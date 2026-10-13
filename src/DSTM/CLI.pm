package Plugins::RemotePlayerCompanion::DSTM::CLI;

# The 'remoteplayercompanion dstm *' command family.
#
# Every command is registered with needsClient=0 and carries the target
# queue in the playerid parameter, with params[0] left empty. The remote
# player is not an LMS client: it is never inserted into %clientHash, so it
# cannot be discovered, listed by the players query, shown in the web UI or
# offered as a sync target. Addressing it by parameter rather than through
# params[0] is what keeps that true -- JSON-RPC resolves params[0] through
# getClient(), which only knows registered clients.
#
# Errors are reported as results, never as a request status. An error status
# makes the JSON-RPC layer close the socket without a body, leaving the
# caller with nothing to parse.

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Plugins::RemotePlayerCompanion::DSTM::Provider;
use Plugins::RemotePlayerCompanion::DSTM::Refill;
use Plugins::RemotePlayerCompanion::DSTM::Queue;
use Plugins::RemotePlayerCompanion::DSTM::VClient;
use Slim::Control::Request;
use Slim::Schema;
use Slim::Utils::Log;

my $log = logger('plugin.remoteplayercompanion');

# The queue's own default, read from the record that owns it, so that the two
# cannot drift apart.
use constant DEFAULT_MAX => Plugins::RemotePlayerCompanion::DSTM::Queue::DEFAULT_MAX;

use constant DEFAULT_COUNT => 20;
use constant MAX_COUNT     => 2000;
use constant MAX_MAX       => 10000;
use constant QUEUE_PAGE    => 50;

# How many tracks 'seed' gives a queue with no starting point of its own.
# Smaller than DEFAULT_COUNT on purpose: it only has to be enough for the
# queue's own provider to work from, not enough to serve a caller.
use constant SEED_COUNT => 10;

# --- registration ---------------------------------------------------------

# Register this family's commands. Called from the plugin's initPlugin.
sub init {
	my $class = shift;

	# The definition array is [needsClient, isQuery, hasTags]:
	#
	#   needsClient 0 -- the remote player is not an LMS client; it is
	#                    addressed through the playerid parameter and never
	#                    enters %clientHash, so it stays undiscoverable.
	#   isQuery     1 -- these read the server's state and never mutate the
	#                    request's own client, so they must not be notified.
	#   hasTags     1 -- parameters arrive as key:value, which is the only
	#                    safe encoding here: a MAC address and a URL both
	#                    contain colons, so positional parameters would be
	#                    mis-parsed as tags.
	my @commands = qw(sources config seed nextbatch queue status clear);

	for my $command (@commands) {
		my $handler = $class->can( 'cli' . ucfirst($command) );

		unless ($handler) {
			$log->error("no handler for command '$command'; not registering it");
			next;
		}

		Slim::Control::Request::addDispatch(
			[ 'remoteplayercompanion', 'dstm', $command ],
			[ 0, 1, 1, $handler ],
		);
	}

	return;
}

# --- commands -------------------------------------------------------------

sub cliSources {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	unless ( Plugins::RemotePlayerCompanion::DSTM::Provider->available ) {
		return _fail( $request, 'DSTM_DISABLED', "Don't Stop The Music is not enabled" );
	}

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new( $playerid, $rec ? $rec->{tracks} : [] );
	my $current = ( $rec && $rec->{provider} ) ? $rec->{provider} : '';

	# DSTM's registry is a grab bag: alongside the providers that generate a
	# mix it holds one entry per favourite, and whatever other plugins chose
	# to call their features. We offer the ones that belong, and say how many
	# we left out, unless the caller asks for the registry as it stands.
	my $showAll = $request->getParam('all') ? 1 : 0;

	my @sources;
	my $hidden = 0;

	for my $token ( Plugins::RemotePlayerCompanion::DSTM::Provider->tokens($vClient) ) {

		# A token the queue is already configured with stays in the list even
		# when we would not offer it: dropping it would leave
		# selected_provider naming something the caller cannot see, which
		# reads as a bug rather than as a filter.
		if ( !$showAll && $token ne $current && !Plugins::RemotePlayerCompanion::DSTM::Provider->isOffered($token) ) {
			$hidden++;
			next;
		}

		push @sources, {
			token    => $token,
			name     => _tokenName( $token, $vClient ),
			selected => ( $token eq $current ) ? 1 : 0,
		};
	}

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'selected_provider', $current );
	$request->addResult( 'count', _addLoop( $request, 'sources_loop', \@sources ) );
	$request->addResult( 'hidden', $hidden );
	$request->setStatusDone;

	return;
}

sub cliConfig {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my $token = $request->getParam('token');
	my $max   = $request->getParam('max');

	if ( defined $max ) {
		$max = _int($max);

		unless ( defined $max && $max >= 1 && $max <= MAX_MAX ) {
			return _fail( $request, 'BAD_MAX', "max must be between 1 and " . MAX_MAX );
		}
	}

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	unless ($rec) {
		$rec = Plugins::RemotePlayerCompanion::DSTM::Queue->create(
			$playerid,
			max => defined $max ? $max : DEFAULT_MAX,
		);
	}

	$rec->{max} = $max if defined $max;

	if ( defined $token && length $token ) {

		unless ( Plugins::RemotePlayerCompanion::DSTM::Provider->available ) {
			return _fail( $request, 'DSTM_DISABLED', "Don't Stop The Music is not enabled" );
		}

		my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new( $playerid, $rec->{tracks} );

		unless ( Plugins::RemotePlayerCompanion::DSTM::Provider->hasToken( $vClient, $token ) ) {
			return _fail( $request, 'UNKNOWN_PROVIDER', "no such provider: $token" );
		}

		$rec->{provider} = $token;
	}

	Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'max',      $rec->{max} );
	$request->addResult( 'provider', $rec->{provider} || '' );
	$request->addResult( 'total',    Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) );

	# Answer first, then start filling. The fill yields to the event loop
	# between provider calls, so this returns without waiting for it.
	$request->setStatusDone;

	Plugins::RemotePlayerCompanion::DSTM::Refill->ensure($playerid)
		if $rec->{provider};

	return;
}

sub cliNextbatch {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	unless ( $rec && $rec->{provider} ) {
		return _fail( $request, 'NOT_CONFIGURED',
			"no queue configured for $playerid; run config with a token first" );
	}

	my $count = _int( $request->getParam('count') );
	$count = DEFAULT_COUNT unless defined $count;
	$count = 1       if $count < 1;
	$count = MAX_COUNT if $count > MAX_COUNT;

	# Never wait for more than the buffer could ever hold.
	my $need  = $count < $rec->{max} ? $count : $rec->{max};
	my $total = Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec);

	if ( $total >= $need ) {
		return _serve( $request, $playerid, $count, $need );
	}

	# The buffer is short. Make sure something is being filled, then hold the
	# request open until the fill satisfies us, gives up, or our own budget
	# runs out.
	Plugins::RemotePlayerCompanion::DSTM::Refill->ensure($playerid);

	$request->setStatusProcessing;

	Plugins::RemotePlayerCompanion::DSTM::Refill->wait( $playerid, $need, sub {
		my ( $satisfied, $reason ) = @_;

		my $live  = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);
		my $have  = $live ? Plugins::RemotePlayerCompanion::DSTM::Queue->total($live) : 0;

		if ( !$have && $reason eq 'timeout' ) {
			return _fail( $request, 'SOURCE_TIMEOUT', 'no tracks within the wait budget' );
		}

		# An empty result that is not a timeout means the provider had
		# nothing new to give; that is a valid, if unhelpful, answer.
		return _serve( $request, $playerid, $count, $need );
	} );

	return;
}

sub cliQueue {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);
	my $all = $rec ? $rec->{tracks} : [];

	my $offset = _int( $request->getParam('offset') );
	$offset = 0 unless defined $offset && $offset >= 0;

	my $count = _int( $request->getParam('count') );
	$count = QUEUE_PAGE unless defined $count && $count > 0;

	my $total = scalar @{$all};

	$offset = $total if $offset > $total;

	my $end = $offset + $count - 1;
	$end = $total - 1 if $end > $total - 1;

	my @rows;
	if ( $end >= $offset ) {
		@rows = map { _trackInfo($_) } @{ $all }[ $offset .. $end ];
	}

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'total',    $total );
	$request->addResult( 'offset',   $offset );
	$request->addResult( 'count',    _addLoop( $request, 'queue_loop', \@rows ) );
	$request->setStatusDone;

	return;
}

sub cliStatus {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'configured', $rec ? 1 : 0 );
	$request->addResult( 'total', $rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) : 0 );
	$request->addResult( 'max', $rec ? $rec->{max} : DEFAULT_MAX );
	$request->addResult( 'provider', ( $rec && $rec->{provider} ) ? $rec->{provider} : '' );
	$request->addResult( 'filling', Plugins::RemotePlayerCompanion::DSTM::Refill->isFilling($playerid) );
	$request->addResult( 'created', $rec ? $rec->{created} : 0 );
	$request->addResult( 'updated', $rec ? $rec->{updated} : 0 );

	if ( $rec && $rec->{last_error} ) {
		$request->addResult( 'last_error', $rec->{last_error} );
	}

	$request->setStatusDone;

	return;
}

sub cliClear {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	# Drop any fill in flight first, otherwise its callbacks would refill a
	# queue the caller has just emptied.
	Plugins::RemotePlayerCompanion::DSTM::Refill->abandon($playerid);

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);
	my $removed = 0;

	if ($rec) {
		$removed = Plugins::RemotePlayerCompanion::DSTM::Queue->clear($rec);
		Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);
	}

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'removed',  $removed );
	$request->setStatusDone;

	return;
}

# Give a queue a starting point.
#
# A provider handed an empty queue is not merely unproductive, it can fail
# outright. LastMix asks DSTM for the properties of whatever the queue holds,
# and DSTM answers undef when there is nothing there -- which LastMix passes
# to Storable::dclone without checking, and dies on. Since config leaves a
# new queue empty, such a provider could not be used at all without this.
# Nothing on our side can help: the seed tracks are exactly what is missing.
#
# Not every provider wants one. RatingsLight selects from the whole library
# and works either way, and the PLUGIN_RANDOM_* family answers with a recipe
# the plugin expands itself, so a queue pointed at those never needs seeding.
#
# The tracks come from the plugin's own selection rather than from the
# queue's provider: asking a provider that needs a seed to supply that seed
# is the problem, not the solution. It is a starting point, not a curated
# one, and the queue's real provider takes over from the very next fill.
sub cliSeed {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	unless ($rec) {
		return _fail( $request, 'NOT_CONFIGURED',
			"no queue configured for $playerid; run config first" );
	}

	my $count = _int( $request->getParam('count') );
	$count = SEED_COUNT unless defined $count;
	$count = 1         if $count < 1;
	$count = MAX_COUNT if $count > MAX_COUNT;

	my $have = Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec);

	# Already has at least as much as it was asked for: nothing to do. This
	# is what makes the command safe to call on a queue that is already
	# running, rather than something a caller has to check first.
	if ( $have >= $count ) {
		return _respond( $request, $playerid, 0, $have, 0 );
	}

	my $urls = eval {
		Plugins::RemotePlayerCompanion::DSTM::RandomPlay->expand( 'randomplay://track', $count - $have );
	} || [];

	unless ( scalar @{$urls} ) {
		return _fail( $request, 'NO_SEED_AVAILABLE',
			'could not select any tracks to seed with; is RandomPlay available and the library populated?' );
	}

	my $added = Plugins::RemotePlayerCompanion::DSTM::Queue->add( $rec, $urls, $count );

	Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);

	# Seeding is a change to the buffer like any other, so from here the
	# queue tops itself up from its own provider in the ordinary way -- which
	# is the point: it now has the seed that provider needed.
	Plugins::RemotePlayerCompanion::DSTM::Refill->ensure($playerid);

	return _respond( $request, $playerid, $added, Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec), 1 );
}

sub _respond {
	my ( $request, $playerid, $added, $total, $seeded ) = @_;

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'added',    $added );
	$request->addResult( 'total',    $total );
	$request->addResult( 'seeded',   $seeded );
	$request->setStatusDone;

	return;
}

# --- shared helpers -------------------------------------------------------
sub _serve {
	my ( $request, $playerid, $count, $need ) = @_;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	unless ($rec) {
		return _fail( $request, 'NOT_CONFIGURED', "no queue configured for $playerid" );
	}

	my $urls = Plugins::RemotePlayerCompanion::DSTM::Queue->take( $rec, $count );

	Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);

	# Top the tail back up for the next caller.
	Plugins::RemotePlayerCompanion::DSTM::Refill->ensure($playerid);

	my @batch = map { _trackInfo($_) } @{$urls};

	# 'complete' answers the caller's request, so it compares against the
	# requested count -- not against $need, which is clamped to max purely to
	# stop us waiting on a target the buffer could never reach.
	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'count',    scalar @batch );
	$request->addResult( 'complete', scalar(@batch) >= $count ? 1 : 0 );
	_addLoop( $request, 'batch_loop', \@batch );
	$request->addResult( 'total',    Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) );
	$request->addResult( 'source',   $rec->{provider} || '' );
	$request->addResult( 'filling',  Plugins::RemotePlayerCompanion::DSTM::Refill->isFilling($playerid) );
	$request->setStatusDone;

	return;
}

# Arrays of objects go out as LMS-style '*_loop' results. The CLI renders a
# plain arrayref as 'HASH(0x...)' because only loop results are flattened
# item by item; naming them this way keeps both transports readable.
sub _addLoop {
	my ( $request, $name, $items ) = @_;

	my $i = 0;

	$request->setResultLoopHash( $name, $i++, $_ ) for @{$items};

	return scalar @{$items};
}

sub _trackInfo {
	my ($url) = @_;
	my $info = { url => $url };

	my $obj = eval { Slim::Schema->objectForUrl($url) };

	return $info unless blessed $obj;

	for my $field (qw(id title year duration tracknum)) {
		my $value = eval { $obj->$field };
		$info->{$field} = $value if defined $value;
	}

	my $artist = eval { $obj->artist };
	$info->{artist} = eval { $artist->name } if blessed $artist;

	my $album = eval { $obj->album };
	$info->{album} = eval { $album->name } if blessed $album;

	return $info;
}

sub _tokenName {
	my ( $token, $client ) = @_;

	my $name = eval {
		Slim::Utils::Strings::stringExists($token)
			? Slim::Utils::Strings::cstring( $client, $token )
			: undef;
	};

	return $name || $token;
}

sub _playerId {
	my $request = shift;

	my $playerid = $request->getParam('playerid');

	unless ( defined $playerid && length $playerid ) {
		return ( undef, 'MISSING_PARAMETER' );
	}

	unless ( $playerid =~ /^[A-Za-z0-9:_.\-]{1,64}$/ ) {
		return ( undef, 'BAD_PARAMETER' );
	}

	return ( $playerid, undef );
}

sub _int {
	my $value = shift;

	return undef unless defined $value && $value =~ /^\d+$/;

	return int($value);
}

sub _fail {
	my ( $request, $code, $message ) = @_;

	$code    ||= 'INTERNAL';
	$message ||= $code;

	$request->addResult( 'error',  { code => $code, message => $message } );
	$request->addResult( '_error', "$code: $message" );
	$request->setStatusDone;

	return;
}

1;
