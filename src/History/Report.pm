package Plugins::RemotePlayerCompanion::History::Report;

# The operation: what a report does, in what order, and what it logs.
#
# Everything that can refuse the request has already been decided by CLI
# before this runs, so the first line here may write. Local destinations come
# before scrobbles because they are the durable record and cannot fail
# asynchronously.

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::RemotePlayerCompanion::History::APC;
use Plugins::RemotePlayerCompanion::History::Scrobbler;
use Plugins::RemotePlayerCompanion::History::Stats;
use Plugins::RemotePlayerCompanion::History::Store;
use Plugins::RemotePlayerCompanion::DSTM::Tracks;

my $log = logger('plugin.remoteplayercompanion');

sub run {
	my ( $class, $args ) = @_;

	my $playerid = $args->{playerid};
	my $entries  = $args->{entries} || [];

	my @new;
	my $duplicates = 0;
	my %in_request;

	for my $entry ( @{$entries} ) {
		# The store only knows what earlier requests marked, so a repeat
		# inside this one has to be caught here as well: the identity is
		# the same whoever repeats it.
		my $key = _key($entry);

		if ( $in_request{$key}++ ) {
			$duplicates++;
			main::DEBUGLOG && $log->is_debug && $log->debug(
				"history duplicate in request: $playerid " . $entry->{url}
				. ' at ' . $entry->{played} );
			next;
		}

		if ( Plugins::RemotePlayerCompanion::History::Store->seen(
				$playerid, $entry->{url}, $entry->{played} ) )
		{
			$duplicates++;
			main::DEBUGLOG && $log->is_debug && $log->debug(
				"history duplicate: $playerid " . $entry->{url}
				. ' at ' . $entry->{played} );
			next;
		}

		push @new, $entry;
	}

	my $accepted = scalar @new;

	# Everything AudioScrobbler would refuse is decided here, before the first
	# write: the queue cap is the one refusal that depends on what the next
	# few lines do, and a successful answer tells the caller to delete its
	# copy.
	my $scrobbler = Plugins::RemotePlayerCompanion::History::Scrobbler->new($playerid);

	my @scrobble;
	my %eligible;
	for my $entry ( @new ) {
		my ( $ok, $reason, $item ) = $scrobbler->eligible($entry);

		$log->debug(
			'history scrobbler: ' . $playerid . ' ' . $entry->{url}
			. ' status=' . ( $ok ? 'queued' : $reason ) )
			if main::DEBUGLOG && $log->is_debug;

		$eligible{ _key($entry) } = [ $ok, $reason, $item ];

		push @scrobble, $item if $ok;
	}

	if ( @scrobble && $scrobbler->would_overflow( scalar @scrobble ) ) {
		return {
			error => {
				code    => 'SCROBBLE_QUEUE_FULL',
				message => 'the AudioScrobbler queue already holds '
					. $scrobbler->pending . ' entries',
			},
		};
	}

	# Local writes first: they are the durable record and cannot fail
	# asynchronously. Any destination throwing is caught per entry, so one
	# broken one does not stop the others or leave the request unanswered.
	for my $entry ( @new ) {
		my $result = eval {
			Plugins::RemotePlayerCompanion::History::Stats->apply($entry);
		};
		$result ||= { status => 'error', error => ( $@ || 'unknown error' ) };

		main::DEBUGLOG && $log->is_debug && $log->debug(
			'history lms: ' . $playerid . ' ' . $entry->{url}
			. ' status=' . $result->{status}
			. (
				$result->{status} eq 'ok'
				? ' playcount=' . ( 0 + $result->{playcount} )
					. ' lastplayed=' . ( 0 + $result->{lastplayed} )
				: ' error=' . ( $result->{error} || '' )
			)
		);
	}

	my $apc_saved = 0;

	for my $entry ( @new ) {
		my $status;
		my $apc_error;
		eval {
			$status = Plugins::RemotePlayerCompanion::History::APC->apply(
				$entry, $playerid );
			1;
		} or $apc_error = $@ || 'unknown error';

		$status ||= 'error';

		main::DEBUGLOG && $log->is_debug && $log->debug(
			'history apc: ' . $playerid . ' ' . $entry->{url}
			. ' status=' . $status
			. ( $apc_error ? ' error=' . $apc_error : '' )
		);

		# The player is recorded once per request, after the first row that
		# landed -- not once per track.
		if ( $status eq 'ok' && !$apc_saved ) {
			Plugins::RemotePlayerCompanion::History::APC->savePlayer(
				$playerid, $args->{playername} );
			$apc_saved = 1;
		}
	}

	# Scrobbles, then the present tense: LMS's own newsongCallback does the
	# same, so a queued scrobble cannot clobber the now-playing display.
	my $queued = $scrobbler->enqueue( \@scrobble );

	# Each entry this report recorded, named in full. The per-destination
	# lines above say how one fared but identify it only by url; this is the
	# line that answers "what was that song" when a report is being traced.
	# Duplicates never reach here -- they have their own lines above.
	if ( main::DEBUGLOG && $log->is_debug ) {
		for my $entry ( @new ) {
			$log->debug(
				'history recorded: ' . $playerid . ' '
					. Plugins::RemotePlayerCompanion::DSTM::Tracks->describe(
						$entry->{track}, $entry->{url} )
					. ' played=' . $entry->{played} );
		}
	}

	# Now-playing is decided from the play times, not from a parameter: the
	# newest accepted play is what the player is on, and Scrobbler announces
	# it only while the server's clock is still inside its duration. A
	# retried report (every entry a duplicate) therefore announces nothing.
	my $nowplaying_status = 'skipped';
	my $newest            = _newest( \@new );

	if ($newest) {
		my ( $ok, $reason, $item ) =
			@{ $eligible{ _key($newest) } || [ 0, 'unsupported' ] };

		$nowplaying_status =
			$scrobbler->nowPlaying( $newest, $ok ? $item : undef, $args->{now} );

		$log->debug(
			'history now playing: ' . $playerid . ' ' . $newest->{url}
			. ' scrobble=' . ( $ok ? 'eligible' : $reason )
			. ' status=' . $nowplaying_status )
			if main::DEBUGLOG && $log->is_debug;
	}

	# Marked after the last write, not before: a server that dies mid-entry
	# should re-apply it on retry rather than forget it. The window is a few
	# statements wide, and it is the at-least-once boundary.
	#
	# Best-effort: the writes have landed and the caller is about to delete
	# its copy, so a cache that cannot be written must not turn a successful
	# report into an error the caller would retry -- and re-apply.
	eval {
		Plugins::RemotePlayerCompanion::History::Store->mark(
			$playerid, $_->{url}, $_->{played} ) for @new;
		1;
	} or main::DEBUGLOG && $log->is_debug && $log->debug(
		'history store: could not mark ' . scalar(@new) . ' entries: ' . $@ );

	# `0 + $accepted` in the interpolation, not `$accepted`: interpolating a
	# scalar marks it as a string, and these two go straight into the answer
	# where the caller expects numbers.
	main::DEBUGLOG && $log->is_debug && $log->debug(
		'history report: ' . $playerid
		. ' entries=' . scalar @{$entries}
		. ' accepted=' . ( 0 + $accepted )
		. ' duplicates=' . ( 0 + $duplicates )
		. ' queued=' . ( 0 + $queued )
		. ' nowplaying=' . $nowplaying_status
	);

	return {
		accepted          => 0 + $accepted,
		duplicates        => 0 + $duplicates,
		queued            => 0 + $queued,
		nowplaying_status => $nowplaying_status,
	};
}

# The identity of a play inside one request: the player is constant here, so
# the URL and the play time are enough, as they are for Store.
sub _key {
	my $entry = shift;

	return $entry->{url} . "\0" . $entry->{played};
}

# The latest play in the batch. Ties go to the later entry: a caller lists
# plays in order, and a report without `played` stamps them all with one
# value, where the last is the one just started.
sub _newest {
	my $entries = shift;

	my $newest;
	for my $entry ( @{$entries} ) {
		$newest = $entry if !$newest || $entry->{played} >= $newest->{played};
	}

	return $newest;
}

1;
