package Plugins::RemotePlayerCompanion::History::Targets::ListeningHistory;

# Listening History (CrystalGipsy's plugin) -- its own entries and plays.
#
# That plugin records live plays in Tracker::_record, but there is no public
# "record this play" seam: _record needs a live client and playingSong, stamps
# the wall clock, and maintains the plugin's in-memory session. A report is a
# backfill with its own start times, so the write goes through the storage
# layer Tracker::_record itself calls:
#
#   Plugins::ListeningHistory::DB::addEntry
#   Plugins::ListeningHistory::DB::addToEntry
#
# The row is built by the plugin's own Sources::describe, so its rules for
# source, title, stations and album identity are the plugin's, not copies. We
# supply the synthetic client and a two-method song shim, and take the
# reported start as both started_at and played_at.
#
# A target: new($ctx), name, status, apply(\@plays). The batch interface is
# described in History::Targets.

use strict;
use warnings;

use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

use Plugins::RemotePlayerCompanion::History::VClient;

my $prefs = preferences('plugin.listeninghistory');

# Probed, not assumed. The plugin has to be enabled and loaded, not merely
# installed: writing rows for a plugin the user turned off would be a side
# effect they did not ask for. The functions are probed too, so a version
# whose storage interface differs is `unavailable` rather than a stream of
# errors.
my $available;

sub available {
	return $available if defined $available;

	$available = 0;

	return $available unless eval {
		Slim::Utils::PluginManager->isEnabled('Plugins::ListeningHistory::Plugin');
	};

	$available = eval {
		require Plugins::ListeningHistory::DB;
		require Plugins::ListeningHistory::Sources;

		Plugins::ListeningHistory::DB->can('addEntry')
			&& Plugins::ListeningHistory::DB->can('addToEntry')
			&& Plugins::ListeningHistory::Sources->can('describe')
			? 1
			: 0;
	} ? 1 : 0;

	return $available;
}

sub new {
	my ( $class, $ctx ) = @_;

	my $self = bless { ctx => $ctx }, $class;

	# Open the store before the first write, as the plugin itself does at
	# startup. A store that cannot be opened is `unavailable`, not one error
	# per play.
	my $ok = $class->available
		&& eval { Plugins::ListeningHistory::DB::dbh() ? 1 : 0 };

	$self->{status} = $ok ? 'ok' : 'unavailable';

	return $self;
}

sub name { return 'listeninghistory' }

sub status { return $_[0]->{status} }

sub apply {
	my ( $self, $entries ) = @_;

	my @results = map {
		{ status => 'error', detail => 'not processed' }
	} @{$entries};

	return \@results unless $self->{status} eq 'ok';

	my $playerid   = $self->{ctx}{playerid};
	my $playername = $self->{ctx}{playername};
	$playername = $playerid
		unless defined $playername && length $playername;

	# Sources::describe takes the client a real track would have. The
	# scrobbler already creates this same synthetic client; a server without
	# AudioScrobbler gets it here, for the handler metadata alone.
	my $client = eval {
		Plugins::RemotePlayerCompanion::History::VClient->forPlayer($playerid);
	};

	if ( !$client ) {
		my $error = $@ || 'unknown error';
		$error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
		$_ = { status => 'error', detail => 'client: ' . $error }
			for @results;
		return \@results;
	}

	# Plays are grouped by album in time order, but the answer stays aligned
	# with the request: the caller sent them in its own order.
	my @order = sort {
		$entries->[$a]{played} <=> $entries->[$b]{played} || $a <=> $b
	} 0 .. $#{$entries};

	my $gap = ( $prefs->get('session_gap_min') // 30 ) * 60;

	$self->{session} = undef;

	for my $i (@order) {
		my $result = eval {
			$self->_record( $client, $entries->[$i], $playername, $gap );
		};

		if ( !$result ) {
			my $error = $@ || 'unknown error';
			$error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
			$result = { status => 'error', detail => $error };
		}

		$results[$i] = $result;
	}

	return \@results;
}

sub _record {
	my ( $self, $client, $entry, $playername, $gap ) = @_;

	my $url    = $entry->{url};
	my $track  = $entry->{track};
	my $played = $entry->{played};

	# Sources::describe's fourth argument is a playing song, not a track: it
	# asks it for duration (a library play) and streamUrl (Radio Paradise's
	# announcement check). This shim answers both from the report.
	my $song = bless {
		url      => $url,
		duration => eval { $track->secs } || 0,
	}, 'Plugins::RemotePlayerCompanion::History::Targets::ListeningHistory::Song';

	my ( $d, $why ) =
		Plugins::ListeningHistory::Sources::describe( $client, $song, $track, $url );

	return { status => 'skipped', detail => $why || 'not recordable' }
		unless $d;

	# A station is not a track to find again; it only ends the album session,
	# exactly as the live tracker treats it.
	if ( $d->{is_station} ) {
		$self->{session} = {
			kind    => 'station',
			url     => $d->{url},
			last_at => $played,
		};

		return { status => 'skipped', detail => 'station' };
	}

	my $play = {
		url       => $d->{url},
		title     => $d->{title},
		artist    => $d->{artist},
		album     => $d->{album},
		duration  => $d->{duration},
		played_at => $played,
	};

	my $session = $self->{session};
	my $end     = $played + ( $d->{duration} || 0 );

	# The live tracker groups consecutive tracks of one album into one entry
	# while the next starts within session_gap_min of the previous being
	# recorded. A backfill has no record instant, so the previous play's end
	# is the closest equivalent: a two-minute gap after a track is a gap, not
	# an overlap after its start.
	if ( $session
		&& ( $session->{kind} // '' ) ne 'station'
		&& defined $d->{album_key}
		&& defined $session->{album_key}
		&& $session->{album_key} eq $d->{album_key}
		&& !$session->{urls}{ $d->{url} }
		&& $played - $session->{last_at} <= $gap )
	{
		my $promote = $session->{kind} eq 'track' ? {
			artist      => $d->{album_artist} // $d->{artist},
			album       => $d->{album},
			year        => $d->{year},
			artwork     => $d->{artwork},
			track_total => $d->{track_total},
			ref         => $d->{ref},
		} : undef;

		if ( Plugins::ListeningHistory::DB::addToEntry(
				$session->{entry_id}, $play, $promote ) )
		{
			$session->{kind} = 'album';
			$session->{urls}{ $d->{url} } = 1;
			$session->{last_at} = $end;

			return {
				status => 'ok',
				detail => 'entry ' . $session->{entry_id} . ' album',
			};
		}

		# The entry was removed while the album played: start afresh below.
	}

	my $id = Plugins::ListeningHistory::DB::addEntry(
		{
			player_id   => $self->{ctx}{playerid},
			player_name => $playername,
			kind        => 'track',
			source      => $d->{source},
			artist      => $d->{artist},
			album       => $d->{album},
			title       => $d->{title},
			year        => $d->{year},
			artwork     => $d->{artwork},
			url         => $d->{url},
			album_key   => $d->{album_key},
			track_total => $d->{track_total},
			ref         => $d->{ref},
			started_at  => $played,
			played_at   => $played,
		},
		$play,
	);

	return { status => 'error', detail => 'addEntry failed' } unless $id;

	$self->{session} = {
		entry_id  => $id,
		kind      => 'track',
		album_key => $d->{album_key},
		url       => $d->{url},
		urls      => { $d->{url} => 1 },
		last_at   => $end,
	};

	return { status => 'ok', detail => 'entry ' . $id . ' track' };
}

# The two methods Sources::describe asks a song for. A report has no playing
# song; it has a URL and (for a library track) the track's own length.
package Plugins::RemotePlayerCompanion::History::Targets::ListeningHistory::Song;

sub duration  { return $_[0]->{duration} }
sub streamUrl { return $_[0]->{url} }

1;