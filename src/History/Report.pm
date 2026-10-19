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

my $log = logger('plugin.remoteplayercompanion');

sub run {
	my ( $class, $args ) = @_;

	my $entries = $args->{entries} || [];

	my $accepted = scalar @{$entries};

	my $nowplaying_status = $args->{nowplaying} ? 'unavailable' : 'skipped';

	main::DEBUGLOG && $log->is_debug && $log->debug(
		'history report: ' . $args->{playerid}
		. ' entries=' . scalar @{$entries}
		. ' nowplaying=' . $nowplaying_status
	);

	return {
		accepted          => $accepted,
		duplicates        => 0,
		queued            => 0,
		nowplaying_status => $nowplaying_status,
	};
}

1;