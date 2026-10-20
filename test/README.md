# Tests

Integration tests that drive a running LMS over its JSON-RPC interface. They
exercise the plugin the way a remote player would: over the network, against
a real server with a real library and real DSTM providers.

They are ordinary `unittest` test cases — discovered, skipped and reported by
the standard machinery, with no test framework of our own and nothing to
install. Python 3 standard library only.

```bash
LMS_HOST=lms.local python3 test/run.py            # readable, recommended
```

Three ways to run them, all over the same files:

| Command | Output |
|---|---|
| `python3 test/run.py` | grouped by class, one line per test with its duration |
| `python3 -m unittest discover -s test -p "test_*.py" -v` | the standard one line per test, no timings |
| `python3 -m pytest test` | pytest's, if it is installed |

`run.py` only changes what is printed: it passes a `TextTestResult` subclass
to the standard runner, which is what the `resultclass` argument exists for.
Discovery, assertions, skipping and exit codes are all unchanged. The default
verbose format is terse by design — no timings, and test ids rather than
sentences — which is hard to read when a run takes eight minutes and you are
watching it.

`LMS_HOST` and `LMS_PORT` name the server and default to `127.0.0.1:9000`.
[pytest](https://pytest.org) runs the same files unchanged, for anyone who
prefers it: `pytest test`.

## Layout

One directory per command family, mirroring the modules under `DSTM/`, so
that a `cache/` or `sync/` family later has an obvious home.

```
test/
├── lib/lmsrpc.py               the client, and shared prerequisites
├── packaging/                  what build.py produces, which needs no server
│   └── test_package.py         the zip's shape, its sha, and the listing
└── dstm/                       the 'remoteplayercompanion dstm *' family
    ├── test_basic.py           the ordinary paths and the error paths
    ├── test_bootstrap.py       establishing a queue from nothing, and over
    ├── test_sources.py         offers every listed provider one, and measures
    ├── test_async_delivery.py  a provider answering later still gets its tracks in
    ├── test_fill_timeout.py    a stuck fill is cut off, its late result dropped
    ├── test_concurrent_take.py taking while a refill writes repeats no track
    └── test_defaults.py        the default depth and batch size, and seed
```

`history/` holds the other family:

```
test/history/
├── test_report.py      the request contract: refusals, and the receipt
├── test_duplicates.py  one report twice is one play
├── test_targets.py     where a play lands: the play count, then APC
└── test_nowplaying.py  the AudioScrobbler queue and now-playing
```

`packaging/` is the one directory that is not an integration suite: it checks
what `build.py` produces, so it needs no server and does not inherit
`DSTMTestCase`. It runs in a fraction of a second, and it is the reason a
malformed release fails here rather than on a stranger's server.

It is deliberately not called `build/`. Discovery puts `test/` on `sys.path`,
so a directory named `build` there is imported as the module `build` — and
wins over `build.py`, because it is reached first. The suite then fails with
`module 'build' has no attribute 'render_listing'` while every test in that
directory passes when run on its own, which is a confusing afternoon.

## What a run needs

The plugin installed and enabled, at least one DSTM provider, and **a player
LMS knows about**. A server without RandomPlay cannot be tested at all, since
that is how a queue is seeded — `DSTMTestCase.setUpClass` skips the whole class
for it, and it skips the same way when it can find no player.

### The player, and what the suites do to it

A queue adopts its provider from the player it is named for, so the queue *is*
the player: there is no separate per-run queue name any more. Two consequences
worth knowing before running these against a server you care about:

- **The suites change a real player's Dont Stop The Music provider.** They
  remember the value they found, print it, and put it back in `tearDownClass`.
  A run killed outright cannot restore it; the printed value is how it is put
  back by hand, and the preference file is
  `prefs/plugin/dontstopthemusic.prefs` on the server.
- **Two runs against one server collide**, because they share one player's
  queue. They used to be isolated by giving each run its own queue name.
- **The suites turn the plugin's own logging up**, to DEBUG for their duration.
  A logger builds its message only when its level admits one, so with the
  category at its default the plugin's debug lines never run — and a fault
  inside one of them, such as a value stringified on its way into an answer,
  cannot fail anything. The level is server-wide and LMS has no query that
  reads one back, so `tearDownClass` sets it to `ERROR`, the plugin's own
  default, rather than to whatever it was before. The run's output lands in the
  server's `server.log`.

`LMS_PLAYER` names the player to drive. Without it, the first player LMS
reports is used. **No player id is ever hardcoded here** — this repository is
public, and a MAC address is somebody's device.

### What the history suites do to a server

A report is a real write, and most of it cannot be undone from the plugin:

- **A reported play increments a real library track's play count.** The suite
  prints the count before and after each such test. It can be reset from the
  track's information page in LMS's web UI.
- **APC rows are written** under the run's own remote player id, so they can be
  removed from APC's play history view.
- **A server with an AudioScrobbler account configured scrobbles them.** That
  is the feature being tested, not a leak. The tests that also announce a
  now-playing track run only under `LMS_HISTORY_SCROBBLE=1` so that a run says
  when it is about to submit to a real profile; every other test still submits
  when the server has an account, and must be run against a profile you mean
  to write to.
- Each remote player id the suites use gains a `_client:<playerid>` section
  in `plugin.audioscrobbler.prefs`, holding its account and any pending
  scrobbles. A player id that changes per run leaves one section per run.

Expect **several minutes** against a real server. Most of the time is
`test_sources`, which seeds a queue and offers it to each provider in turn --
the per-provider progress it prints as it goes is the best way to see where
the time lands -- and the rest is real waiting on real fills: cutting that
further would mean cutting the waits and retries, which is coverage paid for
with speed. The packaging suite needs no server and is over before you notice
it.

| Suite | Also needs |
|---|---|
| `test_async_delivery`, `test_fill_timeout`, `test_concurrent_take` | one asynchronous provider, looked up from `lmsrpc.ASYNC_CANDIDATES` |

Those three ask for the property they need and **skip with a reason** when no
provider has it. A skip means **nothing was concluded**, not that something
passed: a provider may legitimately answer with an empty list, so a run where
it never contributed proves nothing either way.

## Four ways these tests were wrong before

Kept here because every one of them produced confident-looking output, and
because they are the kinds of mistake that are easy to make again.

**Measuring the seed instead of the provider.** Several providers select from
what the queue already holds, so these suites seed the queue first.
`test_sources` then has to measure tracks added *beyond* the seed — an
earlier version checked `total > 0`, which the seed already satisfied, and so
reported every provider as working.

**Measuring something that had not happened yet.** `config` answers before
the provider does, by design. An earlier version configured a provider and
read the queue on the next line, so it could only ever see the seed.
Anything that waits on a fill has to actually wait for it.

**Depending on a provider staying broken, or staying cooperative.**
`test_fill_timeout` once assumed a particular plugin never called back, which
stopped being true when that plugin was fixed. `test_async_delivery` once
treated a provider answering with an empty list as a failure. Both needed
someone else's behaviour to hold still. They now ask for the property they
need — slow and productive, or asynchronous — and skip when the server has no
provider that fits.

**Reporting an environment problem as a defect.** `test_sources` once
decided a provider "was refused" by reading the provider back after a
`config`, rather than by reading the `config` response. A single dropped
request was therefore reported as *two named providers that cannot be
configured* — a specific, plausible, and entirely false bug report. The
response is the only thing that can tell a refusal from a request that never
arrived.
