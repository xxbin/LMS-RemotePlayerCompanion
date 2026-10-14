package Plugins::RemotePlayerCompanion::DSTM::Provider;

# Calling Dont Stop The Music providers, and turning what they hand back into
# playable track URLs.
#
# Resolving a provider token to a handler is the fiddly half. %handlers is
# lexical to DSTM, so the only public door is getHandler($client), which
# reads the token from that client's 'provider' preference. We therefore
# write the token into the preference of a throwaway client, resolve, and
# restore straight away -- getHandler is the only reader of that
# preference, so the swap never has to stay open across an async provider
# call.
#
# The token now arrives from that same preference (see adopted() below), which
# makes the swap look redundant. It is not. getHandler resolves whatever the
# preference says *now*, while the queue record holds what it said when the
# queue was seeded; those diverge the moment a user changes the setting for
# their player, and the record is the queue's truth. So the record's token is
# what gets resolved, and that means putting it back into a preference for the
# length of the call.
#
# Turning the answer into tracks is the other half, and providers answer in
# several shapes. The routing, and the reasons for refusing what we refuse,
# are in expand() below.

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Plugins::RemotePlayerCompanion::DSTM::RandomPlay;
use Plugins::RemotePlayerCompanion::DSTM::Tracks;
use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

my $log = logger('plugin.remoteplayercompanion');

use constant DSTM_PLUGIN => 'Slim::Plugin::DontStopTheMusic::Plugin';

# Providers we offer, on top of the conventionally named ones.
#
# DSTM's registry is a grab bag. RandomPlay, LastMix, Spotty and the rest
# register tokens named PLUGIN_<SOMETHING>, but Favorites registers one
# provider per favourite under the favourite's own title -- radio stations
# and albums alike, and a library with many favourites produces far more of
# those than it does real providers -- while other plugins simply use their
# own display names.
#
# So we list what belongs rather than trying to subtract what does not. A
# subtraction cannot be made correct: DSTM resolves one handler per token and
# keeps its registry lexical, so there is no way to ask a token who
# registered it, and any name-based rule both misses some noise and catches
# real providers (BBC Sounds and BlissMixer carry no PLUGIN_ prefix).
#
# Add a token here when it generates a mix but is not PLUGIN_-prefixed.
# 'sources all:1' lists the registry unfiltered, which is the way to find
# the exact spelling of one.
use constant EXTRA_TOKENS => qw(BLISSMIXER_DSTM);

sub available {
	return Slim::Utils::PluginManager->isEnabled(DSTM_PLUGIN) ? 1 : 0;
}

sub tokens {
	my ( $class, $vClient ) = @_;

	return () unless $class->available;

	# Called as a plain function, not as a class method: getSortedHandlerTokens
	# takes the client as its first argument with no $class slot, so '->' would
	# silently pass the package name where the client belongs. getHandler below
	# does have a $class slot and is therefore called with '->'.
	return Slim::Plugin::DontStopTheMusic::Plugin::getSortedHandlerTokens($vClient);
}

sub hasToken {
	my ( $class, $vClient, $token ) = @_;

	return scalar grep { $_ eq $token } $class->tokens($vClient);
}

# Is this token one worth offering to a queue?
#
# The convention is the PLUGIN_ prefix; EXTRA_TOKENS covers the providers
# that generate a mix without following it. Everything else in the registry
# is a favourite, or a plugin's own naming, and is left out of our listings.
sub isOffered {
	my ( $class, $token ) = @_;

	return 1 if $token =~ /^PLUGIN_/;

	return scalar grep { $_ eq $token } EXTRA_TOKENS;
}

# The provider this player is set to, if it is one a queue may use.
#
# Returns ( $token, $error ). The token is undef exactly when $error is set.
#
# Checked against the same whitelist 'sources' offers. The registry carries one
# entry per favourite alongside the real providers, and a queue pointed at one
# of those is pointed at a single favourite rather than at a mix -- and DSTM's
# own per-player setting will happily hold one, because that setting was not
# written with this queue in mind.
sub adopted {
	my ( $class, $vClient ) = @_;

	my $token = $class->stored($vClient);

	unless ($token) {
		# Stated neutrally on purpose: stored() also answers undef when Dont
		# Stop The Music is not enabled at all, so this is "nothing came back"
		# rather than "nothing was set".
		main::DEBUGLOG && $log->is_debug
			&& $log->debug( 'no provider adopted for ' . $vClient->id . ' (NO_PROVIDER)' );

		return ( undef, 'NO_PROVIDER' );
	}

	my ( $ok, $err ) = $class->check( $vClient, $token );

	return ( undef, $err ) unless $ok;

	return ( $token, undef );
}

# What the player's own Dont Stop The Music setting says, or undef.
#
# Truthiness, not definedness: DSTM's own settings write the string '0' for
# their "none" choice, and DSTM reads this back through `|| ''` -- so '0' is
# false there, and it has to be false here too or we would go looking for a
# provider literally named 0.
sub stored {
	my ( $class, $vClient ) = @_;

	return unless $class->available;

	return preferences('plugin.dontstopthemusic')->client($vClient)->get('provider') || undef;
}

# May a queue be pointed at this token? Returns ( $ok, $error ).
#
# Shared by adoption and by config, so that naming a provider and inheriting
# one are judged by the same rule -- the registry carries one entry per
# favourite alongside the real providers, and neither route should accept one.
sub check {
	my ( $class, $vClient, $token ) = @_;

	# Each refusal says so, with the token in it. This is the answer to "why
	# will my queue not take the provider I picked", and from outside the three
	# refusals are indistinguishable: every one of them is a queue that will
	# not fill.
	unless ( $class->available ) {
		main::DEBUGLOG && $log->is_debug
			&& $log->debug("provider $token refused: Dont Stop The Music is not enabled");
		return ( 0, 'DSTM_DISABLED' );
	}

	unless ( $class->hasToken( $vClient, $token ) ) {
		main::DEBUGLOG && $log->is_debug
			&& $log->debug("provider $token refused: Dont Stop The Music does not know it");
		return ( 0, 'UNKNOWN_PROVIDER' );
	}

	unless ( $class->isOffered($token) ) {
		main::DEBUGLOG && $log->is_debug
			&& $log->debug("provider $token refused: it is a single favourite rather than a mix");
		return ( 0, 'PROVIDER_NOT_OFFERED' );
	}

	return ( 1, undef );
}

# Put a provider into the player's own setting.
#
# This writes another plugin's preference, which is deliberate: the queue and
# the player are then set to the same provider, so the player keeps behaving
# the way its queue does. It is also what makes a queue configurable without
# going into LMS's UI.
sub assign {
	my ( $class, $vClient, $token ) = @_;

	preferences('plugin.dontstopthemusic')->client($vClient)->set('provider', $token);

	return 1;
}

# Resolve the record's provider and call it. $cb->($urls, $error) fires
# exactly once, either synchronously (handler answered inline) or later
# (handler is async). Bounding the wait is the caller's business.
sub invoke {
	my ( $class, $rec, $vClient, $cb ) = @_;

	return $cb->( undef, 'DSTM_DISABLED' ) unless $class->available;

	my $token = $rec->{provider};

	return $cb->( undef, 'NOT_CONFIGURED' ) unless defined $token && length $token;
	return $cb->( undef, 'UNKNOWN_PROVIDER' ) unless $class->hasToken( $vClient, $token );

	my $handler = eval { $class->_resolve( $vClient, $token ) };

	if ( !$handler ) {
		$log->error("could not resolve provider $token: " . ($@ || 'no handler returned'));
		return $cb->( undef, 'NO_HANDLER' );
	}

	# A provider delivers its tracks by calling this callback, now or on some
	# later event-loop turn -- that callback *is* the delivery mechanism, so
	# there is nothing else to collect. Returning without it having fired is
	# the normal asynchronous case, not a failure.
	my $done = 0;
	my $finish = sub {
		my ( $urls, $err ) = @_;

		return if $done;
		$done = 1;

		$cb->( $urls, $err );
	};

	eval {
		$handler->( $vClient, sub {
			my ( $client, $tracks ) = @_;

			$finish->( ref $tracks eq 'ARRAY' ? $tracks : [], undef );
		} );
	};

	if ($@) {
		# An error, not a warning: a provider that throws tells us something
		# about the object we handed it, and the exception is the only clue
		# there is. Providers reach for player methods our synthetic client
		# may not have, so this line is where that shows up.
		$log->error("provider $token died: $@");
		return $finish->( undef, 'HANDLER_DIED' );
	}

	return;
}

sub _resolve {
	my ( $class, $vClient, $token ) = @_;

	my $prefs = preferences('plugin.dontstopthemusic');
	my $pc    = $prefs->client($vClient);
	my $old   = $pc->get('provider');

	$pc->set( 'provider', $token );

	my ( $handler, $err );
	my $ok = eval { $handler = Slim::Plugin::DontStopTheMusic::Plugin->getHandler($vClient); 1 };
	$err = $@ unless $ok;

	my $readback = $pc->get('provider');

	# getHandler is the only reader of this preference, so restore right away
	# rather than holding the swap open across a possibly async provider call.
	if ( defined $old ) {
		$pc->set( 'provider', $old );
	}
	else {
		$pc->remove('provider');
	}

	die $err unless $ok;

	main::INFOLOG && $log->is_info
		&& $log->info("resolved $token for " . $vClient->id . ': pref readback='
			. ( defined $readback ? $readback : 'undef' )
			. ', handler=' . ( defined $handler ? 'yes' : 'no' ) );

	return $handler;
}

# --- turning the answer into tracks ---------------------------------------

# Providers answer in several shapes, and not all of them are tracks:
#
#   randomplay://<kind>[?genres=...]   a recipe, which a real player expands
#   db:<entity>                        an album/contributor/work, not a song
#   http(s)://                         in practice a live stream, which a
#                                      cached player can never hold
#   file://, spotify://, ...           a track, playable as it stands
#
# We expand what can be expanded, and refuse what cannot become something a
# player could fetch. Refusing matters: a queue that quietly fills with
# unplayable entries fails much later, at the far end, where nothing points
# back to the provider that caused it.
sub expand {
	my ( $class, $urls, $want, $vClient ) = @_;

	my @kept;
	my @refused;

	for my $url ( @{ $urls || [] } ) {
		next unless defined $url && length $url;

		# A provider may hand back an object rather than a URL; DSTM's own
		# handlers do, for the favourite and dynamic-playlist cases.
		$url = $url->url if blessed $url;

		next unless defined $url && length $url;

		my ( $out, $why ) = $class->_expandOne( $url, $want );

		if ( defined $out ) {
			push @kept, @{$out};
		}
		else {
			push @refused, "$url [$why]";
		}
	}

	if (@refused) {
		# Cap the list: one badly behaved provider could otherwise fill the
		# log with the same complaint hundreds of times per refill.
		my $shown = @refused > 5 ? join( ', ', @refused[ 0 .. 4 ] ) . ', ...' : join( ', ', @refused );

		$log->error( scalar(@refused) . ' provider entr' . ( @refused == 1 ? 'y' : 'ies' )
			. " cannot become playable tracks and were refused: $shown" );
	}

	return \@kept;
}

sub _expandOne {
	my ( $class, $url, $want ) = @_;

	if ( $url =~ m{^randomplay://}i ) {
		my $out = eval { Plugins::RemotePlayerCompanion::DSTM::RandomPlay->expand( $url, $want ) };

		return ( undef, 'recipe failed: ' . ($@ || 'nothing selected') ) if $@ || !$out;

		return ( $out, undef );
	}

	if ( $url =~ m{^db:}i ) {
		return Plugins::RemotePlayerCompanion::DSTM::Tracks->expandDb( $url, $want );
	}

	# DynamicPlaylists4 answers through DSTM with a marker rather than with
	# tracks, and expanding it means calling into that plugin's own API. We
	# have not seen a provider produce one, so rather than couple to it
	# speculatively we refuse it -- loudly, so that a server which does
	# produce one finds out here instead of at the far end.
	return ( undef, 'dynamicplaylist markers are not expanded' ) if $url =~ m{^dynamicplaylist://}i;

	# A blunt rule, and deliberately so: a stream cannot be cached, which is
	# the whole point of this queue. It also refuses a plain http file, such
	# as a podcast episode, which *could* be cached -- there is no reliable
	# LMS-wide test that separates the two, so the simple rule wins until a
	# real case argues otherwise.
	return ( undef, 'streams cannot be cached' ) if $url =~ m{^https?://}i;

	return ( [$url], undef );
}

1;
