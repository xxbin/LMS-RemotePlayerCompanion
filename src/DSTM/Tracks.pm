package Plugins::RemotePlayerCompanion::DSTM::Tracks;

# Turning ids and entity URLs into playable track URLs.
#
# Two entry points need this and neither owns it: randomplay:// recipes,
# which may name an album or a contributor rather than a track, and the
# db: entity URLs that some providers emit. Both end up asking the same
# question -- "give me the tracks of this album / contributor / work" -- so
# the answer lives here.

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Slim::Control::Queries;
use Slim::Player::Playlist;
use Slim::Schema;
use Slim::Utils::Log;

my $log = logger('plugin.remoteplayercompanion');

use constant TRACK_WHERE => '(tracks.audio = 1 AND tracks.content_type NOT IN ("cpl", "src", "ssp", "dir"))';

# A track id -> a playable URL. Ids come back from the queries below; a value
# that is not a plain number is already a URL, so it passes through.
sub urlForId {
	my ( $class, $id ) = @_;

	return $id unless defined $id && $id =~ /^\d+$/;

	my $track = eval { Slim::Schema->resultset('Track')->find($id) };

	return unless $track;

	return eval { $track->url };
}

# The shuffled track ids of a single entity.
#
# $entity is an album id, a contributor id, or -- for a work -- either the
# [album id, work id, performance] triple that RandomPlay's album query
# returns, or a bare work id as db:work.id=... carries.
sub tracksForEntity {
	my ( $class, $kind, $entity ) = @_;

	my %args = ( where => TRACK_WHERE );

	if ( $kind eq 'album' ) {
		$args{albumId} = $entity;
	}
	elsif ( $kind eq 'contributor' ) {
		$args{contributorId} = $entity;
	}
	elsif ( $kind eq 'work' ) {
		my ( $workId, $performance ) = ref $entity eq 'ARRAY'
			? ( $entity->[1], $entity->[2] )
			: ( $entity,      undef );

		return [] unless defined $workId;

		$args{workId}      = $workId;
		$args{performance} = $performance if defined $performance;
	}
	else {
		return [];
	}

	my ( $results, $idList ) = Slim::Control::Queries::_getTagDataForTracks( 'II', \%args );

	my $ids = $idList || [];

	Slim::Player::Playlist::fischer_yates_shuffle($ids);

	return $ids;
}

# Expand a 'db:<entity>' URL into the tracks it stands for.
#
# Some providers answer with these instead of with tracks: a favourite or a
# playlist entry that is an album, a contributor or a work rather than a
# single song. A real player expands them through its playlist commands; a
# queue has no player, so we do it here.
#
# Returns ($urls, undef) or (undef, $reason). Genre, year and playlist URLs
# are refused rather than guessed at -- each needs a different expansion a
# provider has not yet been seen to ask for.
sub expandDb {
	my ( $class, $url, $want ) = @_;

	my $obj = eval { Slim::Schema->objectForUrl($url) };

	return ( undef, 'UNRESOLVED_ENTITY' ) unless blessed $obj;

	my $kind =
		  $obj->isa('Slim::Schema::Album')       ? 'album'
		: $obj->isa('Slim::Schema::Contributor') ? 'contributor'
		: $obj->isa('Slim::Schema::Work')        ? 'work'
		:                                          undef;

	return ( undef, 'UNSUPPORTED_ENTITY' ) unless $kind;

	my $ids = $class->tracksForEntity( $kind, $obj->id );

	splice @{$ids}, $want if $want && scalar @{$ids} > $want;

	return ( [ map { $class->urlForId($_) } grep { defined } @{$ids} ], undef );
}

1;
