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

our %CLIENTS;

# The id is internal and prefixed so it cannot collide with a MAC address.
# Never construct the same id twice: Client::new asserts the id is unknown.
sub forPlayer {
	my ( $class, $playerid ) = @_;

	my $id = '__rpc_history_' . $playerid;

	return $CLIENTS{$id} ||= Slim::Player::Client::getClient($id)
		|| $class->new($id);
}

# Client::ipport asserts a paddr, and Client::ip splits one. A synthetic
# client has neither, and getClient's brute-force loop calls both on every
# client whenever an id misses -- which is every request that asks for a
# player LMS does not know.
sub ipport { '' }
sub ip     { '' }

1;
