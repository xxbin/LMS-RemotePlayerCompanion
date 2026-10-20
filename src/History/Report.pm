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
		my $key = $entry->{url} . "\0" . $entry->{played};

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
	for my $entry ( @new ) {
		my ( $ok, $reason, $item ) = $scrobbler->eligible($entry);

		$log->debug(
			'history scrobbler: ' . $playerid . ' ' . $entry->{url}
			. ' status=' . ( $ok ? 'queued' : $reason ) )
			if main::DEBUGLOG && $log->is_debug;

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

	my $nowplaying_ok = 0;
	if ( $args->{nowplaying} ) {
		( $nowplaying_ok ) = $scrobbler->eligible( $args->{nowplaying} );
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

	my $nowplaying_status = 'skipped';
	if ( $args->{nowplaying} ) {
		$nowplaying_status = $nowplaying_ok
			? $scrobbler->nowPlaying( $args->{nowplaying}{track} )
			: 'unavailable';
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

1;
