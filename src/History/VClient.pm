package Plugins::RemotePlayerCompanion::History::VClient;

# The synthetic client the AudioScrobbler path needs.
#
# AudioScrobbler stores a client's *id*, not the object: API::new keeps
# $client->id, and every later path resolves it through
# Slim::Player::Client::getClient -- the handshake, the retry, the queue, the
# metadata lookup, and master(). An object that is not in %clientHash works
# for the first call and is lost at the first of those.
#
# So the client has to be a real one. Slim::Player::Disconnected is LMS's own
# class for players that are known but not connected; it supplies a hidden
# client (clients() filters hidden, so the players query, the web UI, the
# sync lists and clientCount never see it), a NoDisplay, and inert
# stop/play/pause. One client per remote player keeps accounts and pending
# queues from crossing.

use strict;
use warnings;

use Slim::Player::Client;

use parent 'Slim::Player::Disconnected';

# The client's id is the remote player's own id: the same value APC records
# as `client_id` and the duplicate store keys on. One remote player is one
# identity in every destination, so the `_client:<id>` preferences this client
# keeps its account and pending queue in describe the same player APC's
# history does -- and stay put across requests and restarts, because the id
# is not allocated but is the caller's own.
#
# Client::new registers the client in %clientHash, so the id must not already
# be another client's. getClient matches by name and by address as well as by
# id, so the id is compared rather than trusted: a client returned for its
# *name* is a different player, and adopting it would spend its account and
# queue on this one. That is refused; the report still succeeds, scrobbling
# is logged as unavailable.
sub forPlayer {
	my ( $class, $playerid ) = @_;

	my $client = Slim::Player::Client::getClient($playerid);

	if ($client) {
		# Ours from an earlier request, or a client LMS already keeps under
		# this id -- the same player either way, and the same preferences.
		return $client if $client->id eq $playerid;

		die "history client: $playerid is another client's name\n";
	}

	# Client::new only registers the client. The preferences every client is
	# expected to have -- titleFormat above all -- are installed by
	# Client::init, which runs when a player connects and so never for this
	# one. Without them, anything that formats a title for this client dies:
	# HTTP::getMetadataFor asks for the current title while the scrobbler
	# looks up a remote URL, and standardTitleFormat dereferences titleFormat
	# as an array (Slim::Music::Info line 755). A remote player reporting a
	# remote URL -- the case this family exists for -- would then silently
	# never scrobble. initPrefs is the same call, minus display and alarms,
	# and only fills what is missing, so it is harmless on a client LMS has
	# already initialised.
	$client = $class->new($playerid);
	$client->initPrefs;

	return $client;
}

# Client::ipport asserts a paddr, and Client::ip splits one. A synthetic
# client has neither, and getClient's brute-force loop calls both on every
# client whenever an id misses -- which is every request that asks for a
# player LMS does not know.
sub ipport { '' }
sub ip     { '' }

1;
