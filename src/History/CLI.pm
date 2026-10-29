package Plugins::RemotePlayerCompanion::History::CLI;

# 'remoteplayercompanion history report' -- a play report from a remote
# player.
#
# The command takes everything as parameters and resolves nothing about the
# caller: the remote player is not an LMS client, so needsClient is 0 and
# playerid travels as a parameter, exactly as in the DSTM family.
#
# A successful answer transfers ownership: the caller deletes its copy. So
# every request the plugin cannot record in full is refused here, before
# anything is written. Environmental gaps (no APC, no scrobbler account, a
# scan in progress) are not refusals; they are logged, and the report is
# consumed.

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Utils::Log;

use Plugins::RemotePlayerCompanion::History::Report;
use Plugins::RemotePlayerCompanion::History::Track;

my $log = logger('plugin.remoteplayercompanion');

use constant MAX_TRACKS     => 500;
use constant WINDOW_SECONDS => 7 * 86400;

# Five minutes, not one. The caller is a remote player on its own clock, and
# a play time a little ahead of the server's is a clock disagreement, not a
# backdated lie. The test environment alone has machines two minutes apart;
# a phone that has not synced can be further. Anything past this is refused.
use constant FUTURE_SLACK => 300;

sub init {
	Slim::Control::Request::addDispatch(
		[ 'remoteplayercompanion', 'history', 'report' ],
		[ 0, 1, 1, \&cliReport ],
	);
}

sub cliReport {
	my $request = shift;

	my ( $playerid, $player_error ) = _playerId($request);
	return _fail( $request, $player_error,
		$player_error eq 'BAD_PARAMETER'
			? 'playerid is malformed'
			: 'playerid is required' )
		unless defined $playerid;

	my $playername = $request->getParam('playername');
	if ( defined $playername
		&& $playername !~ /^[^\x00-\x1F\x7F]{1,64}$/ )
	{
		return _fail( $request, 'BAD_PARAMETER',
			'playername must be 1 to 64 printable characters' );
	}

	my $idlist  = $request->getParam('id');
	my $urllist = $request->getParam('url');

	if ( defined $idlist && defined $urllist ) {
		return _fail( $request, 'BAD_PARAMETER',
			'id and url are mutually exclusive' );
	}

	if ( !defined $idlist && !defined $urllist ) {
		return _fail( $request, 'MISSING_PARAMETER',
			'one of id or url is required' );
	}

	my $is_id = defined $idlist;
	my $value = $is_id ? $idlist : $urllist;
	my @items;

	if ( defined $value ) {
		my ($items, $error, $message) = _list($value);
		return _fail( $request, $error, $message ) if $error;
		@items = @{$items};
	}

	my $now = time();

	my ($played, $error, $message) = _played( $request, scalar @items, $now );
	return _fail( $request, $error, $message ) if $error;

	my @entries;
	for my $i ( 0 .. $#items ) {
		my $entry = eval { Plugins::RemotePlayerCompanion::History::Track->resolve( $items[$i], $is_id ) };
		return _fail( $request, 'UNRESOLVED_TRACK',
			'cannot resolve entry ' . ( $i + 1 ) . ': ' . $items[$i] )
			unless $entry;

		$entry->{played} = $played->[$i];
		push @entries, $entry;
	}

	my $receipt = eval {
		Plugins::RemotePlayerCompanion::History::Report->run(
			{
				playerid   => $playerid,
				playername => $playername,
				input      => $is_id ? 'id' : 'url',
				entries    => \@entries,
				now        => $now,
			}
		);
	};

	if ( !$receipt ) {
		my $error = $@ || 'unknown error';
		$error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
		$log->error("history report for $playerid died: $error");

		return _fail( $request, 'INTERNAL_ERROR', $error );
	}

	# Report decides the one refusal that depends on server state (the
	# scrobbler queue's depth) and returns it rather than dying.
	if ( $receipt->{error} ) {
		return _fail( $request, $receipt->{error}{code},
			$receipt->{error}{message} );
	}

	$request->addResult( 'playerid', $playerid );
	$request->addResult( 'accepted', $receipt->{accepted} );
	$request->addResult( 'duplicates', $receipt->{duplicates} );
	$request->addResult( 'queued', $receipt->{queued} );
	$request->addResult( 'nowplaying_status', $receipt->{nowplaying_status} );

	$request->setStatusDone;

	return;
}

# --- parameter helpers ---------------------------------------------------------

sub _playerId {
	my $request = shift;

	my $playerid = $request->getParam('playerid');

	return ( undef, 'MISSING_PARAMETER' )
		unless defined $playerid && length $playerid;

	return ( undef, 'BAD_PARAMETER' )
		unless $playerid =~ /^[A-Za-z0-9:_.\-]{1,64}$/;

	return ($playerid);
}

# A comma list, refused whole on any structural fault.
#
# split(..., -1) rather than a plain split: a plain one drops trailing empty
# fields, so a trailing comma would silently disappear instead of being
# refused. A malformed list means the index alignment with `played` may be
# wrong, and applying it could attach the wrong time to a track.
sub _list {
	my $value = shift;

	# split on the empty string returns an empty list, even with -1, so an
	# empty value has to be refused before it is split or it would look like
	# a list of no entries rather than a malformed one.
	unless ( defined $value && length $value ) {
		return ( undef, 'BAD_PARAMETER', 'the list is empty' );
	}

	my @items = split( /,/, $value, -1 );

	if ( @items > MAX_TRACKS ) {
		return ( undef, 'TOO_MANY_TRACKS',
			'a request carries at most ' . MAX_TRACKS . ' entries' );
	}

	for my $i ( 0 .. $#items ) {
		unless ( length $items[$i] ) {
			return ( undef, 'BAD_PARAMETER',
				'entry ' . ( $i + 1 ) . ' is empty' );
		}
	}

	return ( \@items );
}

# Each entry's play time: the instant the track started, in epoch seconds.
#
# Omitted means one `now` for the whole request, which is right for a live
# report and wrong for a backlog. It also makes a retry unrecognisable as a
# duplicate -- see Store -- so a caller that may retry should send `played`.
sub _played {
	my ( $request, $count, $now ) = @_;

	my $value = $request->getParam('played');

	return ( [ ($now) x $count ] ) unless defined $value;

	# Same empty-string trap as _list: an empty value is a malformed play
	# time, not a list of no values.
	unless ( length $value ) {
		return ( undef, 'INVALID_PLAYED', 'played is empty' );
	}

	my @played = split( /,/, $value, -1 );

	if ( @played != $count ) {
		return ( undef, 'LIST_LENGTH_MISMATCH',
			'played carries ' . scalar(@played) . ' values for ' . $count . ' entries' );
	}

	my $earliest = $now - WINDOW_SECONDS;
	my $latest   = $now + FUTURE_SLACK;

	for my $i ( 0 .. $#played ) {
		unless ( $played[$i] =~ /^\d+$/ ) {
			return ( undef, 'INVALID_PLAYED',
				'entry ' . ( $i + 1 ) . ' has a malformed play time' );
		}

		my $time = int( $played[$i] );

		if ( $time < $earliest || $time > $latest ) {
			return ( undef, 'INVALID_PLAYED',
				'entry ' . ( $i + 1 ) . ' is outside the last seven days' );
		}

		$played[$i] = $time;
	}

	return ( \@played );
}

sub _fail {
	my ( $request, $code, $message ) = @_;

	$request->addResult( 'error', { code => $code, message => $message } );
	$request->addResult( '_error', "$code: $message" );
	$request->setStatusDone;

	return;
}

1;
