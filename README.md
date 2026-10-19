# Remote Player Companion

An LMS plugin that provides the server-side services a cached/offline remote
player needs in order to work away from the server: dynamic playlists,
playback information sync, favourites sync, and more.

To install it, add this repository in LMS's plugin settings:

```
https://xxbin.github.io/LMS-RemotePlayerCompanion/repo.xml
```

A cached/offline remote player keeps a music library's audio files on a mobile
device ahead of time — by syncing or downloading them — and then plays them
locally. Its purpose is to keep playback going on an unreliable mobile network.
This plugin is only the server-side half of that setup: it provides such a
player with what it needs from the server, such as the dynamic playlist to work
through, playback history batches to report back, and favourites to keep in
sync.

It speaks LMS's own protocols, offering an LMS-style JSON-RPC and CLI
interface. The separate functions are provided as separate subcommands, and
later versions will add the further subcommands that remote players turn out
to need.

## Command families

Commands are `remoteplayercompanion <family> <action>`, so a family can be
added without disturbing the others. Each family is a directory under the
plugin, and registers its own commands.

One command belongs to no family: `remoteplayercompanion version` answers the
plugin's own version, read from `install.xml` — the only place it is written.

| Family | What it is for | Status |
|---|---|---|
| [`dstm`](#the-dstm-family) | What to play next: a rolling queue filled from Dont Stop The Music providers | implemented |
| `convert` | What the player can play: the server's transcoding and format support | planned |
| `history` | What the player has played: listening done offline, reported back to the server | planned |
| `favorites` | Favourites: the server's and the player's, kept in step in both directions | planned |
| `rating` | Track ratings: the server's and the player's, kept in step in both directions | planned |

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
plugin answers from a queue it keeps topped up in the background — so the
player never waits on a slow or asynchronous music-discovery provider.

```
["", ["remoteplayercompanion", "dstm", "config",    "playerid:02:00:79:b3:5d:7c",
                                            "token:PLUGIN_RANDOM_TITLEMIX_WITH_GENRES",
                                            "max:50"]]
["", ["remoteplayercompanion", "dstm", "seed",      "playerid:02:00:79:b3:5d:7c",
                                            "url:file:///music/what-im-playing.flac"]]
["", ["remoteplayercompanion", "dstm", "nextbatch", "playerid:02:00:79:b3:5d:7c", "count:20"]]
["", ["remoteplayercompanion", "dstm", "queue",     "playerid:02:00:79:b3:5d:7c"]]
```

`config` is what gives a queue its provider — the queue's own, kept in its
record and nowhere else — and `seed` then gives it something to work from, so
those two are the order to use. Given `url:` or `id:` — a comma-separated list
of tracks — a seed builds the queue around them without ever handing them to the
player. A `nextbatch` that
finds a queue with nothing in it gives it material the same way, though it cannot
name a track to build around as `seed` can.

Every command in the family is registered with `needsClient = 0`, and carries
the queue in the `playerid` parameter with `params[0]` left empty.

The rest of it — each command and the parameters it takes, the shapes it
answers with, the errors it raises, and why the queue is built the way it is
— is in **[docs/DSTM.md](docs/DSTM.md)**.

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
│   ├── Queue.pm       the queue: its records, and the operations on them
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

Two things are set up once, by hand, and neither is visible from this
repository:

- **Pages** enabled with source "GitHub Actions".
- **The `github-pages` environment** must allow `v*` tags. Its deployment
  branch rules default to branches only, and because the job declares that
  environment, GitHub applies the rule *before* the job starts. The run is
  then rejected with every step unrun: it appears as a failed deployment whose
  job shows no steps, and no release is created — which reads as a workflow
  bug rather than a settings one.
