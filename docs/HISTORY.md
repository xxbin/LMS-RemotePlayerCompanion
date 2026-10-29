# The `history` family

Detail for the `history` family of [Remote Player Companion](../README.md):
a batch of plays a remote player made away from the server, reported back and
written into the server's existing play records and scrobble queue.

It is written for whoever works on this next: the contract first, then what
each destination gets, then the mechanics and side effects.

## What it is

One request carries a batch of plays. For every play it has not seen before,
the plugin updates:

- **LMS's play count** — `tracks_persistent`, the count the web UI shows;
- **Alternative Play Count** — APC's own play count, its Play History row,
  and its played/skipped bookkeeping, through APC's external report command;
- **Listening History** — an entry in that plugin's own database, built with
  its own `Sources::describe`;
- **AudioScrobbler** — an item in LMS's own scrobble queue, which LMS then
  submits, retries and chunks exactly as it does for a real player.

```
   player ──history report──▶ Remote Player Companion ──▶ LMS play count
                                                        ├──▶ APC count and play history
                                                        ├──▶ Listening History entry
                                                        └──▶ AudioScrobbler queue ──▶ Last.fm
```

What Was That Tune is deliberately not among them; see
[Not a destination](#not-a-destination-what-was-that-tune).

The first three are *targets* under `History/Targets/`: local destinations
with a batch interface (`new`, `name`, `status`, `apply`), each responsible
only for its own plugin's rules. AudioScrobbler is not a target because it
can refuse the whole request (the queue cap) before anything is written, and
it owns now-playing; `Report.pm` keeps it outside the target loop.

The command is `remoteplayercompanion history report`, registered with
`needsClient = 0`: the remote player does not connect as an LMS client, so
`playerid` is a parameter and `params[0]` stays empty, as in the `dstm` family.

**Success transfers ownership.** The caller deletes its copy once the plugin
accepts the plays, so a request that cannot be recorded in full is refused
before anything is written. The answer is a receipt, not a per-destination
report.

## The request

```
["", ["remoteplayercompanion", "history", "report",
      "playerid:living-room",
      "id:27189,27198",
      "played:1792441378,1792441450"]]
```

| Parameter | Required | Value |
|---|---|---|
| `playerid` | yes | The remote player's id: `^[A-Za-z0-9:_.\-]{1,64}$` |
| `id` | one of `id`/`url` | Comma-separated LMS track ids |
| `url` | one of `id`/`url` | Comma-separated track URLs |
| `played` | no | Comma-separated epoch **seconds**, one per track, same order |
| `playername` | no | Display name for APC's and Listening History's player lists, 1–64 printable characters |

- One of `id` or `url` must be present; they are mutually exclusive.
- There is no now-playing parameter. The plugin decides from the play times:
  see [AudioScrobbler](#4-audioscrobbler).
- At most **500** entries per request.
- An empty item, a trailing comma or an empty list is refused rather than
  trimmed: a malformed element means the positional match with `played` may be
  wrong, and applying the rest could attach the wrong time to a track.
- A comma inside a URL cannot be represented. The DSTM seed has the same
  restriction.
- There is **no account parameter**: the server's own AudioScrobbler account
  is used, and credentials never travel in the request.

### Play time

`played` is the **start** of the track, in UTC epoch seconds.

- If omitted, every entry is stamped with one `now`, taken at the start of the
  request. That is right for a live "I just played these" call and wrong for a
  backlog. It also makes a retry unrecognisable as a duplicate, so a caller
  that may retry should always send `played`.
- Only the last **seven days** are accepted, plus a five-minute allowance for a
  remote player's clock running ahead of the server's.
- An out-of-window value refuses the whole request. A play that would be
  silently skipped is worse than a refusal: the caller would delete the only
  copy of it.

### Resolving an entry

```
id:   DSTM::Tracks->urlForId($id)    undef or '' -> UNRESOLVED_TRACK
both: Slim::Schema->objectForUrl({url})
      undef and a remote URL -> Slim::Schema::RemoteTrack->new($url)
      otherwise              -> UNRESOLVED_TRACK
```

An ephemeral `RemoteTrack` is never inserted into the library. It exists so
AudioScrobbler can ask the protocol handler for artist, title and duration,
and so the local destinations can record its URL.

Whichever parameter a play arrived through, the debug log says so: the
request's first line is `history request: <playerid> input=id|url
entries=N`. Resolution erases the distinction — every later line names the
play by its url — and `id` and `url` are mutually exclusive, so one word per
request covers the whole batch.

## The answer

```json
{
  "playerid": "living-room",
  "accepted": 2,
  "duplicates": 0,
  "queued": 2,
  "nowplaying_status": "requested"
}
```

- `accepted` — entries that were not duplicates. This can be less than the
  number sent, and a destination may still skip one (a station, no play-count
  row, and so on); the play is consumed either way.
- `duplicates` — entries already recorded from an earlier report, not applied
  again. They are consumed, not refused.
- `queued` — entries handed to the AudioScrobbler queue. Eligibility can
  reduce it (`too_short`, `ignored`, radio), and it is 0 when scrobbling is
  off, no account is configured, the plugin is missing or disabled, or LMS
  would not take the queue.
- `nowplaying_status` — `requested` (handed to the AudioScrobbler API),
  `skipped` (there was no new play to announce, the newest play has ended, or
  its duration is unknown), or `unavailable` (the scrobbler is unavailable or
  would not take the track).

The answer has no per-destination field and no account field. The targets
apply the batch internally; `Report.pm` logs one debug line per entry and
target, under the plugin's own log category.

### Refusals

| Code | When |
|---|---|
| `MISSING_PARAMETER` | no `playerid`; neither `id` nor `url` |
| `BAD_PARAMETER` | malformed `playerid`/`playername`, both `id` and `url`, an empty item or list |
| `TOO_MANY_TRACKS` | more than 500 entries |
| `LIST_LENGTH_MISMATCH` | `played` count differs from the track count |
| `INVALID_PLAYED` | a `played` value is not an integer, or lies outside the window |
| `UNRESOLVED_TRACK` | an id or URL resolves to nothing (the message names the index and the input) |
| `SCROBBLE_QUEUE_FULL` | enqueueing would leave more than 1000 pending scrobbles |
| `INTERNAL_ERROR` | the report died before answering; the message carries the error |

Errors are results, never request statuses: an error status closes the JSON-RPC
socket with no body.

Environmental gaps are **not** refusals. A missing or disabled APC, Listening
History or AudioScrobbler plugin, APC's Play History switched off (its counts
still update), statistics
switched off, no scrobbling account, scrobbling switched off, a library scan
in progress, a track with no `tracks_persistent` row, or a play that
Listening History declines (a station, a service track with no duration) is
logged and the report is consumed. The caller cannot act on
these, and keeping its copy would produce the same outcome next time.

## What each destination gets

### 1. LMS's play count

The rules are `Slim::Player::Song`'s own: increment only when LMS statistics
are on, no scan is running, and a `tracks_persistent` row exists. (`Song` also
skips a seek; a reported play is not one.) `lastplayed` becomes
`max(existing, played)` and is never lowered, so an out-of-order report counts
the play without moving the clock backwards.

### 2. Alternative Play Count

Each play is reported through APC's own external interface, the one it
provides for a player that is not an LMS client:

```
alternativeplaycount reportplayback mac:<playerid> playername:<name>
                       trackid:<id> percentplayed:100
```

It applies APC's own rules: the play count, `lastPlayed`, the Play History
row, the dynamic played/skipped value and, when auto-rating is configured,
the auto-rating step. `percentplayed:100` is above APC's threshold (validated
to 10..90), so a reported play is always counted. The remote player decided
it was a play; the server has no progress to judge.

The command records the instant it runs, and a reported play may be days old.
Two values are therefore corrected afterwards, each only when it differs:

- **the Play History row's `played`** — the row APC just wrote gets the
  reported start time, not the time of the report. Its rating is whatever
  APC wrote.
- **`lastPlayed`** — becomes `max(its previous value, played)`, so a backlog
  cannot move the clock forward and an out-of-order report cannot move it
  back. A play reported as it happens needs no correction at all.

Everything else is APC's own, written by APC's own code: the count, the
dynamic played/skipped value (which rises, as it does for any played track),
and the rating when auto-rating is on.

- **An entry with no library track has no id to report.** A URL only an
  ephemeral `RemoteTrack` answers for is skipped (`no_track_id`); APC has no
  count row for it either.
- **A player id longer than 40 characters is skipped**
  (`player_id_too_long`). `reportplayback` rejects it, and truncating would
  file the play under a different player.
- **The player row** is saved once per request, after the last report: name
  from `playername`, else the name APC already has, else the id; model
  `remote`; `last_seen` set to now — a six-day-old play reported today still
  means the player was seen today. `reportplayback` saves the player itself
  with no model, so this call is what restores it.
- **With APC's Play History switched off**, APC writes neither the row nor
  the player, so neither correction runs; the count still updates.

### 3. Listening History

The plugin's live tracker has no public "record this play" seam:
`Tracker::_record` needs a live client and `playingSong`, stamps the wall
clock, and keeps in-memory session state. A backfill has its own start times,
so the target calls the storage functions the tracker itself uses —
`Plugins::ListeningHistory::DB::addEntry` and `addToEntry`, the plugin's own
API rather than raw SQL or a second database — and builds the row with
`Plugins::ListeningHistory::Sources::describe`. That keeps the plugin's rules:

- a station is skipped (and ends any album session);
- a service track with no duration, or a Radio Paradise announcement, is
  skipped;
- consecutive tracks from one album become one `album` entry when nothing
  repeats in the run and the next play starts within `session_gap_min`
  (default 30 minutes) of the previous play's end.

### 4. AudioScrobbler

A report does two things here: every play LMS would scrobble is queued, and
the newest play still running is announced as now-playing. Submitting is
LMS's — the plugin builds the queue item `newsongCallback` would have built
and hands the queue back, so the handshake, the retries and the durable queue
stay LMS's.

- **Eligibility** is LMS's own, in its order: scrobbling on, an account,
  metadata, at least 30 seconds when the duration is known, the ignore lists
  (`ignoreTitles`, `ignoreArtists`, `ignoreAlbums`, `ignoreGenres`;
  case-insensitive substrings), and radio only when `include_radio` allows
  it. A refused track is logged with the reason and not queued; the report
  still succeeds.
- **The account** is the server's: a stored choice that still matches an
  account wins, otherwise the only account, otherwise the first of several
  (named in a warning). It is written into the synthetic client's `account`
  preference, which is what LMS reads from then on.
- **Now-playing** has no parameter. The newest accepted play is announced
  only while `now - played < duration`; a play that has ended or has no
  duration is recorded but not announced, and a retried report (all
  duplicates) announces nothing. Ignore lists apply here too, unlike LMS's
  own callback. The announcement goes out after the scrobbles, so it does not
  clobber the display.

### Order of writes

Everything that can refuse the request is decided first: scrobbler
eligibility and the queue cap. The targets then write in order — LMS, APC,
Listening History — followed by the scrobble queue and now-playing; only
after that is the duplicate store marked. A server that dies mid-entry
re-applies that entry on retry rather than forgetting it.

### Duplicates

A play is identified by `md5(playerid, url, played)` in a durable cache
namespace with a seven-day expiry — the same window the request accepts. A
repeated report answers `accepted: 0` and `duplicates: n`, so a caller that
retried after a timeout can safely delete its copy.

A report without `played` is never recognised as a duplicate, because `now`
differs on every call: send `played` if the caller may retry.

## Not a destination: What Was That Tune

PlayHistory (Michael Herger's plugin) is not a destination. Its history is
addressed per player, and a remote player is not one LMS lists.

**The entries cannot be read.** The plugin's pages are opened for a player,
and LMS's player lists leave hidden clients out
(`Slim::Player::Client::clients` filters `hidden`); the synthetic client is a
hidden one. Entries would at most show as
a row in the plugin's own player menu, and that row does not open.

**The write is awkward too.** There is no "record this play" interface: the
plugin logs the URL of the *playing* client's playlist, so a write means
fabricating client state. It stamps the logging time, not the play time; drops
an entry identical to that player's newest; applies its ignore list; and keeps
the buffer in memory, rewriting its own preference on every play, so a
preference written directly is overwritten by the next live play. Nothing
written can be deleted afterwards.

## The synthetic client

AudioScrobbler stores a client's **id**, not the object: `API::new` keeps
`$client->id`, and every later path resolves it through
`Slim::Player::Client::getClient` — the handshake, the retry, the queue, the
metadata lookup, and `master()`. A client that is not in `%clientHash` works
for the first call and is lost at the first of those.

So one hidden client is created per remote player, from
`Slim::Player::Disconnected`. It is invisible to the `players` query, the web
UI and sync lists (`hidden` clients are filtered out), and it keeps each
remote player's account, queue and session to itself. The Listening History
target asks for the same client, because `Sources::describe` takes one.

Its id is the **remote player's own id** — the same value APC records as
`client_id` and the duplicate store keys on. One remote player is one identity
in every destination, so the client's `_client:<playerid>` preferences and its
APC player row describe the same thing, and both survive restarts because the
id is the caller's own rather than one allocated here.

If LMS already keeps a client under that id — a player that also connects to
the server, or LMS's disconnected record of one — that client is used: same
id, same player, same account and queue. `getClient` matches names as well as
ids, so the returned id is compared: a client reached by its **name** is a
different player, and the plugin refuses rather than spending that player's
account and queue on this one. The report still succeeds; scrobbling is
logged as unavailable.

`Client::new` only registers the object. The preferences every client is
expected to have are installed by `Client::init`, which runs when a player
connects and never for a synthetic one. `forPlayer` therefore calls
`initPrefs` on a client it created — without it, anything that formats a
title for the client dies: `HTTP::getMetadataFor` asks for the current title
while a remote URL is looked up, and `standardTitleFormat` dereferences
`titleFormat` as an array. Every reported play from a remote player on a
remote URL would then quietly fail its metadata lookup and go unscrobbled.

## Side effects worth knowing

- **Each remote player gains one `_client:<playerid>` section** in
  `plugin.audioscrobbler.prefs`, holding its account and any pending
  scrobbles. A player id that changes per request (as the test suite's ids
  do) leaves one section per id.
- **Each remote player also gains one `_client:<playerid>` section** in
  `server.prefs` — LMS's standard client defaults (`titleFormat`,
  `playername`, and so on), installed by `initPrefs`. A real client gets the
  same section when it connects; a synthetic one has no connection to hang it
  on, so the same "one section per id" growth applies.
- **A test run against a server with an account writes to that Last.fm
  profile.** That is the feature working: reported plays are queued and
  submitted like a real player's, through the server's own account — there is
  no separate test identity to send them to.
- **Listening History gains entries under the remote player's id**, in its own
  SQLite store. A track play is one entry; consecutive same-album plays are
  one album entry. Both are visible in the plugin's own app and can be removed
  there. The plugin's retention setting applies to them like any other entry.
- **The play count cannot be undone through the plugin.** It can be edited in
  LMS's database, or reset from the track's information page. APC's count and
  values for the track can be reset from its information page too ("Reset all
  APC values for this track").
- **APC's dynamic played/skipped value rises with every reported play**, as
  it does for any play APC counts. The auto-rating step also runs when it is
  configured; both are APC's own behaviour, not an extra write here.
