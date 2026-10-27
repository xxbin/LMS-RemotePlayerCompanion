package Plugins::RemotePlayerCompanion::History::Targets::Stats;

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
#
# A target: new($ctx), name, status, apply(\@plays). The batch interface is
# described in History::Targets.

use strict;
use warnings;

use Slim::Music::Import;

sub new {
	my ( $class, $ctx ) = @_;

	return bless { ctx => $ctx }, $class;
}

sub name { return 'lms' }

# The play count has no switch of its own: whether it updates is decided per
# entry (statistics off, a scan running, no tracks_persistent row).
sub status { return 'ok' }

sub apply {
	my ( $self, $entries ) = @_;

	my @results;

	for my $entry ( @{$entries} ) {
		my $result = eval { $self->_record($entry) };

		if ( !$result ) {
			my $error = $@ || 'unknown error';
			push @results, { status => 'error', detail => $error };
			next;
		}

		if ( $result->{status} eq 'ok' ) {
			push @results, {
				status => 'ok',
				detail => 'playcount=' . ( 0 + $result->{playcount} )
					. ' lastplayed=' . ( 0 + $result->{lastplayed} ),
			};
		}
		else {
			push @results, { status => 'skipped', detail => $result->{status} };
		}
	}

	return \@results;
}

sub _record {
	my ( $self, $entry ) = @_;

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