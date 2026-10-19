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

use Plugins::RemotePlayerCompanion::History::Stats;
use Plugins::RemotePlayerCompanion::History::Store;

my $log = logger('plugin.remoteplayercompanion');

sub run {
	my ( $class, $args ) = @_;

	my $playerid = $args->{playerid};
	my $entries  = $args->{entries} || [];

	my @new;
	my $duplicates = 0;

	for my $entry ( @{$entries} ) {
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

	my $nowplaying_status = $args->{nowplaying} ? 'unavailable' : 'skipped';

	# Marked after the last write, not before: a server that dies mid-entry
	# should re-apply it on retry rather than forget it. The window is a few
	# statements wide, and it is the at-least-once boundary.
	Plugins::RemotePlayerCompanion::History::Store->mark(
		$playerid, $_->{url}, $_->{played} ) for @new;

	# `0 + $accepted` in the interpolation, not `$accepted`: interpolating a
	# scalar marks it as a string, and these two go straight into the answer
	# where the caller expects numbers.
	main::DEBUGLOG && $log->is_debug && $log->debug(
		'history report: ' . $playerid
		. ' entries=' . scalar @{$entries}
		. ' accepted=' . ( 0 + $accepted )
		. ' duplicates=' . ( 0 + $duplicates )
		. ' nowplaying=' . $nowplaying_status
	);

	return {
		accepted          => 0 + $accepted,
		duplicates        => 0 + $duplicates,
		queued            => 0,
		nowplaying_status => $nowplaying_status,
	};
}

1;