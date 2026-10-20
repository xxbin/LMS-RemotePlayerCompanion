package Plugins::RemotePlayerCompanion::History::Store;

# What this plugin has already recorded.
#
# A retried report must not count a play twice, and the API carries no
# idempotency token. The play is the token: the player, the resolved URL and
# the play time. `id:27189` and the equivalent `url:` resolve to the same
# URL, so they dedupe against each other.
#
# A namespace of our own, for the reason documented in DSTM::Queue: the
# default cache namespace's version marker does not read back on this LMS,
# so it is cleared on every start; a custom namespace's is durable. It is
# separate from the queue's so either layout can bump its own version
# without clearing the other.
#
# The TTL matches the accepted window: a play old enough to be refused needs
# no duplicate memory.

use strict;
use warnings;

use Slim::Utils::Cache;
use Digest::MD5 qw(md5_hex);

my $cache = Slim::Utils::Cache->new( 'remoteplayercompanion_history', 1 );

use constant TTL => 7 * 86400;

sub _key {
	my ( $playerid, $url, $played ) = @_;

	return 'rpc_history_' . md5_hex(
		join "\0", $playerid, $url, $played
	);
}

# Without a play time there is no key to remember: the request was stamped
# with a per-request `now`, and a retry cannot produce the same one. A caller
# that may retry should send `played`; the documentation says so.
sub seen {
	my ( $class, $playerid, $url, $played ) = @_;

	return 0 unless defined $played && length $played;

	return $cache->get( _key( $playerid, $url, $played ) ) ? 1 : 0;
}

sub mark {
	my ( $class, $playerid, $url, $played ) = @_;

	return unless defined $played && length $played;

	$cache->set( _key( $playerid, $url, $played ), 1, TTL );
}

1;
