package Plugins::RemotePlayerCompanion::History::Stats;

# LMS's play count, updated the way LMS updates it.
#
# Slim::Player::Song::open increments tracks_persistent.playcount and sets
# lastplayed = time() on a real play; this mirrors that, minus the seek
# condition (a reported play is not a stream seeked into) and taking the
# reported play time instead of the wall clock.
#
# lastplayed only moves forward. An out-of-order submission is still a play
# that happened -- the count increments -- but it does not move the clock
# backwards.

use strict;
use warnings;

use Slim::Music::Import;

sub apply {
	my ( $class, $entry ) = @_;

	my $track = $entry->{track};

	return { status => 'no_record' }
		unless $track && $track->can('retrievePersistent');

	return { status => 'statistics_off' } unless main::STATISTICS;

	return { status => 'scanning' } if Slim::Music::Import->stillScanning();

	my $persistent = $track->retrievePersistent;

	return { status => 'no_record' } unless $persistent;

	my $played   = $entry->{played};
	my $previous = $persistent->lastplayed || 0;

	$persistent->set( playcount => ( $persistent->playcount || 0 ) + 1 );
	$persistent->set(
		lastplayed => $played > $previous ? $played : $previous );
	$persistent->update;

	return {
		status     => 'ok',
		playcount  => 0 + ( $persistent->playcount || 0 ),
		lastplayed => 0 + ( $persistent->lastplayed || 0 ),
	};
}

1;
