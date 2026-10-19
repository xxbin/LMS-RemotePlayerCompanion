package Plugins::RemotePlayerCompanion::History::Track;

# One reported entry, resolved to what the destinations need.
#
# An id is a lookup in the library. A url is either a library object or, for
# a remote URL LMS has never seen, an ephemeral RemoteTrack -- enough for
# AudioScrobbler's metadata lookup and for APC's url, and never inserted into
# the library.

use strict;
use warnings;

use Slim::Music::Info;
use Slim::Schema;
use Slim::Utils::Misc;

use Plugins::RemotePlayerCompanion::DSTM::Tracks;

sub resolve {
	my ( $class, $value, $is_id ) = @_;

	return unless defined $value && length $value;

	my $url;

	if ($is_id) {
		$url = Plugins::RemotePlayerCompanion::DSTM::Tracks->urlForId($value);
		return unless defined $url && length $url;
	}
	else {
		$url = $value;
	}

	my $track = eval { Slim::Schema->objectForUrl( { url => $url } ) };

	if ( !$track && Slim::Music::Info::isRemoteURL($url) ) {
		$track = eval { Slim::Schema::RemoteTrack->new($url) };
	}

	return $track ? $class->entry( $url, $track ) : undef;
}

# A resolved entry, from a URL and the object that answered for it.
sub entry {
	my ( $class, $url, $track ) = @_;

	my $urlmd5 = eval { $track->urlmd5 };
	$urlmd5 ||= Slim::Utils::Misc::safe_md5_hex($url);

	return {
		url     => $url,
		track   => $track,
		urlmd5  => $urlmd5,
		remote  => ( Slim::Music::Info::isRemoteURL($url) ? 1 : 0 ),
	};
}

1;