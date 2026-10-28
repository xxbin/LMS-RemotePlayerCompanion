package Plugins::RemotePlayerCompanion::History::Scrobbler;

# AudioScrobbler, entered through its own queue.
#
# The plugin builds the queue item LMS's newsongCallback would have built and
# hands the queue back to LMS, which owns the handshake, the retries, the
# 50-item chunking and the durable queue. Nothing here posts to Last.fm.
#
# Everything runs on a synthetic client (see VClient): the account choice, the
# queue and the session are per client, so one remote player never shares an
# account or a pending scrobble with another.
#
# Every AudioScrobbler function called below takes the client as its *first*
# argument and has no $class slot, so they are plain calls, never `->`.

use strict;
use warnings;

use URI::Escape qw(uri_escape_utf8);

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

use Plugins::RemotePlayerCompanion::History::VClient;

my $log   = logger('plugin.remoteplayercompanion');
my $prefs = preferences('plugin.audioscrobbler');

# AudioScrobbler's own floor: a shorter track is never scrobbled.
use constant MIN_DURATION => 30;

# Our backpressure, not LMS's. A queue this long means submission has been
# failing for a long time, and taking more entries only makes the backlog
# harder to clear.
use constant MAX_PENDING => 1000;

# Probed, not assumed: on a server without it -- or with it switched off --
# the report still succeeds and every entry logs `unsupported`. `require`
# alone is not enough: the module is on @INC even when LMS did not load the
# plugin, and the stored preferences still say scrobbling is on, so calling
# into it would submit where the user expects nothing to be submitted.
my $available;

sub available {
	return $available if defined $available;

	$available =
		   eval { Slim::Utils::PluginManager->isEnabled('Slim::Plugin::AudioScrobbler::Plugin') }
		&& eval { require Slim::Plugin::AudioScrobbler::Plugin; 1 }
		? 1 : 0;

	return $available;
}

# How this server names an account.
#
# Newer LMS stores the full id ("username::api_type::api_url") in a player's
# preference; older LMS stores the bare username and matches on it. The two
# are not interchangeable, so the naming and the matching are asked of the
# server rather than assumed -- the same preference must be readable by the
# getAccount that will later read it.
my $full_ids;

sub _accountId {
	my $account = shift;

	unless ( defined $full_ids ) {
		$full_ids =
			Slim::Plugin::AudioScrobbler::Plugin->can('getAccountId') ? 1 : 0;
	}

	return $full_ids
		? Slim::Plugin::AudioScrobbler::Plugin::getAccountId($account)
		: $account->{username};
}

sub new {
	my ( $class, $playerid ) = @_;

	my $self = bless { playerid => $playerid }, $class;

	unless ( $class->available ) {
		$self->{status} = 'unsupported';
		return $self;
	}

	my $client = eval {
		Plugins::RemotePlayerCompanion::History::VClient->forPlayer($playerid);
	};

	if ( !$client ) {
		$log->error(
			'history scrobbler: cannot create a client for ' . $playerid
			. ': ' . ( $@ || 'unknown error' ) );
		$self->{status} = 'unsupported';
		return $self;
	}

	$self->{client} = $client;
	$self->{status} = $self->_selectAccount;

	return $self;
}

sub status { $_[0]->{status} }
sub client { $_[0]->{client} }

# Which server account this remote player scrobbles as.
#
# The caller never names one: the server's configured accounts are the only
# input. The choice is written into the synthetic client's own `account`
# preference, which is exactly what the AudioScrobbler settings page does for
# a real player -- and what every later LMS path reads. The preference holds
# the full account id, not the bare username.
#
# A stored choice that still matches an account wins, so a server with several
# accounts stays on the one it used last time. A single account is used without
# a choice being recorded. Several accounts with no usable choice is the one
# case the request carries no signal for, so the first is taken and named in a
# warning.
sub _selectAccount {
	my $self = shift;

	my $client = $self->{client};

	return 'disabled' unless $prefs->get('enable_scrobbling');

	my $accounts = eval {
		Slim::Plugin::AudioScrobbler::Plugin::getAccounts($client);
	} || [];

	return 'not_configured' unless ref $accounts eq 'ARRAY' && @{$accounts};

	my $cprefs = $prefs->client($client);
	my $stored = $cprefs->get('account');

	my $chosen;
	if ( defined $stored && length $stored && $stored ne '0' ) {
		($chosen) = grep { _accountId($_) eq $stored } @{$accounts};
	}

	if ( !$chosen && @{$accounts} == 1 ) {
		$chosen = $accounts->[0];
	}

	if ( !$chosen ) {
		$chosen = $accounts->[0];

		$log->warn(
			'history scrobbler: ' . $self->{playerid} . ' has '
			. scalar( @{$accounts} ) . ' AudioScrobbler accounts and no '
			. 'selection; using ' . $chosen->{username} );
	}

	my $id = _accountId($chosen);

	# Suppressed by the preference layer when it is already this value, which
	# matters: a change runs LMS's changeAccount, which trims the pending
	# queue to its newest item.
	$cprefs->set( 'account', $id );

	return 'ok';
}

# Would one report be scrobbled as `$entry`? Returns ($ok, $reason, $item).
#
# The order is LMS's own (newsongCallback then checkScrobble): scrobbling on,
# an account, metadata, length, ignore lists, radio. `$item` is the queue item
# exactly as checkScrobble would build it, with the reported play time in `i`
# where LMS would put the playlist change time.
sub eligible {
	my ( $self, $entry ) = @_;

	return ( 0, $self->{status} ) if $self->{status} ne 'ok';

	my $client = $self->{client};
	my $track  = $entry->{track};
	my $url    = $entry->{url};

	my $meta = eval {
		Slim::Plugin::AudioScrobbler::Plugin::_getMetadata( $client, $track, $url );
	};

	if ( my $error = $@ ) {
		$log->error("history scrobbler: metadata for $url failed: $error");
		return ( 0, 'no_metadata' );
	}

	# No object, or a protocol handler that cannot describe the URL.
	return ( 0, 'unsupported' ) unless $meta;
	return ( 0, 'no_metadata' ) if $meta->{msg};

	my $duration = $meta->{duration};
	return ( 0, 'too_short' ) if $duration && $duration < MIN_DURATION;

	return ( 0, 'ignored' ) if $self->_ignored( $track, $meta );

	my $source = 'P';

	if ( $track->can('stash') ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

		if ( $handler && $handler->can('audioScrobblerSource') ) {
			my $handler_source = $handler->audioScrobblerSource( $client, $url );
			$source = $handler_source if defined $handler_source;

			my $include_radio = $prefs->get('include_radio');

			if ( defined $include_radio && !$include_radio && $source =~ /^[RE]$/ ) {
				return ( 0, 'radio_disabled' );
			}
		}
	}

	return ( 1, 'queued', {
		_url => $url,
		a    => uri_escape_utf8( $meta->{artist} || '' ),
		t    => uri_escape_utf8( $meta->{title}  || '' ),
		i    => 0 + $entry->{played},
		o    => $source,
		r    => '',
		l    => ( $meta->{duration} ? int( $meta->{duration} ) : '' ),
		b    => uri_escape_utf8( $meta->{album} || '' ),
		n    => ( defined $meta->{tracknum} ? $meta->{tracknum} : '' ),
		m    => ( eval { $track->musicbrainz_id } || '' ),
	} );
}

# LMS's matching policy, copied: a comma-separated list, each entry a
# case-insensitive substring of the corresponding field.
sub _ignored {
	my ( $self, $track, $meta ) = @_;

	my @titles  = split( /\s*,\s*/, $prefs->get('ignoreTitles')  || '' );
	my @artists = split( /\s*,\s*/, $prefs->get('ignoreArtists') || '' );
	my @albums  = split( /\s*,\s*/, $prefs->get('ignoreAlbums')  || '' );
	my @genres  = split( /\s*,\s*/, $prefs->get('ignoreGenres')  || '' );

	my $title  = $meta->{title} || '';
	my $artist = eval { $track->artistName } || $meta->{artist} || '';
	my $album  = eval { $track->albumname }  || $meta->{album}  || '';

	return 1 if @titles  && grep { $title  =~ /\Q$_\E/i } @titles;
	return 1 if @artists && grep { $artist =~ /\Q$_\E/i } @artists;
	return 1 if @albums  && grep { $album  =~ /\Q$_\E/i } @albums;

	if (@genres) {
		my @track_genres = map { $_->name } eval { $track->genres };
		push @track_genres, $meta->{genre}
			if !@track_genres && $meta->{genre};

		for my $genre (@track_genres) {
			return 1 if grep { $genre =~ /\Q$_\E/i } @genres;
		}
	}

	return 0;
}

sub pending {
	my $self = shift;

	return 0 unless $self->{client};

	my $queue = eval {
		Slim::Plugin::AudioScrobbler::Plugin::getQueue( $self->{client} );
	};

	return ref $queue eq 'ARRAY' ? scalar @{$queue} : 0;
}

sub would_overflow {
	my ( $self, $count ) = @_;

	return $self->pending + $count > MAX_PENDING;
}

# Append to LMS's queue and hand it back to LMS.
#
# Plugin::submitScrobble is the gatekeeper, not $api->submitScrobble: it kills
# pending timers, drops the queue if scrobbling was disabled, resolves the
# account, and re-enters itself after a handshake or an HTTP retry. Its own
# retry path drops its callback, so what is known here is that the items were
# queued -- never that Last.fm accepted them.
sub enqueue {
	my ( $self, $items ) = @_;

	return 0 unless $self->{status} eq 'ok' && ref $items eq 'ARRAY' && @{$items};

	my $client = $self->{client};

	my $queue = [
		@{ Slim::Plugin::AudioScrobbler::Plugin::getQueue($client) || [] },
		@{$items},
	];

	# Oldest first, so leftovers from an earlier request go out before this
	# one's, as they do through LMS's own queue.
	$queue = [ sort { $a->{i} <=> $b->{i} } @{$queue} ];

	my $ok = eval {
		Slim::Plugin::AudioScrobbler::Plugin::setQueue( $client, $queue );
		Slim::Plugin::AudioScrobbler::Plugin::submitScrobble( $client, {} );
		1;
	};

	if ( !$ok ) {
		$log->error(
			'history scrobbler: submission for ' . $self->{playerid}
			. ' failed: ' . ( $@ || 'unknown error' ) );
		return 0;
	}

	return scalar @{$items};
}

# Hand the batch's newest play to the API as now-playing, if it is still
# playing.
#
# `played` is the instant the track started, so the server's clock being
# inside the track's duration is what makes it the present tense: a report
# that arrives after the track ended announces nothing. No duration means no
# way to judge, and announcing on a guess would show the wrong track. The
# item decides eligibility: a track LMS would not scrobble is not announced
# either, which is the one deliberate difference from LMS's newsongCallback
# -- it announces before applying the ignore lists.
#
# Called after the scrobbles were queued, so a scrobble does not clobber the
# display. The scrobble's HTTP response is not waited for -- the queue
# retries in the background, and a failing scrobble must not delay the
# present tense.
sub nowPlaying {
	my ( $self, $entry, $item, $now ) = @_;

	return 'unavailable' unless $self->{status} eq 'ok' && $self->{client};
	return 'unavailable' unless $item;

	my $duration = $item->{l} || 0;
	return 'skipped' unless $duration;

	$now ||= time();
	return 'skipped' if $now - $entry->{played} >= $duration;

	my $api = eval {
		require Slim::Plugin::AudioScrobbler::API;
		Slim::Plugin::AudioScrobbler::API->getAPI( $self->{client} );
	};

	if ( !$api ) {
		$log->error(
			'history scrobbler: no API for ' . $self->{playerid}
			. ': ' . ( $@ || 'unknown error' ) );
		return 'unavailable';
	}

	my $ok = eval { $api->submitNowPlaying( $entry->{track} ); 1 };

	if ( !$ok ) {
		$log->error(
			'history scrobbler: now-playing for ' . $self->{playerid}
			. ' failed: ' . ( $@ || 'unknown error' ) );
		return 'unavailable';
	}

	return 'requested';
}

1;
