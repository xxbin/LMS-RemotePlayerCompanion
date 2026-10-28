package Plugins::RemotePlayerCompanion::DSTM::RandomPlay;

# Expanding randomplay:// recipes by asking RandomPlay to do the work.
#
# RandomPlay's DSTM tokens answer with recipes such as
# 'randomplay://track?genres=Rock' rather than with tracks, because a real
# player expands them later. A queue has no player, so the expansion has to
# happen here.
#
# This sits in its own module because it is the one place that reaches into
# RandomPlay's internals, and that coupling deserves to be visible:
#
#   * Mixer::getIdList is undocumented. It is called as a plain function
#     because it takes the client as its first argument with no $class slot.
#
#   * getIdList decides what to include by calling Plugin::getGenres, which
#     reads the genres off the client's pluginData rather than from its
#     arguments -- so the recipe's genres have to be planted there first.
#
#   * Mixer.pm never loads Plugin.pm, yet calls into it. The require below
#     is therefore load-bearing: without it getIdList dies on an undefined
#     subroutine on any server where RandomPlay is not enabled.
#
#   * getIdList also honours RandomPlay's server-wide 'exclude_genres' and
#     'library' preferences. A server that has set those will see queues
#     quietly follow them.
#
# An LMS release that changes any of that breaks here, in one known file.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use URI;

use Plugins::RemotePlayerCompanion::DSTM::Tracks;
use Plugins::RemotePlayerCompanion::DSTM::VClient;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;

my $log   = logger('plugin.remoteplayercompanion');
my $cache = Slim::Utils::Cache->new();

my $mixerModule;

use constant ID_CACHE_TTL     => 3600;
use constant MAX_ENTITIES     => 50;
use constant SELECT_CLIENT_ID => 'remoteplayercompanion-recipe';

# A 'randomplay://<kind>[?genres=...]' recipe -> a listref of track URLs.
sub expand {
	my ( $class, $url, $want ) = @_;

	my $params = {};
	eval { $params = { URI->new($url)->query_form } };

	my $genres = $params->{genres};

	my ($kind) = $url =~ m{^randomplay://([a-z]*)};
	$kind = lc( $kind || 'track' );
	$kind = 'track' unless $kind =~ /^(?:track|album|contributor|work|year)$/;

	if ( $kind eq 'track' || $kind eq 'year' ) {
		my $ids = $class->_nextIds( $kind, $genres, $want );

		return [ map { Plugins::RemotePlayerCompanion::DSTM::Tracks->urlForId($_) }
			grep { defined } @{$ids} ];
	}

	return $class->_expandEntities( $kind, $genres, $want );
}

# Splice up to $want ids from a cached, shuffled id list, rebuilding it when
# it runs dry.
#
# The cache is what keeps a refill loop cheap. getIdList rebuilds and
# reshuffles its list on every call, so without this a queue topping itself
# up would re-query the whole library once per provider call.
sub _nextIds {
	my ( $class, $kind, $genres, $want ) = @_;

	my $key  = 'rpc_ids_' . md5_hex( join( '|', $kind, defined $genres ? $genres : '' ) );
	my $list = $cache->get($key);

	my $regenerated = 0;
	my $size_after  = 0;

	if ( !$list || !scalar @{$list} ) {
		$list = $class->_selectIds( $kind, $genres );
		$regenerated = 1;
		$size_after  = scalar @{ $list || [] };

		return [] unless $list && scalar @{$list};
	}

	my @out = splice @{$list}, 0, $want;

	$cache->set( $key, $list, ID_CACHE_TTL );

	# Debug rather than info: a refill loop calls this repeatedly, so this is
	# only worth printing when someone is actually asking why a queue is not
	# filling. Turning on plugin.remoteplayercompanion is the way to see it.
	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug("ids for $kind: want=$want regenerated=$regenerated "
			. "generated=$size_after remaining=" . scalar( @{$list} )
			. ' returned=' . scalar(@out)
			. ' first=' . join( ',', @out[ 0 .. ( @out > 3 ? 2 : $#out ) ] ) );
	}

	return \@out;
}

# Entity recipes (album/contributor/work) select entities rather than
# tracks, so a full batch needs several of them expanded and is not a plain
# splice.
sub _expandEntities {
	my ( $class, $kind, $genres, $want ) = @_;

	my $key  = 'rpc_ents_' . md5_hex( join( '|', $kind, defined $genres ? $genres : '' ) );
	my $list = $cache->get($key);

	if ( !$list || !scalar @{$list} ) {
		$list = $class->_selectIds( $kind, $genres );
	}

	my @tracks;
	my $guard = 0;

	while ( scalar(@tracks) < $want && scalar(@{$list}) && $guard++ < MAX_ENTITIES ) {
		my $entity = shift @{$list};

		push @tracks, @{ Plugins::RemotePlayerCompanion::DSTM::Tracks->tracksForEntity( $kind, $entity ) };
	}

	$cache->set( $key, $list, ID_CACHE_TTL );

	splice @tracks, $want if scalar(@tracks) > $want;

	return [ map { Plugins::RemotePlayerCompanion::DSTM::Tracks->urlForId($_) } grep { defined } @tracks ];
}

# Ask RandomPlay to choose and shuffle the ids.
#
# This is RandomPlay's own selection routine, the one its mixer uses, so we
# inherit its semantics instead of reimplementing them: the library filter,
# the balanced shuffle when the server has it enabled, and the choice of a
# random year for 'year'.
sub _selectIds {
	my ( $class, $kind, $genres ) = @_;

	my $available = $class->_mixer or return [];

	# A throwaway client. getIdList uses it for pluginData, for an id to key
	# RandomPlay's year cache on, and as the first argument of the
	# needsClient=0 queries it runs -- executeRequest passes $client->id(),
	# not the object, so an unregistered id is fine here.
	my $client = Plugins::RemotePlayerCompanion::DSTM::VClient->new( SELECT_CLIENT_ID, [] );

	if ( defined $genres && length $genres ) {
		$client->pluginData( include_genres => [ split /,/, $genres ] );
	}

	# A plain function call, deliberately. getIdList takes the client as its
	# first argument and has no $class slot, so '->' would pass the package
	# name where the client belongs -- which fails as a missing pluginData
	# method deep inside RandomPlay's own genre lookup.
	my $ids = eval { Slim::Plugin::RandomPlay::Mixer::getIdList( $client, $kind ) };

	if ($@) {
		$log->error("RandomPlay could not select $kind ids: $@");
		return [];
	}

	if ( ref $ids ne 'ARRAY' || !scalar @{$ids} ) {
		$log->error("RandomPlay selected no $kind ids"
			. ( defined $genres ? " for genres '$genres'" : '' ) );
		return [];
	}

	# Worth knowing when a queue will not fill: getIdList selects from
	# RandomPlay's own genre selection, so a server that has excluded genres
	# there will find its queues limited to the rest, whatever the library
	# holds. These counts are the difference between "the provider had
	# nothing" and "we asked it for almost nothing".
	if ( main::DEBUGLOG && $log->is_debug ) {
		require Slim::Plugin::RandomPlay::Plugin;

		my $included = Slim::Plugin::RandomPlay::Plugin::getFilteredGenres( $client, 0, 0, 1 );
		my $excluded = Slim::Plugin::RandomPlay::Plugin::getFilteredGenres( $client, 1, 0, 1 );

		$log->debug("selected $kind ids: got=" . scalar(@{$ids})
			. ' includedGenres=' . scalar( @{ $included || [] } )
			. ' excludedGenres=' . scalar( @{ $excluded || [] } )
			. ' recipeGenres=' . ( defined $genres ? $genres : 'none' ) );
	}

	return $ids;
}

# Load RandomPlay's mixer on first use, and keep it.
#
# The empty string is a deliberate "tried and failed" marker, so a server
# without RandomPlay reports the problem once rather than on every call.
sub _mixer {
	my $class = shift;

	return $mixerModule if defined $mixerModule;

	$mixerModule = '';

	# Installed is not enabled: LMS puts every installed plugin on @INC, so
	# the require below would succeed for a RandomPlay that was switched off,
	# and its mixer would be called anyway.
	if ( !eval { Slim::Utils::PluginManager->isEnabled('Slim::Plugin::RandomPlay::Plugin') } ) {
		$log->error('RandomPlay is disabled; cannot expand randomplay:// recipes');
		return $mixerModule;
	}

	if ( eval { require Slim::Plugin::RandomPlay::Plugin; require Slim::Plugin::RandomPlay::Mixer; 1 } ) {
		$mixerModule = 'Slim::Plugin::RandomPlay::Mixer';
	}
	else {
		$log->error("RandomPlay is unavailable; cannot expand randomplay:// recipes: $@");
	}

	return $mixerModule;
}

1;
