package Plugins::RemotePlayerCompanion::DSTM::Refill;

# Keeps a queue topped up to its 'max'.
#
# Filling is decoupled from serving: 'config' kicks a fill and returns at
# once, and every 'nextbatch' kicks another one for the tail it just took.
#
# ===========================================================================
# How an asynchronous provider's result reaches the queue
# ===========================================================================
#
# A DSTM provider delivers its tracks by calling the callback it is handed:
#
#     $handler->( $client, sub { my ($client, $tracks) = @_; ... } );
#
# There is no separate "async result" to go and collect. The tracks always
# come back through that one callback -- the closure DSTM::Provider::invoke
# passed in. What differs between providers is only *when* control comes
# back:
#
#   synchronous provider                asynchronous provider
#   --------------------------------    --------------------------------
#   _step calls invoke                  _step calls invoke
#     handler(...) calls its cb           handler(...) returns immediately,
#       inline, with the tracks             having kept the callback
#     invoke returns                      invoke returns
#   invoke has therefore already        (control goes back to the event loop,
#     called our callback before          and the command that started this
#     it returned                         fill is free to answer)
#                                       ... later ...
#                                       the provider's HTTP call finishes
#                                         and it calls its cb
#                                       invoke's callback runs now
#
#   in both cases: our callback appends the tracks, then _schedule()s the
#   next turn of the loop
#
# So the fill is not a loop that blocks; it is a chain that re-arms itself
# from inside the provider's callback. That is also why the loop must yield
# to the event loop between calls (_schedule): several providers -- every
# RandomPlay token -- answer synchronously, and without that yield the whole
# chain would run to completion inside the command that started it, making
# 'config' block after all.
#
# Three guards keep late or stray results out of the queue:
#
#   * _step's callback re-checks that this fill is still the live one
#     (the state exists, is running, and is the same hash) before writing.
#     A result arriving after the fill ended finds nothing to write to.
#   * _finish and abandon clear `running` and delete the state, so any
#     callback still in flight is discarded rather than acted on.
#   * the budget timer is the only thing that can end a fill which is
#     stuck waiting on a callback that never arrives.
#
# One fill per queue at a time, bounded by a single budget timer. Callers
# that need more than the buffer currently holds register as waiters and are
# woken when the buffer grows enough for them or when the fill ends.

use strict;
use warnings;

use AnyEvent;
use Scalar::Util qw(refaddr);

use Plugins::RemotePlayerCompanion::DSTM::Provider;
use Plugins::RemotePlayerCompanion::DSTM::Queue;
use Plugins::RemotePlayerCompanion::DSTM::VClient;
use Slim::Utils::Log;

my $log = logger('plugin.remoteplayercompanion');

my %state;

use constant MAX_CALLS     => 20;    # provider calls per fill
use constant FILL_BUDGET   => 30;    # seconds for a whole fill
use constant WAIT_BUDGET   => 30;    # seconds a single waiting request may block
use constant GIVE_UP_EMPTY => 2;     # consecutive fruitless calls before we stop

sub isFilling {
	my ( $class, $playerid ) = @_;

	return( $state{$playerid} && $state{$playerid}{running} ) ? 1 : 0;
}

# Start a fill unless one is already running. Returns immediately -- it does
# not wait for the first provider call, let alone for the fill to finish.
# That is what lets 'config' answer straight away even when the provider is
# slow: the work continues after this returns.
sub ensure {
	my ( $class, $playerid ) = @_;

	return if $class->isFilling($playerid);

	my $st = $state{$playerid} = {
		running => 1,
		waiters => [],
		calls   => 0,
		empty   => 0,
	};

	# What this fill is for and what it starts from. Without it the turns below
	# arrive with nothing saying whose they are or what they are aiming at.
	if ( main::DEBUGLOG && $log->is_debug ) {
		my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

		$log->debug( "fill start: $playerid provider="
			. ( $rec && $rec->{provider} ? $rec->{provider} : 'none' )
			. ' target=' . ( $rec ? 0 + $rec->{max} : 0 )
			. ' buffered=' . ( $rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) : 0 )
			. ' max_calls=' . MAX_CALLS . ' budget=' . FILL_BUDGET . 's' );
	}

	# The one bound on a fill. Without it, a provider that accepts the
	# callback and never calls it would leave the queue's fill gate closed
	# forever, and every later fill for this queue would be refused.
	#
	# test/dstm/test_fill_timeout.py is what checks this, and it is currently
	# disabled: reaching the budget takes a provider that hangs, and one is
	# not installed here. The behaviour was verified against a real broken
	# provider before that provider was fixed. Anyone changing the fill loop
	# should re-enable it, or supply a provider that hangs -- this guard
	# failing is silent, and leaves a queue wedged for good.
	$st->{budget} = AnyEvent->timer(
		after => FILL_BUDGET,
		cb    => sub {
			main::INFOLOG && $log->is_info && $log->info("fill budget exhausted for $playerid");
			$class->_finish( $playerid, 'SOURCE_TIMEOUT' );
		},
	);

	$class->_schedule($playerid);

	return;
}

# Register interest in the buffer reaching $need tracks.
#
# $cb->($satisfied, $reason), reason is 'filled' | 'ended' | 'timeout'.
# Called once the buffer holds $need tracks, or the fill ends, or this
# waiter's own budget runs out. This is how a 'nextbatch' that arrived while
# the buffer was short turns into an asynchronous command: it parks here and
# is resumed by _notify from inside the fill's callback.
sub wait {
	my ( $class, $playerid, $need, $cb ) = @_;

	my $st = $state{$playerid};

	# Nothing in flight and not enough buffered: report immediately rather
	# than leaving the caller suspended with nothing that could wake it.
	unless ( $st && $st->{running} ) {
		return $cb->( 0, 'ended' );
	}

	my $w = { need => $need, cb => $cb };

	# Per-waiter budget, not a share of the fill's. A caller that happens to
	# arrive late still gets its own full window.
	$w->{timer} = AnyEvent->timer(
		after => WAIT_BUDGET,
		cb    => sub {
			undef $w->{timer};
			return if $w->{done};
			$w->{done} = 1;
			$class->_dropWaiter( $playerid, $w );
			$cb->( 0, 'timeout' );
		},
	);

	push @{ $st->{waiters} }, $w;

	return;
}

sub _dropWaiter {
	my ( $class, $playerid, $w ) = @_;

	my $st = $state{$playerid} or return;

	my $addr = refaddr($w);

	$st->{waiters} = [ grep { refaddr($_) != $addr } @{ $st->{waiters} } ];

	return;
}

# Re-arm the fill loop on the next event-loop turn.
#
# A zero-delay timer rather than a direct _step() call. For an asynchronous
# provider this costs nothing (we are already inside its callback, and the
# event loop is ours). For a synchronous one it is the whole point: without
# it, the chain would recurse through every provider call before returning
# to whoever called ensure(), and 'config' would block for the full fill.
sub _schedule {
	my ( $class, $playerid ) = @_;

	my $st = $state{$playerid} or return;
	return unless $st->{running};

	$st->{tick} = AnyEvent->timer(
		after => 0,
		cb    => sub {
			# Re-read the state: the fill may have ended, or been replaced,
			# between scheduling this turn and running it.
			my $live = $state{$playerid} or return;
			undef $live->{tick};
			$class->_step($playerid);
		},
	);

	return;
}

# One turn of the fill loop.
#
# This is where an asynchronous provider's result lands. For a synchronous
# provider the callback passed to invoke() fires before invoke() returns, so
# everything below runs inside this same call. For an asynchronous one,
# invoke() returns first and the code below runs later, on whichever event
# loop turn the provider finally calls back on. The body is identical either
# way, which is the point.
sub _step {
	my ( $class, $playerid ) = @_;

	my $st = $state{$playerid} or return;
	return unless $st->{running};

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	return $class->_finish( $playerid, 'GONE' ) unless $rec;

	my $total = Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec);

	# Either of these ends the fill without error: the target is met, or we
	# have spent the call allowance the budget is meant to cover.
	return $class->_finish( $playerid, undef ) if $total >= $rec->{max};
	return $class->_finish( $playerid, undef ) if $st->{calls} >= MAX_CALLS;

	$st->{calls}++;

	# The buffer itself is handed to the provider as its seed, so a provider
	# that derives its selection from the current playlist sees this queue.
	my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new( $playerid, Plugins::RemotePlayerCompanion::DSTM::Queue->playlist($rec) );

	Plugins::RemotePlayerCompanion::DSTM::Provider->invoke( $rec, $vClient, sub {
		my ( $urls, $err ) = @_;

		# --- this is the asynchronous resume point ---
		#
		# If the budget timer already ended this fill, or another fill has
		# since replaced this one, the result is stale: drop it. Comparing
		# identity (not just presence) matters because a new fill for the
		# same queue would otherwise accept this old one's answer.
		my $live = $state{$playerid};
		return unless $live && $live->{running};
		return unless refaddr($live) == refaddr($st);

		# Re-read the record before touching it.
		#
		# The provider call above was asynchronous, so a 'nextbatch' may have
		# taken tracks out of the buffer while it was in flight. Writing back
		# the copy loaded before the call would undo that take, putting the
		# tracks back where the next caller could be handed one of them a
		# second time -- and a caching player would then download it twice.
		my $current = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

		return $class->_finish( $playerid, 'GONE' ) unless $current;

		if ($err) {
			$current->{last_error} = { code => $err, message => $err };
			Plugins::RemotePlayerCompanion::DSTM::Queue->save($current);
			$log->warn("fill for $playerid failed: $err");
			return $class->_finish( $playerid, $err );
		}

		# Room left now, which is not the room there was when the call went
		# out: a take may have happened in between.
		my $room = $current->{max} - Plugins::RemotePlayerCompanion::DSTM::Queue->total($current);

		return $class->_finish( $playerid, undef ) if $room <= 0;

		my $expanded = Plugins::RemotePlayerCompanion::DSTM::Provider->expand( $urls, $room, $vClient );
		my $added    = Plugins::RemotePlayerCompanion::DSTM::Queue->add( $current, $expanded, $current->{max} );

		# The shape of one turn of the loop, which is what answers "why is
		# this queue not filling": a provider that returns nothing, one whose
		# answers are all already held, and one whose answers are refused as
		# unplayable all look the same from outside.
		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug("fill turn: room=$room providerReturned=" . scalar( @{ $urls || [] } )
				. ' kept=' . scalar( @{ $expanded || [] } )
				. " added=$added buffered=" . Plugins::RemotePlayerCompanion::DSTM::Queue->total($current)
				. " fruitless=$st->{empty} calls=$st->{calls}" );
		}

		if ($added) {
			$st->{empty} = 0;
			$current->{last_error} = undef;
			Plugins::RemotePlayerCompanion::DSTM::Queue->save($current);

			# Wake any request that was waiting for exactly this much.
			$class->_notify($playerid);
		}
		elsif ( ++$st->{empty} >= GIVE_UP_EMPTY ) {
			# The provider keeps handing back tracks this queue already
			# holds; there is nothing more to be had right now.
			return $class->_finish( $playerid, undef );
		}

		# Not done yet: re-arm. This goes through a zero-delay timer rather
		# than calling _step directly, so that even a synchronous provider
		# cannot make the whole loop run inside the command that started it.
		return $class->_schedule($playerid);
	} );

	return;
}

# Wake every waiter whose condition the buffer now meets, and every waiter
# at all if the fill is over. Called after each append, and once more from
# _finish/_abandon so that nothing is left suspended.
sub _notify {
	my ( $class, $playerid ) = @_;

	my $st = $state{$playerid} or return;

	my $rec   = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);
	my $total = $rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) : 0;
	my $open  = $st->{running};

	my @keep;

	for my $w ( @{ $st->{waiters} } ) {
		next if $w->{done};

		my $enough = $total >= $w->{need};

		# Wake on "enough tracks" or on "the fill is over, take what there
		# is". The elapsed timer below is the third way out.
		if ( $enough || !$open ) {
			$w->{done} = 1;
			undef $w->{timer};
			$w->{cb}->( $enough ? 1 : 0, $enough ? 'filled' : 'ended' );
			next;
		}

		push @keep, $w;
	}

	$st->{waiters} = \@keep;

	return;
}

# End a fill. Every exit path goes through here -- target met, call
# allowance spent, provider exhausted, provider error, budget expired -- so
# that the gate is always released, the waiters are always woken, and the
# reason is always recorded.
sub _finish {
	my ( $class, $playerid, $err ) = @_;

	my $st = $state{$playerid} or return;

	# Already finished (typically the budget firing just after a normal
	# end). Nothing left to do; in particular, do not overwrite the reason
	# the real terminator recorded with a timeout.
	return unless $st->{running};

	$st->{running} = 0;
	$st->{error}   = $err;

	# Cancel the pending timers. Releasing the last reference to an AnyEvent
	# timer cancels it, which is also what stops the budget from firing.
	undef $st->{budget} if $st->{budget};
	undef $st->{tick}   if $st->{tick};

	# Record why a fill ended without producing anything. Without this a
	# caller only sees an empty queue and has no way to tell a provider that
	# timed out from one that genuinely had nothing to offer.
	if ( defined $err && $err ne 'GONE' ) {
		my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

		if ($rec) {
			$rec->{last_error} = { code => $err, message => $err };
			Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);
		}
	}

	# Why it ended, which is the question a queue that is not filling raises.
	# 'done' is not a failure: it is the target met, the call allowance spent,
	# or a provider that kept answering with tracks the queue already held.
	if ( main::DEBUGLOG && $log->is_debug ) {
		my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

		$log->debug( "fill end: $playerid reason=" . ( defined $err ? $err : 'done' )
			. ' calls=' . $st->{calls}
			. ' buffered=' . ( $rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) : 0 ) );
	}

	$class->_notify($playerid);

	delete $state{$playerid};

	return;
}

# Used by 'clear': stop a fill without recording an error, and wake its
# waiters as unsatisfied.
#
# Unlike _finish this does not save anything, and that is the point: it must
# leave the freshly emptied queue alone. Any provider callback still in
# flight finds no state and is discarded rather than refilling a queue the
# caller just cleared.
sub abandon {
	my ( $class, $playerid ) = @_;

	my $st = $state{$playerid} or return;

	$st->{running} = 0;

	undef $st->{budget} if $st->{budget};
	undef $st->{tick}   if $st->{tick};

	# No last_error and no save: 'clear' and 'forget' call this, and a queue
	# somebody has just emptied or dropped must not be written back to.
	main::DEBUGLOG && $log->is_debug
		&& $log->debug("fill abandon: $playerid stopped without recording an error");

	for my $w ( @{ $st->{waiters} } ) {
		next if $w->{done};
		$w->{done} = 1;
		undef $w->{timer};
		$w->{cb}->( 0, 'ended' );
	}

	delete $state{$playerid};

	return;
}

1;
