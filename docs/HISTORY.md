# The `history` family

Detail for the `history` family of [Remote Player Companion](../README.md):
a batch of plays a remote player made away from the server, reported back and
recorded in the places the server already keeps listening history.

It is written for whoever works on this next: the contract first, then what
each destination gets, then the mechanics and the side effects worth knowing
about before running it against a server you care about.

## What it is

One request carries a batch of plays. For every play the plugin updates:

- **LMS's play count** — `tracks_persistent`, the count the web UI shows;
- **Alternative Play Count's Play History** — the row APC's own analyser would
  have written;
- **Listening History** — an entry in that plugin's own database, built with
  its own `Sources::describe`;
- **AudioScrobbler** — an item in LMS's own scrobble queue, which LMS then
  submits, retries and chunks exactly as it does for a real player.

```
   player ──history report──▶ plugin ──▶ LMS play count
                                     ├──▶ APC play history
                                     ├─▶ Listening History entry
                                     └──▶ AudioScrobbler queue ──▶ Last.fm
```

The first three are *targets* under `History/Targets/`: local destinations
with a batch interface (`new`, `name`, `status`, `apply`), each responsible
only for its own plugin's rules. AudioScrobbler is not a target because it
decides a whole-request refusal (the queue cap) before anything is written
and owns now-playing; `Report.pm` keeps it outside the target loop.

The command is `remoteplayercompanion history report`, registered with
`needsClient = 0`: the remote player is not an LMS client, so `playerid` is a
parameter and `params[0]` stays empty, as in the `dstm` family.

**Success transfers ownership.** A successful answer means the plugin has taken
the plays over, and the caller deletes its copy. That is why every request the
plugin cannot record in full is refused *before anything is written*, and why
the answer is a receipt rather than a per-destination report — there is nothing
left for the caller to retry.

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
  see [Now-playing](#now-playing).
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
id:   DSTM::Tracks->urlForId($id)          undef or '' -> UNRESOLVED_TRACK
url:  Slim::Schema->objectForUrl({url})
      undef and a remote URL -> Slim::Schema::RemoteTrack->new($url)
      otherwise              -> UNRESOLVED_TRACK
```

An ephemeral `RemoteTrack` is never inserted into the library. It exists so
AudioScrobbler can ask the protocol handler for artist, title and duration,
and so APC has a URL to record.

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

- `accepted` — entries the plugin took ownership of, equal to the number sent
  on a successful request.
- `duplicates` — entries already recorded from an earlier report, not applied
  again. They are consumed, not refused.
- `queued` — entries handed to the AudioScrobbler queue. Eligibility can reduce
  it (`too_short`, `ignored`, radio), and it is 0 when scrobbling is off, no
  account is configured, or the plugin is missing.
- `nowplaying_status` — `requested` (handed to the AudioScrobbler API),
  `skipped` (the newest play has ended, or its duration is unknown), or
  `unavailable` (the scrobbler would not take the track).

There is no per-destination field in the answer and no account field. The
targets apply the batch internally; how each destination fared is a debug log
line per entry, under the plugin's own log category.

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

Errors are results, never request statuses: an error status closes the JSON-RPC
socket with no body.

Environmental gaps are **not** refusals. No APC plugin, no Listening History
plugin (or it is disabled), no scrobbling account, scrobbling switched off, a
library scan in progress, a track with no `tracks_persistent` row, or a play
Listening History declines (a station, a service track with no duration) are
logged and the report is consumed — the caller cannot act on them, and keeping
its copy would produce the same outcome next time.

## What each destination gets

### 1. LMS's play count

The rules are `Slim::Player::Song`'s own: increment only when LMS statistics
are on, no scan is running, a `tracks_persistent` row exists, and the play is a
new listen rather than a seek. `lastplayed` becomes `max(existing, played)` and
is never lowered, so an out-of-order report counts the play without moving the
clock backwards.

### 2. APC's Play History

`AlternativePlayCount::Storage->addPlayEntry`, with the URL, its md5, the
track's MusicBrainz id, the reported play time, `remote`, and the remote
player's id as `client_id`.

Nothing else in APC is touched: not its counts table (tied to APC's own
threshold and skip handling), not its dynamic played/skipped values, not auto
rating. An imported play has no skip history, and a rating imported with a
present-day value would be a rating given *after* the listen.

The player is saved once per request, after the first row that landed, with
`last_seen` set to now — a six-day-old play reported today still means the
player was seen today.

### 3. Listening History

The plugin keeps its own SQLite store, and its live tracker has no public
"record this play" seam: `Tracker::_record` needs a live client and
`playingSong`, stamps the wall clock, and maintains in-memory session state.
A backfill has its own start times, so the target calls the storage functions
the tracker itself calls:

```
Plugins::ListeningHistory::DB::addEntry
Plugins::ListeningHistory::DB::addToEntry
```

That is the plugin's own API, not raw SQL and not a second database. The row
is built with `Plugins::ListeningHistory::Sources::describe`, so its rules are
the plugin's own:

- a station is skipped (and ends any album session);
- a service track with no duration is skipped;
- a Radio Paradise announcement is skipped;
- consecutive tracks of one album, with no repeat inside the run and the next
  starting within `session_gap_min` (default 30 minutes) of the previous
  play's end, become one `album` entry — the first play creates it, later
  plays are added and promote it.

`player_id` is the remote player's own id and `player_name` is `playername`,
falling back to that id. `played` is stored as both `started_at` and
`played_at`; the entry list orders by `played_at`, so a reported play appears
at the time it started.

Unlike the live tracker, an imported play does **not** trigger a Qobuz
release-type lookup: that is a network call per entry, and the imported row is
complete without it. A release type already known from a live fetch is kept.

The target is `unavailable` when Listening History is not installed, not
enabled, or a storage function is missing; a row the plugin declines is
`skipped`; a failed write is `error` for that play only. None of those fails
the report.

### 4. AudioScrobbler

LMS's implementation does the work. The plugin builds the queue item that
`newsongCallback` would have built and hands the queue back to LMS, which owns
the handshake, the retries, the 50-item chunking and the durable queue.
Nothing in this plugin posts to Last.fm.

**Eligibility**, in LMS's order: scrobbling enabled, an account configured,
metadata, at least 30 seconds, the ignore lists (`ignoreTitles`,
`ignoreArtists`, `ignoreAlbums`, `ignoreGenres`; case-insensitive substrings),
and radio only when `include_radio` allows it. A track that fails any of them
is logged with the reason and is not queued; the report still succeeds.

**Account selection.** The server's configured accounts are the only input.
A stored choice that still matches an account wins; otherwise a single account
is used; otherwise the first of several is chosen and named in a warning. The
choice is written into the synthetic client's own `account` preference, which
is what every later LMS path reads. Older LMS stores a bare username there,
newer LMS the full `username::api_type::api_url` id; the plugin asks the server
which it expects rather than assuming.

### Now-playing

There is no now-playing parameter. A player has one current track, and the
batch already says when each play started, so the plugin reads it from there:

- The **newest accepted play** in the request is the candidate. Play time
  decides, not position in the list; on a tie (a request without `played`
  stamps every entry with one `now`) the last entry wins.
- It is announced only if the server's clock is still inside that track's
  **duration** — `now - played < duration`. A play that has ended announces
  nothing, which is also what keeps a retried report (every entry a
  duplicate, so nothing accepted) from announcing again.
- No duration means no way to judge, and the plugin does not guess: the play
  is recorded and the status is `skipped`.
- The candidate is subject to the same eligibility checks as a scrobble,
  unlike LMS's own callback, which announces before applying its ignore
  lists: a track the user told LMS to ignore is not announced either.

After the scrobbles are queued — so a scrobble does not clobber the display —
the candidate is handed to the API. Historical now-playing is never replayed:
only the newest play of the current request can be announced.

**Order of writes.** Everything that can refuse the request is decided first:
scrobbler eligibility and the queue cap. Then LMS, APC, Listening History, the
scrobble queue, then now-playing, and only then is the duplicate store marked.
A server that dies mid-entry re-applies that entry on retry rather than
forgetting it.

### Duplicates

A play is identified by `md5(playerid, url, played)` in a durable cache
namespace with a seven-day expiry — the same window the request accepts. A
repeated report answers `accepted: 0` and `duplicates: n`, so a caller that
retried after a timeout can safely delete its copy.

A report without `played` is never recognised as a duplicate, because `now`
differs on every call: send `played` if the caller may retry.

## The synthetic client

AudioScrobbler stores a client's **id**, not the object: `API::new` keeps
`$client->id`, and every later path resolves it through
`Slim::Player::Client::getClient` — the handshake, the retry, the queue, the
metadata lookup, and `master()`. A client that is not in `%clientHash` works
for the first call and is lost at the first of those.

So one hidden client is created per remote player, from
`Slim::Player::Disconnected`. It is invisible to the `players` query, the web
UI and sync lists (`hidden` clients are filtered out), and it keeps each
remote player's account, queue and session to itself.

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

## Side effects worth knowing

- **Each remote player gains one `_client:<playerid>` section** in
  `plugin.audioscrobbler.prefs`, holding its account and any pending
  scrobbles. A player id that changes per request (as the test suite's do)
  leaves one section per id.
- **Reporting real plays to a server with an account configured scrobbles
  them.** That is the feature, but it means a test run against such a server
  submits to that Last.fm profile.
- **Listening History gains entries under the remote player's id**, in its own
  SQLite store. A track play is one entry; consecutive same-album plays are
  one album entry. Both are visible in the plugin's own app and can be removed
  there with More → Remove. The plugin's retention setting applies to them
  like any other entry.
- **The play count cannot be undone through the plugin.** It can be edited in
  LMS's database, or reset from the track's information page.
