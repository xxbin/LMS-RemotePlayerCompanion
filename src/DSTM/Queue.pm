package Plugins::RemotePlayerCompanion::DSTM::Queue;

# The queue: its records, and the buffer operations on them.
#
# A record is a bounded rolling buffer of track URLs. The consumer takes
# from the head (nextbatch) and Refill appends to the tail, so the buffer
# never exceeds 'max' and nothing is ever silently trimmed away.
#
# Records are keyed by playerid and never created implicitly: a record
# exists only after a 'config' call.

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

my $log   = logger('plugin.remoteplayercompanion');

# A namespace of our own, with an explicit version.
#
# The default 'cache' namespace is not durable: its version marker never
# reads back on this LMS, so Slim::Utils::Cache::new() decides the version
# changed and clears the whole namespace on every server start. Queue
# records have to outlive a restart -- that is the whole point of a
# configured queue -- so they live in their own namespace, whose version we
# control and bump only when the record layout changes incompatibly.
# Bump this whenever the record layout changes shape. Records written by an
# older version cannot be read by a newer one, and the version check in
# Slim::Utils::Cache::new() clears the namespace rather than leaving
# unreadable records behind. Version 2 renamed the record's player_id field
# to playerid, matching LMS's spelling.
my $cache = Slim::Utils::Cache->new( 'remoteplayercompanion', 2 );

use constant KEY_PREFIX  => 'rpc_queue_';
use constant SEEN_HARD   => 5000;    # dedup memory ceiling
use constant SEEN_KEEP   => 2500;    # how many of the newest survive a prune

# How deep a queue is when nothing says otherwise. The record owns this value:
# CLI reads it from here rather than keeping a second copy that could drift.
use constant DEFAULT_MAX => 50;

sub _key { KEY_PREFIX . $_[0] }

sub load {
	my ( $class, $playerid ) = @_;

	return unless defined $playerid && length $playerid;

	return $cache->get( _key($playerid) );
}

sub save {
	my ( $class, $rec ) = @_;

	# The record carries its own key, so a record that lost that field would
	# silently be stored under a garbage key and every later load would miss
	# it. Refuse rather than corrupt the queue.
	my $playerid = $rec->{playerid};

	unless ( defined $playerid && length $playerid ) {
		$log->error('refusing to save a queue record with no playerid');
		return;
	}

	$rec->{updated} = time;

	$cache->set( _key($playerid), $rec, 'never' );

	return $rec;
}

sub create {
	my ( $class, $playerid, %opt ) = @_;

	my $rec = {
		playerid   => $playerid,
		provider   => $opt{provider},
		max        => $opt{max} || DEFAULT_MAX,
		tracks     => [],
		seed       => [],
		seen       => {},
		created    => time,
		updated    => time,
		last_error => undef,
	};

	return $class->save($rec);
}

# What the provider should derive from: the seed plus whatever the buffer
# holds. The seed is not queue content -- see seed() below -- but a provider
# that reads the queue should still see it, or a queue built around a track
# would stop looking like it.
sub playlist {
	my ( $class, $rec ) = @_;

	return [ @{ $rec->{seed} || [] }, @{ $rec->{tracks} || [] } ];
}

# The derivation material an explicit seed set, as opposed to the buffer.
#
# '||=' rather than a plain read is what lets a record written before this
# field existed read as empty. That one line is why the cache namespace
# version does not have to move.
sub seed {
	my ( $class, $rec ) = @_;

	return $rec->{seed} ||= [];
}

# Replace the derivation material with a named track.
#
# Replaces rather than appends: "I am playing this now" is a statement about
# the present, not an accumulation.
sub setSeed {
	my ( $class, $rec, $url ) = @_;

	$rec->{seed} = [ $url ];

	return $rec;
}

sub destroy {
	my ( $class, $playerid ) = @_;

	$cache->remove( _key($playerid) );
}

# --- buffer operations ----------------------------------------------------

# Append URLs, skipping anything this queue has already held or served, and
# stopping once the buffer reaches $limit so it never overshoots 'max'.
# Returns the number actually appended.
sub add {
	my ( $class, $rec, $urls, $limit ) = @_;

	my $seen = $rec->{seen} ||= {};
	my $added = 0;

	for my $url ( @{ $urls || [] } ) {
		last if defined $limit && scalar( @{ $rec->{tracks} } ) >= $limit;

		next unless defined $url && length $url;
		next if $seen->{$url};

		push @{ $rec->{tracks} }, $url;
		$seen->{$url} = time;
		$added++;
	}

	$class->_pruneSeen($seen) if scalar( keys %{$seen} ) > SEEN_HARD;

	return $added;
}

# Hand out up to $count URLs from the head of the buffer. They stay in the
# dedup memory so Refill cannot immediately re-serve the same track.
sub take {
	my ( $class, $rec, $count ) = @_;

	my $tracks = $rec->{tracks} ||= [];

	$count = scalar @{$tracks} if $count > scalar @{$tracks};

	return [ splice @{$tracks}, 0, $count ];
}

sub clear {
	my ( $class, $rec ) = @_;

	my $removed = scalar @{ $rec->{tracks} || [] };

	$rec->{tracks} = [];
	$rec->{seen}   = {};

	return $removed;
}

sub total {
	my ( $class, $rec ) = @_;

	return scalar @{ $rec->{tracks} || [] };
}

sub _pruneSeen {
	my ( $class, $seen ) = @_;

	my @urls = sort { $seen->{$b} <=> $seen->{$a} } keys %{$seen};

	splice @urls, SEEN_KEEP;

	my %keep = map { $_ => $seen->{$_} } @urls;

	%{$seen} = %keep;

	return;
}

1;
