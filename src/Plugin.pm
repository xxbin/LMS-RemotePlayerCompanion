package Plugins::RemotePlayerCompanion::Plugin;

# Plugin entry point.
#
# It does nothing but bring up the command groups. Each group owns the
# registration of its own commands, so adding another one later (say a
# 'remoteplayercompanion cache ...' family) is a directory under this one
# plus a single line here.

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::RemotePlayerCompanion::DSTM::CLI;

my $log = logger('plugin.remoteplayercompanion');

our $VERSION = '1.0.0';

sub initPlugin {
	my $class = shift;

	Plugins::RemotePlayerCompanion::DSTM::CLI->init;

	main::INFOLOG && $log->is_info && $log->info('Remote Player Companion initialized');

	return;
}

sub getDisplayName {
	return 'PLUGIN_REMOTEPLAYERCOMPANION_NAME';
}

1;
