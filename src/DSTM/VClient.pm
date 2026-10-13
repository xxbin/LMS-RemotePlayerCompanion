package Plugins::RemotePlayerCompanion::DSTM::VClient;

# A synthetic client handed to DSTM provider handlers.
#
# DSTM resolves a provider through getHandler($client), which needs only
# $client->master and a per-client 'provider' preference; the handlers
# themselves read the current playlist as a seed through
# Slim::Player::Playlist::playList($client), which is
# $client->master->playlist.
#
# This object therefore satisfies exactly those two contracts and nothing
# else. It is never inserted into %clientHash, so it is invisible to the
# players query, the web UI and the sync target lists.

use strict;
use warnings;

use Slim::Utils::Log;

my $log = logger('plugin.remoteplayercompanion');

sub new {
	my ( $class, $playerid, $playlist ) = @_;

	return bless {
		id       => $playerid,
		playlist => $playlist || [],
		pd       => {},
	}, $class;
}

# --- contracts required by DSTM -------------------------------------------

sub id       { $_[0]->{id} }
sub master   { $_[0] }
sub playlist { $_[0]->{playlist} }

# --- defensive stubs ------------------------------------------------------
#
# Some providers reach for player methods we do not model. Providing inert
# implementations beats dying inside a provider: the reference RandomPlay
# tokens call execute(['randomplaygenreselectall', 0]) purely to clear that
# player's genre filter, which is meaningless for a queue and must not touch
# the server-wide pref a real player would.

sub name      { 'Remote Player ' . $_[0]->{id} }
sub isPlayer  { 0 }
sub connected { 0 }
sub isPlaying { 0 }
sub power     { 0 }

# Exists for one reason: the first time a preference namespace is asked for a
# client's preferences, Slim::Utils::Prefs::Namespace::client migrates them,
# and Slim::Utils::Prefs::Migration::ClientV3 calls $client->hasDigitalIn to
# pick a default menu structure. Without this, that migration dies on an
# undefined method.
#
# Returning 0 is not a fudge. Slim::Player::Client's own default is 0; only
# Transporter answers 1, and a virtual client is not a Transporter.
#
# Those migrations reach for only two methods in total across all fourteen
# ClientV* modules -- hasDigitalIn and isa, which every blessed object has.
# Should a later LMS add a third, the callers that reach this object are
# wrapped in eval and report the failure rather than taking the server down
# with them.
sub hasDigitalIn { 0 }

# Every real client gets one of these in Slim::Player::Client::new, and some
# providers assume it: RatingsLight checks $client->controller before it will
# consider a client at all, and throws when the method is missing.
#
# The real controller rather than a stand-in, because a stand-in would have
# to be extended one missing method at a time as providers reached further
# into it. This client never plays anything, so the controller sits idle; all
# that is wanted from it is that it exists.
sub controller {
	my $self = shift;

	unless ( $self->{controller} ) {
		require Slim::Player::StreamingController;

		$self->{controller} = Slim::Player::StreamingController->new($self);
	}

	return $self->{controller};
}

sub string {
	my ( $self, $token ) = @_;

	return $token unless defined $token;
	return $token unless Slim::Utils::Strings::stringExists($token);

	return Slim::Utils::Strings::string($token);
}

sub execute {
	my ( $self, $args ) = @_;

	my $command = lc( $args->[0] || '' );

	# The reference RandomPlay tokens call this only to clear that player's
	# genre filter before answering with 'randomplay://...'. In DSTM's own
	# flow the player expands that recipe later, so the filter matters. We
	# expand recipes ourselves and never consult RandomPlay's per-client
	# genre preference, so the call has nothing to do here.
	return if $command eq 'randomplaygenreselectall';

	# Anything else means a provider expects real player behaviour we do not
	# model. Say so loudly: silently ignoring it would surface as a fill that
	# mysteriously comes back empty.
	$log->error( 'provider called execute(['
			. join( ',', @{ $args || [] } )
			. "]) on virtual client "
			. $self->{id}
			. ', which does not implement it' );

	return;
}

sub pluginData {
	my $self = shift;

	if ( @_ > 1 ) {
		my ( $key, $value ) = @_;
		$self->{pd}{$key} = $value;
	}

	return $self->{pd}{ $_[0] };
}

1;
