package Plugins::RemotePlayerCompanion::History::Targets::APC;

# Alternative Play Count's own record of a play.
#
# APC's external-report command is the interface it provides for a player that
# is not an LMS client: `alternativeplaycount reportplayback` takes a track id,
# a player id and a percentage played, and applies APC's own rules -- its play
# count, lastPlayed, the Play History row, the dynamic played/skipped value and,
# when configured, auto-rating. `percentplayed:100` is above APC's threshold
# (validated to 10..90), so a reported play is always counted. The remote
# player decided it was a play; the server has no progress to judge.
#
# The command stamps "now", though, and a reported play may be days old. The
# two places that carry the play time are read before the call and corrected
# after it, and only when they differ: the history row's `played`, and
# `lastPlayed`, which becomes max(its previous value, the reported time) so a
# backlog cannot move the clock forward and an out-of-order report cannot move
# it back. Everything else -- the count, the rating, the dynamic value -- is
# APC's own, written by APC's own code.
#
# An entry that resolves to no library track -- a URL only an ephemeral
# RemoteTrack answers for -- has no id to report and is left alone. APC would
# not have a count row for it either.
#
# A target: new($ctx), name, status, apply(\@plays). The batch interface is
# described in History::Targets.

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

my $log   = logger('plugin.remoteplayercompanion');
my $prefs = preferences('plugin.alternativeplaycount');

# `reportplayback` refuses a player id longer than this. A remote player id
# may be up to 64 characters; the longer ones are left unrecorded rather than
# truncated into a different player's row.
use constant MAX_PLAYER_ID => 40;

# Probed, not assumed: APC is optional. A server without it -- or with it
# installed but switched off -- gets a logged `unavailable`, not a failed
# report. `require` alone would say yes to a disabled plugin: every installed
# plugin is on @INC whether LMS loaded it or not.
my $available;

sub available {
	return $available if defined $available;

	$available =
		   eval { Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin') }
		&& eval { require Plugins::AlternativePlayCount::Storage; 1 }
			? 1 : 0;

	return $available;
}

# The play-history extras -- the row correction and the player row -- exist
# only while APC itself is recording a history. The counts are updated either
# way: `reportplayback` counts whether or not that preference is on.
sub _playhistory {
	my $class = shift;

	return eval { $prefs->get('playhistory') } ? 1 : 0;
}

sub new {
	my ( $class, $ctx ) = @_;

	my $self = bless { ctx => $ctx }, $class;

	$self->{status} = $class->available ? 'ok' : 'unavailable';

	return $self;
}

sub name { return 'apc' }

sub status { return $_[0]->{status} }

sub apply {
	my ( $self, $entries ) = @_;

	my @results;
	my $saved    = 0;
	my $class    = ref $self;
	my $playerid = $self->{ctx}{playerid};

	# `reportplayback` saves the player itself, with no model and with a NULL
	# name when the request carried none. Resolve the name once here, so every
	# call writes the same one and no call wipes the name APC already had.
	$self->{playername} = $self->_playerName($playerid);

	for my $entry ( @{$entries} ) {
		my $status = eval { $self->_record( $entry, $playerid ) };

		if ( !$status ) {
			my $error = $@ || 'unknown error';
			$log->error("history apc: reportplayback failed: $error");
			push @results, { status => 'error', detail => $error };
			next;
		}

		if ( $status eq 'ok' ) {
			push @results, { status => 'ok', detail => '' };
			$saved = 1;
		}
		else {
			push @results, { status => 'skipped', detail => $status };
		}
	}

	# Once per request, after the last row landed -- not once per track. It
	# puts APC's `remote` model back, which `reportplayback` itself leaves
	# unset, and it may well be the call that writes the final name. With play
	# history off there is no player list to keep, and `reportplayback` wrote
	# neither the row nor the player.
	$self->savePlayer( $playerid, $self->{playername} )
		if $saved && $class->_playhistory;

	return \@results;
}

sub _record {
	my ( $self, $entry, $playerid ) = @_;

	my $class = ref $self;

	return 'unavailable' unless $class->available;

	my $track = $entry->{track};

	# Only a library track has an id, and the external report is addressed by
	# one. An ephemeral RemoteTrack is not something APC could count.
	my $trackid = eval { $track->id };

	return 'no_track_id'
		unless defined $trackid && $trackid =~ /^\d+$/ && $trackid > 0;

	return 'player_id_too_long' if length($playerid) > MAX_PLAYER_ID;

	# Read before the call: the command records the moment it runs. The count
	# rows are found by APC's own rule, because `allmusicbrainzidversions` can
	# update every version of a recording, not only this URL. The history row
	# only exists when APC is recording history at all.
	my $playhistory    = $class->_playhistory;
	my $history_before = $playhistory ? $self->_historyMaxId : 0;
	my $lastplayed     = $self->_countRows( $entry, $track );

	my @params = (
		'alternativeplaycount', 'reportplayback',
		'mac:'          . $playerid,
		'playername:'   . $self->{playername},
		'trackid:'      . $trackid,
		'percentplayed:100',
	);

	# One flat command array, as the CLI would send it; a client is undef
	# because this command is registered with needsClient = 0.
	my $request = Slim::Control::Request::executeRequest( undef, \@params );

	return 'reportplayback_refused'
		unless $request && $request->isStatusDone;

	$self->_restoreHistoryRow( $history_before, $entry->{played} )
		if $playhistory;
	$self->_restoreLastPlayed( $lastplayed, $entry->{played} );

	return 'ok';
}

sub _playerName {
	my ( $self, $playerid ) = @_;

	my $name = $self->{ctx}{playername};

	return $name if defined $name && length $name;

	return eval { Plugins::AlternativePlayCount::Storage->getPlayerName($playerid) }
		|| $playerid;
}

# The newest play_history row, so the row this call writes can be recognised.
# `reportplayback` runs synchronously and nothing else writes between the two
# reads, so a larger maximum is this call's row.
sub _historyMaxId {
	my $self = shift;

	my $dbh = eval { Plugins::AlternativePlayCount::Storage->dbh };
	return 0 unless $dbh;

	my $id = eval { $dbh->selectrow_array('SELECT ifnull(max(id), 0) FROM play_history') };

	return $id || 0;
}

sub _restoreHistoryRow {
	my ( $self, $before, $played ) = @_;

	my $dbh = eval { Plugins::AlternativePlayCount::Storage->dbh };
	return unless $dbh;

	# The row APC has just inserted, if there is one.
	my $row = eval {
		$dbh->selectrow_arrayref(
			'SELECT id, played FROM play_history ORDER BY id DESC LIMIT 1' );
	};
	return unless $row && $row->[0] && $row->[0] > $before;

	# Only what the command got wrong: the play time. Its rating is left as
	# APC wrote it. With a play reported as it happens, `now` is the play time
	# and there is nothing to do.
	return if defined $row->[1] && $row->[1] == $played;

	eval {
		$dbh->do(
			'UPDATE play_history SET played = ? WHERE id = ?',
			undef, $played, $row->[0] );
	};
	$log->error("history apc: correcting the play row failed: $@") if $@;

	return;
}

# The alternativeplaycount rows `reportplayback` will update, with their
# lastPlayed before the call. Returns an arrayref of [rowid, lastPlayed].
sub _countRows {
	my ( $self, $entry, $track ) = @_;

	my $dbh  = Slim::Schema->dbh;
	my $mbid = eval { $track->musicbrainz_id } || '';

	# APC's own getTrackMBID and validation: an id without a dash is not a
	# MusicBrainz recording id, and one outside this alphabet falls back to
	# the URL. Either way the row is found by urlmd5, then by url.
	$mbid = ''
		if !$mbid || $mbid !~ /-/ || $mbid !~ /^[a-zA-Z0-9\-]+$/;

	my $by_mbid = $prefs->get('allmusicbrainzidversions') && $mbid;

	my $rows = eval {
		$dbh->selectall_arrayref(
			$by_mbid
				? 'SELECT rowid, ifnull(lastPlayed, 0) FROM alternativeplaycount WHERE musicbrainz_id = ?'
				: 'SELECT rowid, ifnull(lastPlayed, 0) FROM alternativeplaycount WHERE urlmd5 = ?',
			undef,
			$by_mbid ? $mbid : $entry->{urlmd5},
		) || [];
	} || [];

	# _updateAPCbyUrlmd5OrUrl falls back to the URL when no row matched its md5.
	if ( !@{$rows} && !$by_mbid ) {
		# The track's own url, which is what the command updates by.
		my $url = eval { $track->url } || $entry->{url};

		$rows = eval {
			$dbh->selectall_arrayref(
				'SELECT rowid, ifnull(lastPlayed, 0) FROM alternativeplaycount WHERE url = ?',
				undef, $url ) || [];
		} || [];
	}

	return $rows;
}

sub _restoreLastPlayed {
	my ( $self, $rows, $played ) = @_;

	return unless $rows && @{$rows};

	my $dbh = Slim::Schema->dbh;

	for my $row ( @{$rows} ) {
		my ( $rowid, $last ) = @{$row};

		my $value = ( $last && $last > $played ) ? $last : $played;

		# Only when the command's "now" actually differs. A play reported as
		# it happens lands on the same second and needs no write at all.
		my $current = eval {
			$dbh->selectrow_array(
				'SELECT lastPlayed FROM alternativeplaycount WHERE rowid = ?',
				undef, $rowid );
		};
		next if defined $current && $current == $value;

		eval {
			$dbh->do(
				'UPDATE alternativeplaycount SET lastPlayed = ? WHERE rowid = ?',
				undef, $value, $rowid );
		};
		$log->error("history apc: correcting lastPlayed failed: $@") if $@;
	}

	return;
}

# Once per request, after the last row landed. A player's last_seen is "now",
# not the play time: a six-day-old play reported today still means the player
# was seen today. The name is the one resolved before the first report.
sub savePlayer {
	my ( $class, $playerid, $playername ) = @_;

	return unless $class->available;

	eval {
		my $name = $playername
			|| Plugins::AlternativePlayCount::Storage->getPlayerName($playerid)
			|| $playerid;

		Plugins::AlternativePlayCount::Storage->savePlayer(
			{
				mac       => $playerid,
				name      => $name,
				model     => 'remote',
				last_seen => int(time),
			}
		);
	};

	$log->error("history apc: savePlayer failed: $@") if $@;

	return;
}

1;