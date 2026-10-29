package Plugins::RemotePlayerCompanion::History::Targets;

# The local destinations a report writes to.
#
# Each target is a batch applier for one destination. The interface is:
#
#   new($ctx)        one per request; $ctx carries playerid, playername, now
#   name()           the word in the debug line: lms, apc, listeninghistory
#   status()         'ok' or 'unavailable'
#   apply(\@plays)    \@results, one per play, in the same order:
#                    { status => 'ok'|'skipped'|'error', detail => '...' }
#
# A target owns the rules of its destination and nothing else. It must not
# fail the report: a plugin that is not installed makes the target
# `unavailable`, a play the destination declines is `skipped`, and a write
# that throws is `error` for that play only.
#
# Order matters. These are the durable local records, written before the
# AudioScrobbler queue because they cannot fail asynchronously.
#
# AudioScrobbler is deliberately not a target. It refuses a whole request
# before anything is written (the queue cap) and owns now-playing, so Report
# keeps it outside the batch loop.

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::RemotePlayerCompanion::History::Targets::APC;
use Plugins::RemotePlayerCompanion::History::Targets::ListeningHistory;
use Plugins::RemotePlayerCompanion::History::Targets::Stats;

my $log = logger('plugin.remoteplayercompanion');

my @TARGETS = (
	'Plugins::RemotePlayerCompanion::History::Targets::Stats',
	'Plugins::RemotePlayerCompanion::History::Targets::APC',
	'Plugins::RemotePlayerCompanion::History::Targets::ListeningHistory',
);

# One target per destination, in the order they write. A target that cannot
# even be constructed is logged and left out: one broken destination must not
# take the report down with it.
sub for_context {
	my ( $class, $ctx ) = @_;

	my @targets;

	for my $target_class (@TARGETS) {
		my $target = eval { $target_class->new($ctx) };

		if ( !$target ) {
			my $error = $@ || 'unknown error';
			$error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
			$log->error("history target $target_class could not start: $error");
			next;
		}

		push @targets, $target;
	}

	return \@targets;
}

1;