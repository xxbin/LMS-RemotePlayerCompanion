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

# How many tracks 'nextbatch' hands out when the caller does not say, and the
# most it will hand out in one call whatever it is asked for.
#
# seed used to share this, so that the two commands' defaults were equal. It
# no longer does: a seed's size comes from the queue's depth instead (see
# cliSeed), because a seed only has to be enough for a provider to work from
# and the right amount depends on how deep the queue is -- with the default
# depth of 20 the two still come to the same 10.
use constant DEFAULT_COUNT => 10;
use constant MAX_COUNT     => 50;
# The depth ceiling. Deliberately not far above the batch ceiling: the dedup
# memory that stops a track being handed out twice holds a few thousand urls,
# and a queue deeper than that could outgrow it and repeat itself.
use constant MAX_MAX       => 100;
use constant QUEUE_PAGE    => 50;

# The track fields a list carries when the caller does not ask for any.
#
# Letters are LMS's own, from its tag map: 'y' year, 'd' duration, 't' track
# number -- which is not the title, however easy that is to misread -- 'a'
# artist, 'l' album, 'c' coverid. id and title come back whatever the tags say,
# so they need no letter, and neither does url, which is set from the buffer.
#
# This is what a list carried before there was a tags parameter, plus coverid,
# so that asking for nothing still gets no less than it used to.
use constant DEFAULT_TAGS => 'ydtalc';

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
	my @commands = qw(sources config seed nextbatch queue status clear forget);

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

	my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new( $playerid,
		$rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->playlist($rec) : [] );
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

# Set a queue's depth, and optionally its provider. Optional entirely: seed
# creates a queue with DEFAULT_MAX and adopts the player's provider, so a queue
# that needs neither never calls this.
#
# Naming a provider here writes it **both** ways: into the record, and into the
# player's own Dont Stop The Music setting. Both are sources -- seed adopts
# whatever the player is set to, so a provider chosen in LMS works, and this
# makes a provider chosen through the plugin work in LMS too. Neither is
# privileged; the last one written is the one both sides read.
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

		my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new(
			$playerid, Plugins::RemotePlayerCompanion::DSTM::Queue->playlist($rec) );

		# Checked before either is written, so a refused provider leaves both
		# the queue and the player as they were.
		my ( $ok, $err ) = Plugins::RemotePlayerCompanion::DSTM::Provider->check( $vClient, $token );

		return _fail( $request, $err, _providerMessage( $err, $playerid ) ) unless $ok;

		# The player first, then the record: if the second write fails the
		# player is merely set to what was asked for, which is harmless, while
		# the other order could leave a queue drawing from a provider the
		# player is not set to.
		Plugins::RemotePlayerCompanion::DSTM::Provider->assign( $vClient, $token );

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

	# Nothing to serve from. Rather than refuse -- which would make 'seed' a
	# step every caller has to know about -- establish the queue here. What
	# that cannot do is invent a provider, so a player with none set in LMS is
	# still refused, with NO_PROVIDER naming the setting to go and make.
	unless ( $rec && $rec->{provider} ) {
		my ( undef, $fail, $message ) = _establish( $request, $playerid );

		return _fail( $request, $fail, $message ) if $fail;

		$rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);
	}

	# Cut down to the ceiling one call may carry, silently. The answer already
	# says how much was handed over and how much is left behind; a flag on top
	# of those two would be a third thing to keep true, and would still not say
	# which of them the caller should be looking at.
	my $count = _int( $request->getParam('count') );
	$count = DEFAULT_COUNT unless defined $count;
	$count = 1 if $count < 1;
	$count = MAX_COUNT if $count > MAX_COUNT;

	# Never wait for more than the buffer could ever hold.
	my $need  = $count < $rec->{max} ? $count : $rec->{max};
	my $total = Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec);

	if ( $total > 0 ) {
		return _serve( $request, $playerid, $count, $need );
	}

	# The buffer is empty, so there is nothing to return. Make sure something
	# is being filled, then hold the request open until the fill satisfies us,
	# gives up, or our own budget runs out.
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
		my $tags = _tags($request);

		@rows = map { _trackInfo( $request, $_, $tags ) } @{ $all }[ $offset .. $end ];
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
# Drop a queue's record.
#
# This is the only way back to the state a caller who has never used the plugin
# is in, and that is what it is for: a record outlives a server restart, and
# nothing else removes one. 'clear' is the other half of the pair -- it empties
# the buffer and leaves the queue configured.
#
# The player's own Dont Stop The Music setting is left alone. That setting
# belongs to the player rather than to this queue, and it is where the next
# queue for this player will adopt its provider from.
sub cliForget {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	# Drop any fill in flight first, or its callbacks would write the record
	# straight back.
	Plugins::RemotePlayerCompanion::DSTM::Refill->abandon($playerid);

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	Plugins::RemotePlayerCompanion::DSTM::Queue->destroy($playerid) if $rec;

	$request->addResult( 'playerid',  $playerid );
	$request->addResult( 'forgotten', $rec ? 1 : 0 );
	$request->setStatusDone;

	return;
}


# Establish a queue: adopt its provider, and give it something to work from.
#
# **The provider comes from the player, not from the caller.** DSTM keeps a
# provider per player -- the one the user picked for that player in LMS -- and
# this reads it, checks it against the same whitelist 'sources' offers, and
# writes it into the record. This is the step that makes a queue usable, and
# therefore the step that creates a queue when there is none.
#
# **A seed is not a curated selection.** A provider handed an empty queue is
# not merely unproductive, it can fail outright: LastMix asks DSTM for the
# properties of whatever the queue holds, DSTM answers undef when there is
# nothing there, and LastMix passes that to Storable::dclone without checking.
# The tracks come from the plugin's own selection rather than from the queue's
# provider -- asking a provider that needs a seed to supply that seed is the
# problem, not the solution -- and the queue's real provider takes over from
# the very next fill.
#
# Not every provider wants one: RatingsLight selects from the whole library,
# and the PLUGIN_RANDOM_* family answers with a recipe the plugin expands
# itself, so a queue pointed at those is fine with an empty buffer. They still
# need this, because it is what adopts the provider.
#
# **It starts the queue over rather than topping it up.** The buffer and the
# material a previous seed established are both discarded, because a queue
# that kept either would go on deriving from a provider -- or a track -- that
# the caller has moved on from. So this is not safe to call on a queue that is
# playing: whatever it held is gone. That is the price of the only way to pick
# up a provider the player has changed since.
#
# Returns ( $added, $error, $message ). Nothing is written until every refusal
# has been ruled out and the material to replace the old has been obtained, so
# a refused call leaves the queue exactly as it was -- refusing must not be a
# way to unconfigure a queue that is already working.
sub _establish {
	my ( $request, $playerid ) = @_;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	my $vClient = Plugins::RemotePlayerCompanion::DSTM::VClient->new(
		$playerid,
		$rec ? Plugins::RemotePlayerCompanion::DSTM::Queue->playlist($rec) : [],
	);

	my ( $token, $providerErr ) =
		Plugins::RemotePlayerCompanion::DSTM::Provider->adopted($vClient);

	return ( 0, $providerErr, _providerMessage( $providerErr, $playerid ) )
		if $providerErr;

	my ( $url, $urlErr, $urlMessage ) = _trackUrl($request);
	return ( 0, $urlErr, $urlMessage ) if $urlErr;

	# Built in memory from here, and not written until the whole thing has
	# succeeded, so that the refusal below still leaves the queue as it was.
	$rec ||= Plugins::RemotePlayerCompanion::DSTM::Queue->create($playerid);

	$rec->{provider} = $token;

	# Half the queue's depth, rather than a number of its own. A seed only has
	# to be enough for the provider to work from, and half leaves the other
	# half for the tracks that provider is about to supply -- so the queue is
	# not full of seeds before the provider has said anything.
	my $target = int( $rec->{max} / 2 ) || 1;

	# The replacement material is obtained before the old is dropped, so that
	# failing to find any leaves a working queue working.
	my $urls = [];

	unless ( defined $url ) {
		$urls = eval {
			Plugins::RemotePlayerCompanion::DSTM::RandomPlay->expand( 'randomplay://track', $target );
		} || [];

		unless ( scalar @{$urls} ) {
			return ( 0, 'NO_SEED_AVAILABLE',
				'could not select any tracks to seed with; is RandomPlay available and the library populated?' );
		}
	}

	Plugins::RemotePlayerCompanion::DSTM::Queue->clear($rec);
	$rec->{seed} = [];

	my $added = 0;

	# A named seed is what the queue is *about*, so it replaces the previous
	# one rather than adding to it: "I am playing this now" is a statement
	# about the present.
	if ( defined $url ) {
		Plugins::RemotePlayerCompanion::DSTM::Queue->setSeed( $rec, $url );
	}
	else {
		$added = Plugins::RemotePlayerCompanion::DSTM::Queue->add( $rec, $urls, $target );
	}

	Plugins::RemotePlayerCompanion::DSTM::Queue->save($rec);

	# Seeding is a change to the buffer like any other, so from here the queue
	# tops itself up from its own provider in the ordinary way -- which is the
	# point: it now has the seed that provider needed.
	Plugins::RemotePlayerCompanion::DSTM::Refill->ensure($playerid);

	return ( $added, undef, undef );
}

# seed is the command; _establish is what it and 'nextbatch' both do.
#
# nextbatch establishes a queue for itself when it finds none to serve from,
# which is what makes seed optional for a caller whose player is already set
# to a provider in LMS. What seed adds over that fallback is a track to build
# the queue around, and a deliberate moment at which a queue is started over.
sub cliSeed {
	my $request = shift;

	my ( $playerid, $err ) = _playerId($request);
	return _fail( $request, $err ) if $err;

	my ( $added, $fail, $message ) = _establish( $request, $playerid );
	return _fail( $request, $fail, $message ) if $fail;

	my $rec = Plugins::RemotePlayerCompanion::DSTM::Queue->load($playerid);

	return _respond( $request, $playerid, $rec, $added,
		Plugins::RemotePlayerCompanion::DSTM::Queue->total($rec) );
}

# The track a named seed refers to: ( $url, $error, $message ).
#
# No url and no id is not an error -- it is the request to fill a buffer, which
# is what seed did before it could name a track, so all three come back empty
# and the caller carries on.
#
# A URL that cannot be resolved is an error rather than something to ignore:
# DSTM turns buffer URLs into tracks with objectForUrl, and a URL it cannot
# resolve yields nothing, which for a provider deriving from the queue is the
# same silent failure as an empty queue. Refusing says so out loud.
sub _trackUrl {
	my $request = shift;

	my $url = $request->getParam('url');
	my $id  = _int( $request->getParam('id') );

	if ( defined $url && defined $id ) {
		return ( undef, 'BAD_PARAMETER', 'give url: or id:, not both' );
	}

	return ( undef, undef, undef ) unless defined $url || defined $id;

	# Both lookups already exist in DSTM/Tracks.pm; reuse rather than reinvent.
	my $track = defined $id
		? eval { Slim::Schema->resultset('Track')->find($id) }
		: eval { Slim::Schema->objectForUrl($url) };

	unless ( $track && $track->isa('Slim::Schema::Track') ) {
		return ( undef, 'SEED_NOT_IN_LIBRARY',
			'that track is not in the library, so no provider could derive from it' );
	}

	return ( $track->url, undef, undef );
}

# Say where to go, not only what is wrong. The setting lives in LMS, under the
# player, and is not something this plugin can change for the user.
sub _providerMessage {
	my ( $code, $playerid ) = @_;

	return "no Don't Stop The Music provider is set for $playerid; "
		. "set one for that player in LMS"
		if $code eq 'NO_PROVIDER';

	return "the provider set for $playerid is not one Dont Stop The Music "
		. "knows any more; pick another for that player in LMS"
		if $code eq 'UNKNOWN_PROVIDER';

	return "the provider set for $playerid is not one a queue can use: it is "
		. "a single favourite rather than a mix. Run sources to see what can "
		. "be used, and set one of those for the player in LMS"
		if $code eq 'PROVIDER_NOT_OFFERED';

	return "Don't Stop The Music is not enabled";
}

# Answer with the queue as it now stands, not only with what was added.
#
# seed is what establishes a queue -- it adopts the provider and creates the
# record -- so its answer carries the same picture config's does, plus what
# the seeding did. A caller that has just seeded should not have to ask again
# to find out what it now has.
sub _respond {
	my ( $request, $playerid, $rec, $added, $total ) = @_;

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'max',      $rec->{max} );
	$request->addResult( 'provider', $rec->{provider} || '' );
	$request->addResult( 'added',    $added );
	$request->addResult( 'total',    $total );

	# The track the queue is now building around, if one was named. Reported so
	# that a caller can tell a seed that was taken from one that was ignored,
	# which is otherwise invisible: a seed that never lands looks exactly like
	# a queue that simply has not filled yet.
	$request->addResult( 'seeded_track',
		Plugins::RemotePlayerCompanion::DSTM::Queue->seed($rec)->[0] || '' );

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

	my $tags = _tags($request);

	my @batch = map { _trackInfo( $request, $_, $tags ) } @{$urls};

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'count',    scalar @batch );
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

# The tag letters the caller asked for, or the default.
#
# Deliberately not checked against LMS's map: an unrecognised letter is skipped
# by that map rather than being an error, and a second copy of the letter list
# here would be a second copy to keep in step.
sub _tags {
	my $request = shift;

	my $tags = $request->getParam('tags');

	return DEFAULT_TAGS unless defined $tags && length $tags;

	return $tags;
}

# One entry of a track list.
sub _trackInfo {
	my ( $request, $url, $tags ) = @_;

	# LMS's own machinery, rather than a mapping of our own: a tag letter means
	# here exactly what it means to songinfo, and a field LMS adds to its map
	# turns up here without any work.
	#
	# Wrapped in eval because _songData reaches for the request's client when a
	# track is remote, and these commands are registered with no client. A
	# track we cannot describe is still a track the caller can play, so it
	# comes back with its url alone rather than taking the whole answer down.
	my $info = eval { Slim::Control::Queries::_songData( $request, $url, $tags, 1 ) };

	return { url => $url } unless $info && ref $info eq 'HASH';

	# The url the buffer handed out, not the one the database holds. They can
	# differ -- a cue sheet gives a url a #start-end suffix -- and it is the
	# buffer's that the player has to be able to fetch.
	$info->{url} = $url;

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
