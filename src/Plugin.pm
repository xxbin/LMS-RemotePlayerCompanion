package Plugins::RemotePlayerCompanion::Plugin;

# Plugin entry point.
#
# It brings up the command groups and registers the one command that belongs to
# no group. Each group owns the registration of its own commands, so adding
# another one later (say a 'remoteplayercompanion cache ...' family) is a
# directory under this one plus a single line here.

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;

use Plugins::RemotePlayerCompanion::DSTM::CLI;
use Plugins::RemotePlayerCompanion::History::CLI;

# Logging, registered rather than merely created.
#
# LMS's logging settings offer *categories*, and a category is registered by
# asking for one. A plain logger('plugin.remoteplayercompanion') gives a
# logger that works and a category LMS has never heard of: the plugin logs,
# and cannot be turned up from the settings page, with nothing to say why.
# Every plugin that ships with LMS registers its category this way.
#
# The modules below go on calling logger() -- once the category is
# registered, that is the same logger, and this is where it is registered.
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.remoteplayercompanion',
	'defaultLevel' => 'ERROR',
	'description'  => 'PLUGIN_REMOTEPLAYERCOMPANION_NAME',
});

# No $VERSION here, deliberately.
#
# The version is install.xml's, and it is read from there by everything that
# needs it: LMS parses that file to install and to offer updates, build.py
# reads it to name and check a release, and the release workflow refuses a tag
# that disagrees with it. A constant here would be a second copy, and there is
# nothing in LMS that reads one -- no installed plugin on this server declares
# it. This file used to carry `our $VERSION = '1.0.0'`, which had drifted two
# releases behind the file that counts.

sub initPlugin {
	my $class = shift;

	Plugins::RemotePlayerCompanion::DSTM::CLI->init;
	Plugins::RemotePlayerCompanion::History::CLI->init;

	Slim::Control::Request::addDispatch(
		[ 'remoteplayercompanion', 'version' ],
		[ 0, 1, 1, \&cliVersion ],
	);

	main::INFOLOG && $log->is_info && $log->info('Remote Player Companion initialized');

	return;
}

# The plugin's own version, from the one place it is written.
#
# Not a constant and not read from install.xml by hand: LMS has already parsed
# that file and keeps the manifest, so this asks for what LMS itself believes
# is installed. A hand-kept copy is exactly what drifted before.
sub cliVersion {
	my $request = shift;

	my $manifest = Slim::Utils::PluginManager->allPlugins->{'RemotePlayerCompanion'};

	$request->addResult( 'version', ( $manifest && $manifest->{'version'} ) || '' );
	$request->setStatusDone;

	return;
}

sub getDisplayName {
	return 'PLUGIN_REMOTEPLAYERCOMPANION_NAME';
}

1;
