# Remote Player Companion

An LMS plugin that provides the server-side services a cached/offline remote
player needs in order to work away from the server: dynamic playlists,
playback information sync, favourites sync, and the like.

A cached/offline remote player keeps a music library’s audio files on a mobile device ahead of time—by syncing or downloading them—and then plays them locally. Its purpose is to keep playback going on an unreliable mobile network. This plugin is only the server-side half of that setup: it provides such a player with what it needs from the server, such as the dynamic playlist to work through, playback history batches to report back, and favourites to keep in sync.

It speaks LMS's own protocols, offering an LMS-style JSON-RPC and CLI
interface. The separate functions are provided as separate subcommands, and
later versions will add the further subcommands that remote players turn out
to need.

## Command families

Commands are `remoteplayercompanion <family> <action>`, so a family can be
added without disturbing the others. Each family is a directory under the
plugin, and registers its own commands.

| Family | For | Status |
|---|---|---|
| [`dstm`](#the-dstm-family) | What to play next: a rolling queue filled from Dont Stop The Music providers | implemented |
| `convert` | What the player can play: the server's transcoding and format support, as it applies to a remote player | planned |
| `history` | Playback history, so listening done offline can be reported back | planned |
| `favorites` | Favourites, kept in step in both directions | planned |
| `rating` | Track ratings, likewise | planned |

Only `dstm` exists today. The others are listed so the shape of the plugin is
clear, not because anything is stubbed out for them.

### The shape every family shares

- **The remote player is addressed by parameter, not by `params[0]`.** See
  [The remote player is not an LMS client](#the-remote-player-is-not-an-lms-client).
- **Failures come back as results, never as request statuses.** An error
  status makes the JSON-RPC layer close the socket without a body, leaving the
  caller with nothing to parse. Errors are therefore
  `{"error": {"code": …, "message": …}}` inside an otherwise normal result.
- **Lists come back as LMS-style `*_loop` results.** Both transports render
  them: JSON as an array of objects, the CLI as repeated `key:value` pairs.

## The `dstm` family

A rolling queue of tracks to play next, filled from the providers Dont Stop
The Music has registered. The remote player asks for a batch to cache, and the
plugin answers from a buffer it keeps topped up in the background — so the
player never waits on a slow or asynchronous music-discovery provider.

```
["", ["remoteplayercompanion", "dstm", "config",    "playerid:02:00:79:b3:5d:7c",
                                            "token:PLUGIN_RANDOM_TITLEMIX_WITH_GENRES",
                                            "max:100"]]
["", ["remoteplayercompanion", "dstm", "nextbatch", "playerid:02:00:79:b3:5d:7c", "count:20"]]
["", ["remoteplayercompanion", "dstm", "queue",     "playerid:02:00:79:b3:5d:7c"]]
```

All of them are registered with `needsClient = 0`, and carry the queue in the
`playerid` parameter with `params[0]` left empty.

| Command | Does | Blocking |
|---|---|---|
| `sources playerid:<id> [all:<0\|1>]` | Lists the DSTM providers worth pointing a queue at | no |
| `config playerid:<id> [token:<T>] [max:<N>]` | Stores the queue's settings and kicks the first fill | no |
| `seed playerid:<id> [count:<N>]` | Gives an empty queue a starting point to work from | no |
| `nextbatch playerid:<id> [count:<N>]` | Hands out the front of the buffer and refills the tail | only if the buffer is short |
| `queue playerid:<id> [offset:<N>] [count:<N>]` | Reads the buffer without consuming it | no |
| `status playerid:<id>` | Queue metadata, including whether a fill is running | no |
| `clear playerid:<id>` | Empties the buffer | no |

### Parameters

| Parameter | Used by | Default | Notes |
|---|---|---|---|
| `playerid` | all | — | Required. Identifies the queue; one queue per remote player |
| `token` | `config` | — | A DSTM provider token, as listed by `sources` |
| `max` | `config` | 100 | Buffer depth. Persisted, so it survives a restart |
| `count` | `seed`, `nextbatch`, `queue` | 10 / 20 / 50 | `seed`: how many tracks to start it with. `nextbatch`: how many to hand out. `queue`: page size |
| `offset` | `queue` | 0 | Page start |
| `all` | `sources` | 0 | `1` lists DSTM's registry unfiltered |

### Responses

`nextbatch`:

```json
{
  "playerid": "02:00:79:b3:5d:7c",
  "count": 20,
  "complete": 1,
  "total": 30,
  "source": "PLUGIN_RANDOM_TITLEMIX_WITH_GENRES",
  "filling": 1,
  "batch_loop": [ { "url": "file:///music/a.flac", "id": 1234,
                    "title": "…", "artist": "…", "album": "…", "duration": "3:26" } ]
}
```

`count` is what was actually handed out, `total` is what is left in the buffer,
and `complete` says whether the requested `count` was met. A short batch is a
normal answer, not an error — the provider may simply have nothing new to give.

### Errors

| Code | Meaning |
|---|---|
| `MISSING_PARAMETER` / `BAD_PARAMETER` | `playerid` absent or malformed |
| `NOT_CONFIGURED` | No queue for that `playerid`, or `config` never set a provider |
| `UNKNOWN_PROVIDER` | The token is not in DSTM's registry |
| `BAD_MAX` | `max` outside 1–10000 |
| `DSTM_DISABLED` | Don't Stop The Music is not enabled |
| `NO_HANDLER` | DSTM knows the token but resolved no handler |
| `SOURCE_TIMEOUT` | The wait budget expired with nothing to hand out |

### A note on `seed`

Several providers derive their selection from what the queue already holds —
LastMix looks for tracks similar to it, RatingsLight reads it to decide what to
rate — and a provider handed an empty queue either answers with nothing or
fails outright. LastMix asks DSTM for the properties of whatever the queue
holds, DSTM answers `undef` when there is nothing there, and LastMix passes
that to `Storable::dclone` without checking. Since `config` leaves a new queue
empty, such a provider could not be used at all without this.

`seed` fills the buffer up to `count` (10 by default) and then triggers a
refill, so the queue's own provider takes over from the very next fill. It is
idempotent: a queue already holding that many is left alone.

The tracks come from the plugin's own selection, not from the queue's provider
— asking a provider that needs a seed to supply that seed is the problem, not
the solution. It is a starting point, not a curated one.

Providers that do not want one need none: `PLUGIN_RANDOM_*` answers with a
recipe the plugin expands itself, and RatingsLight selects from the whole
library, so both work on an empty queue.

### A note on `sources`

DSTM's registry is a grab bag. RandomPlay, LastMix, Spotty and the rest name
their tokens `PLUGIN_<SOMETHING>`, but Favorites registers **one provider per
favourite under the favourite's own title** — radio stations and albums alike,
and a library with many favourites produces far more of those than it does
real providers — while other plugins simply use their own display names.

`sources` therefore offers the `PLUGIN_`-prefixed tokens plus the ones listed
in `EXTRA_TOKENS` (`DSTM/Provider.pm`), and reports how many it left out as
`hidden`. Pass `all:1` to see the registry as it stands. Add a token to
`EXTRA_TOKENS` when it generates a mix but carries no prefix; `BlissMixer`'s
`BLISSMIXER_DSTM` is there already.

The rule is a whitelist rather than a filter because a filter cannot be made
correct: DSTM resolves one handler per token and keeps its registry lexical,
so there is no way to ask a token who registered it. Subtracting the
favourites by title works for those and misses everything else, and matching
names would have thrown away real providers — BBC Sounds and BlissMixer
register providers that carry no `PLUGIN_` prefix at all.

A token the queue is already configured with stays in the list even when it
would not be offered, so that `selected_provider` never names something the
caller cannot see.

### A note on choosing a provider

Not every token `sources` lists is one a remote player should be pointed at.

A cached player is offline by definition: it plays what it has already synced.
A provider that falls back to a streaming service when a candidate is not in
the local library answers with URLs the player can never cache, so the queue
fills with tracks that cannot be played on the road. That is the wrong
direction for this plugin, whatever the token's name suggests.

LastMix's tokens differ only in flags, and show the distinction plainly.
`PLUGIN_LASTMIX_DSTM_ITEM` is the plain mix: for every candidate the local
database does not hold, it asks a registered streaming service — Qobuz,
Spotty, TIDAL — to find the track instead.
`PLUGIN_LASTMIX_DSTM_MYMUSIC_ONLY` and
`PLUGIN_LASTMIX_DSTM_CURRENT_LIBRARYVIEW_ONLY` set `myMusicOnly`, which skips
that step entirely; a stream cannot be cached, so they are the ones a queue
wants.

The difference is not only one of taste. The service step runs *inside* the
provider, on the event loop, after the fill has already been started, and a
service handler that throws takes the whole provider chain down with it. The
fill then ends at its budget having added nothing — which at the API is
indistinguishable from a provider that politely had nothing to give. Prefer a
provider that stays inside the library. `sources` reports what DSTM has
registered; which of those reach outside it is not something the registry
records, and not something we can ask a token.

### Design notes

**The buffer is a rolling window, not an archive.** `config` fills it to `max`
in the background and `nextbatch` takes from the head while refilling the tail.
Because it is bounded by construction, nothing is ever trimmed away behind the
caller's back, and `nextbatch` normally answers instantly no matter how slow
the provider is.

**The buffer is also the seed.** Providers registered by RandomPlay's
`*_WITH_GENRES` tokens derive their genres from
`Slim::Player::Playlist::playList($client)` — the current playlist of whoever
is asking. We hand the provider our buffer as that client, so the genres come
from what the queue already holds and successive batches stay in the same
vein. When the buffer is empty there is no seed, the recipe carries no genres,
and the batch degrades to an unfiltered pick. This is why the buffer is
load-bearing rather than bookkeeping.

**RandomPlay's genre selection limits what a queue can draw from.** The
provider tokens are resolved through `RandomPlay::Mixer::getIdList`, which
includes only the genres enabled in RandomPlay's own settings. A server that
has deselected most of its genres will find its queues restricted to the rest
— a library of a few thousand tracks can leave a queue drawing from barely a
hundred, with nothing in the API to say why. It is the price of reusing
RandomPlay's selection instead of writing another one; the debug log records
the counts (`includedGenres=` / `excludedGenres=`) when it needs explaining,
and RandomPlay's settings are where it is changed.

**Provider tokens are resolved without registering a client.** `%handlers` is
lexical to DSTM, so the only public door is `getHandler($client)`, which reads
the token from that client's `provider` preference. We write the token into the
preference of a throwaway object, call `getHandler`, and restore the preference
immediately — `getHandler` is the only reader, so the swap never has to stay
open across a possibly async provider call. Resolving a token therefore costs
one small leftover key in the `plugin.dontstopthemusic` preferences file per
configured remote player.

`getSortedHandlerTokens` takes its client as the first argument with no `$class`
slot: it must be called as a plain function, not with `->`, or the package name
silently takes the client's place. `getHandler` does have a `$class` slot and is
called with `->`.

**Fills yield to the event loop.** Several providers answer synchronously —
every RandomPlay token does. If a fill called them back to back, it would run to
completion inside the command that started it, and `config` would block despite
being documented as non-blocking. Each fill step is scheduled with a zero-delay
timer, so the chain always returns to the event loop first.

**Queue records use a private cache namespace.** Records live in
`Slim::Utils::Cache`, but under a namespace of our own rather than the default
`cache` one. The default namespace is not durable: its version marker does not
read back on this LMS, so `Slim::Utils::Cache::new()` concludes the version
changed and clears the whole namespace on every server start. A configured
queue has to outlive a restart, so it gets its own namespace and version.

## The remote player is not an LMS client

This applies to every family, and it is the one decision the rest follows from.

A remote player is addressed by parameter and is never inserted into
`%clientHash`. That is what keeps it invisible: it does not appear in the
`players` query or the web UI player list, it is never announced over
SSDP/UPnP, and it cannot be picked as a sync target — all for free, because
those enumerations walk `%clientHash`.

It also rules out `params[0]`, which JSON-RPC resolves through `getClient()`
against the same hash. An id that is not registered there arrives as `undef`,
and a `needsClient = 1` command would then fail with status 103 and a closed
socket. Every command is therefore registered with `needsClient = 0` and takes
the remote player's id as a parameter.

## Deployment

The plugin directory must be named `RemotePlayerCompanion` and sit in one of
LMS's plugin directories:

```
<plugin-dir>/RemotePlayerCompanion/
├── Plugin.pm          entry point: brings up the command families
├── DSTM/              the 'remoteplayercompanion dstm *' family
│   ├── CLI.pm         command handlers and their registration
│   ├── Queue.pm       the queue: records and buffer operations
│   ├── Refill.pm      the refill loop: gating, waiters, timeouts
│   ├── Provider.pm    provider invocation, filtering, result routing
│   ├── RandomPlay.pm  the RandomPlay coupling: recipes and id selection
│   ├── Tracks.pm      ids and db: entities into playable track URLs
│   └── VClient.pm     the synthetic client handed to providers
├── install.xml
└── strings.txt
```

That tree is `src/` in the repository, which holds the plugin and nothing
else — so it is also exactly what a release packages.

Adding a family means a directory beside `DSTM/` and one line in
`Plugin.pm`'s `initPlugin`, where each family registers its own commands.

LMS needs a restart to pick the plugin up. `restartserver` over the CLI socket
(port 9090) does it without a service manager:

```bash
printf 'restartserver\n' | nc 127.0.0.1 9090
```

## Tests

Integration tests that drive a real server over JSON-RPC live in `test/`, one
directory per family. See [test/README.md](test/README.md).

```bash
LMS_HOST=127.0.0.1 python3 test/run.py
```

## Releases

The repository URL to add in LMS's plugin settings is

```
https://xxbin.github.io/LMS-RemotePlayerCompanion/repo.xml
```

A release is a tag. `build.py` reads the version from `src/install.xml`, which
is the only place it is written, and refuses to run if the tag disagrees with
it:

```bash
# src/install.xml <version> must already say 0.2.0
git tag v0.2.0 && git push origin v0.2.0
```

CI then builds the zip, attaches it to the release, and deploys `repo.xml`.
The zip can be reproduced from the tag alone by running `python3 build.py`, so
the published SHA-1 can be checked rather than trusted.
