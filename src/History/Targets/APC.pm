package Plugins::RemotePlayerCompanion::History::Targets::APC;

# Alternative Play Count's Play History -- the table that explicitly accepts
# entries its analyser did not produce.
#
# Nothing else in APC is touched: not the counts table (tied to APC's own
# threshold and skip handling), not dynamic played/skipped values, not auto
# rating. A play imported after the fact has no skip history, and a rating
# imported with a present-day value would be a rating given *after* the
# listen. Only the row.
#
# A target: new($ctx), name, status, apply(\@plays). The batch interface is
# described in History::Targets.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.remoteplayercompanion');
my $prefs = preferences('plugin.alternativeplaycount');

# Probed, not assumed: APC is optional. A server without it gets a logged
# `unavailable`, not a failed report.
my $available;

sub available {
	return $available if defined $available;

	$available = eval { require Plugins::AlternativePlayCount::Storage; 1 } ? 1 : 0;

	return $available;
}

sub enabled {
	my $class = shift;

	return 0 unless $class->available;

	my $enabled = eval { $prefs->get('playhistory') };

	return $enabled ? 1 : 0;
}

sub new {
	my ( $class, $ctx ) = @_;

	my $self = bless { ctx => $ctx }, $class;

	$self->{status} =
		  !$class->available ? 'unavailable'
		: !$class->enabled   ? 'disabled'
		:                      'ok';

	return $self;
}

sub name { return 'apc' }

sub status { return $_[0]->{status} }

sub apply {
	my ( $self, $entries ) = @_;

	my @results;
	my $saved = 0;

	for my $entry ( @{$entries} ) {
		my $status = eval { $self->_record( $entry, $self->{ctx}{playerid} ) };

		if ( !$status ) {
			my $error = $@ || 'unknown error';
			$log->error("history apc: addPlayEntry failed: $error");
			push @results, { status => 'error', detail => $error };
			next;
		}

		if ( $status eq 'ok' ) {
			push @results, { status => 'ok', detail => '' };

			# The player is recorded once per request, after the first row
			# that landed -- not once per track.
			if ( !$saved ) {
				$self->savePlayer( $self->{ctx}{playerid},
					$self->{ctx}{playername} );
				$saved = 1;
			}
		}
		else {
			push @results, { status => 'skipped', detail => $status };
		}
	}

	return \@results;
}

sub _record {
	my ( $self, $entry, $playerid ) = @_;

	my $class = ref $self;

	return 'unavailable' unless $class->available;
	return 'disabled'    unless $class->enabled;

	my $track = $entry->{track};

	my $musicbrainz_id = eval { $track->musicbrainz_id } || '';

	my $ok = eval {
		Plugins::AlternativePlayCount::Storage->addPlayEntry(
			{
				url            => $entry->{url},
				urlmd5         => $entry->{urlmd5},
				musicbrainz_id => $musicbrainz_id,

				# The reported start, unchanged. APC records the instant its
				# own threshold was met, so a native row and an imported row
				# for one listen can differ by a fraction of the track.
				played  => $entry->{played},
				rating  => undef,
				remote  => $entry->{remote},
				client_id => $playerid,
			}
		);
	};

	die $@ if $@;

	# addPlayEntry answers undef when its database is not initialized.
	return 'disabled' unless $ok;

	return 'ok';
}

# Once per request, after the first row landed. A player's last_seen is
# "now", not the play time: a six-day-old play reported today still means
# the player was seen today. The name is kept unless the request names one.
sub savePlayer {
	my ( $class, $playerid, $playername ) = @_;

	return unless $class->available && $class->enabled;

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