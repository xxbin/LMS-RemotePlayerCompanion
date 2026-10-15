# The `dstm` family

Detail for the `dstm` family of [Remote Player Companion](../README.md): what the
queue is, how it is kept full, and then the commands, what they take, what they
answer with, and what they fail with.

It is written for whoever works on this next, so the mechanics come first and the
command reference follows; the advice about which provider to give a queue is at
the end.

## What it is

A rolling queue of tracks to play next, filled from the providers Dont Stop The
Music has registered.

The remote player is a *cached* player: it keeps audio on the device and plays it
locally, which means it has to know what to fetch before it needs it. It asks for a
batch to cache, and the plugin answers from a queue it keeps topped up in the
background — so the player never waits on a slow or asynchronous
music-discovery provider.

```
   player ──nextbatch──▶ tracks ──take──▶ a batch of tracks to cache
                         ▲
                         └──── fill ───── DSTM provider (RandomPlay, LastMix, …)
```

Two things are true of every command here, and are described in the README rather
than repeated:

- **The remote player is not an LMS client.** It is addressed by the `playerid`
  parameter with `params[0]` left empty, which is what keeps it out of the
  `players` query, the web UI and the sync-target list — see
  [The remote player is not an LMS client](../README.md#the-remote-player-is-not-an-lms-client).
- **Failures come back as results, never as a request status**, and lists come back
  as LMS-style `*_loop` results — see
  [the shape every family shares](../README.md#the-shape-every-family-shares).

All of these are registered with `needsClient = 0`.

## How it works

### The queue's tracks and its seed

A queue's record holds two lists, and the difference between them matters:

- **`tracks`** — what is waiting to be handed out. `nextbatch` serves from it,
  `total` counts it, `clear` empties it;
- the **seed** — what the provider derives its selection *from*. `nextbatch` never
  serves it, `take` never touches it, and `total` does not count it.

The provider is given **both**, as one playlist, through the synthetic client it is
handed — that is what `Queue::playlist` is. A client's playlist is how a provider
asks what is playing, so a queue handed over this way looks like a player, and
RandomPlay's genre tokens take their genres from what this queue has been holding.

Keeping them apart is what makes a named seed possible. `seed url:<track>` says
what the queue is *about* — the track the player is already listening to — and that
track must never come back in a batch, so it is kept out of the list that
`nextbatch` serves.

**The seed follows the queue.** Every batch that hands tracks over leaves the last
of them as what the queue is about, so a queue that has served anything always has
something for a provider to derive from, even once the queue has drained. A batch
that hands over nothing leaves the seed as it was, there being nothing newer to
make it from.

That matters more than it sounds, and it is the reason for most of the care taken
below. A provider handed an empty queue does not merely answer with nothing:
LastMix asks DSTM for the properties of whatever the queue holds, DSTM answers
`undef` when there is nothing there, and LastMix passes that to
`Storable::dclone` without checking, which kills it and leaves `HANDLER_DIED` on
the queue.

Providers that do not want any of this need none of it: `PLUGIN_RANDOM_*` answers
with a recipe the plugin expands itself, and RatingsLight selects from the whole
library, so both work on an empty queue.

### Establishing a queue

**Establishing** a queue is two things: giving it a provider, and giving it
something to work from. Everything else here assumes a queue that has.

**Where the provider comes from.** Named in `config token:`, or adopted by `seed`
from the player's own Dont Stop The Music setting — and either way it ends up in
both: the queue's record, and that player's setting. The `config` section below has
what it means to write the second one.

Three consequences follow, and all three surprise people:

- **The queue's `playerid` must be an id LMS knows.** The preference is keyed by
  client id, so a queue named for something LMS has never heard of has no setting
  to read and no provider to adopt.
- **It is a snapshot.** Changing the player's provider in LMS does not change a
  running queue; the new one is taken the next time `seed` or `config` runs. That is
  deliberate — the queue reports one provider and draws from that same one — but it
  does mean "I changed the setting and nothing happened" is expected rather than a
  fault.
- **The whitelist is narrow, on both routes.** See below.

**Why the whitelist is narrow.** DSTM's registry carries one entry per favourite
alongside the real providers — radio stations and albums alike, under the
favourite's own title. A queue pointed at one of those is pointed at a single
favourite rather than at a mix, so it is refused with `PROVIDER_NOT_OFFERED`, and
`sources` lists what can be used instead.

**A seed's tracks are the plugin's own selection, not the provider's.** Asking a
provider that needs a seed to supply that seed is the problem, not the solution, so
`seed` reaches for RandomPlay's own picks rather than asking the queue's provider
for something to work from. It is a starting point, not a curated one, and the
queue's real provider takes over from the very next fill.

### One fill

A **fill** is one pass at topping the queue up to `max`, running in the
background. `seed` kicks one after it has given the queue material, `nextbatch`
kicks one for the tail it just took, and nothing else does — `config` sets a
provider and a depth and starts no fill of its own, because a fill needs something
to fill *from* and giving a queue that is not `config`'s job.

A DSTM provider delivers its tracks by calling the callback it is handed:

```perl
$handler->( $client, sub { my ($client, $tracks) = @_; ... } );
```

There is no separate "async result" to go and collect. What differs between
providers is only *when* control comes back:

```
  synchronous provider                asynchronous provider
  --------------------------------    --------------------------------
  _step calls invoke                  _step calls invoke
    handler(...) calls its cb           handler(...) returns immediately,
      inline, with the tracks             having kept the callback
    invoke returns                      invoke returns
  invoke has therefore already        (control goes back to the event loop,
    called our callback before          and the command that started this
    it returned                         fill is free to answer)
                                      ... later ...
                                      the provider's HTTP call finishes
                                        and it calls its cb
                                      invoke's callback runs now

  in both cases: our callback appends the tracks, then _schedule()s the
  next turn of the loop
```

So a fill is **not a loop that blocks**; it is a chain that re-arms itself from
inside the provider's callback. That is also why each step is scheduled with a
zero-delay timer rather than called directly: several providers answer
synchronously — every RandomPlay token does — and without that yield to the event
loop the whole chain would run to completion inside the command that started it, so
`seed` would block on a provider that answers only when it is ready.

**One fill per queue at a time, bounded by a single budget timer.** Without that
bound, a provider that accepts the callback and never calls it would leave the
queue's fill gate closed for good, and every later fill for that queue would be
refused. When the budget expires the fill ends as `SOURCE_TIMEOUT`.

Three guards keep late or stray results out of the queue, and all three are
needed:

- the fill's callback re-checks that this fill is still the live one — the state
  exists, is running, and is *the same hash* — before writing. A result arriving
  after the fill ended finds nothing to write to. Comparing identity rather than
  presence matters: a new fill for the same queue would otherwise accept the old
  one's answer;
- `_finish` and `abandon` clear `running` and delete the state, so a callback still
  in flight is discarded rather than acted on;
- the callback **re-reads the record** before touching it, because a `nextbatch`
  may have taken tracks while the provider call was in flight. Writing back the
  copy loaded before the call would undo that take and hand the same track out
  twice.

The budget timer is the only thing that can end a fill stuck waiting on a callback
that never arrives.

**What a fill records.** Why a fill ended without producing anything goes on the
queue as `last_error`, and `status` reports it. Without that, a caller sees an
empty queue and cannot tell a provider that timed out from one that genuinely had
nothing to offer. `last_error` is cleared again when a fill does add something.

**Callers that need more than the queue holds** register as *waiters* rather than
being answered short: `nextbatch` on an empty queue parks, and is woken when it
grows enough, or when the fill ends, or when its own budget runs out.
That is the only time any command here blocks.

### The queue is a window, not an archive

`seed` puts the first tracks in, and the fills that follow carry the queue up to
`max`; `nextbatch` takes from the front and a fill puts more on the end. Nothing is
ever trimmed away behind a caller's back, because nothing has to be: the queue is
bounded by how deep it is, not by time, so tracks leave it only when somebody asks
for them.

That is also why `nextbatch` normally answers at once however slow the provider
is. There is no waiting to be done while there is anything to hand over.

### Where a queue's record is kept

Queue records live in `Slim::Utils::Cache`, under a namespace of our own rather
than the default `cache` one. The default namespace is not durable on this LMS:
its version marker does not read back, so `Slim::Utils::Cache::new()` concludes
the version changed and clears the whole namespace on every server start. A
configured queue has to outlive a restart — its depth and its provider are stored
for exactly that — so it gets a namespace and a version of its own.

### How a token becomes a handler

Dont Stop The Music resolves a provider token through a per-client setting:
`getHandler($client)` reads `plugin.dontstopthemusic:provider` from the client it
is handed, and that is the only public door — the handler registry itself is
lexical to DSTM.

Resolving *our* token therefore means putting it where `getHandler` will read it.
We write it into the preference of a throwaway object, call `getHandler`, and put
the preference back immediately. `getHandler` is the only reader, so the swap never
has to stay open across a possibly asynchronous provider call; the cost is one
small leftover key per configured remote player in that preferences file.

Two details of that API are worth knowing, because both are silent when got wrong.
`getSortedHandlerTokens` takes its client as the *first* argument and has no
`$class` slot, so it must be called as a plain function — called with `->`, the
package name takes the client's place. `getHandler` does have a `$class` slot and
*is* called with `->`.

## Commands

Every command here takes `playerid`, which names the queue: the remote player is
not an LMS client, so there is nothing else to identify it by. It has to be an id
LMS knows — [Establishing a queue](#establishing-a-queue) says why. Every other
parameter is optional, and the commands are set out below in the order a caller
meets them.

### The order to call them in

One thing is needed and everything else is optional or a repeat: **a queue that
has a provider and something to work from**. Three calls can establish one, and
they are the first three below.

| | Step | |
|---|---|---|
| 0 | `sources playerid:<id>` | optional — which providers `config` can be given |
| 1 | `config playerid:<id> [token:<T>] [max:<N>]` | optional — `token:` names a provider, and **overwrites the one the player has in LMS**; without it the queue uses that setting as it stands. `max` is the queue's depth, 50 unless said |
| 2 | `seed playerid:<id> [url:<u> \| id:<n>]` | **required once**, unless `config token:` named a provider or `nextbatch` is left to establish the queue itself — adopts the provider the player is set to, and creates the queue |
| 3 | `nextbatch playerid:<id> [count:<N>] [tags:<letters>]` | the loop — call it whenever the player wants more |
| 4 | `queue`, `status` | optional, any time — both read-only |
| 5 | `clear`, `forget playerid:<id>` | optional — `clear` empties the tracks, `forget` drops the queue's record |

A queue draws from the provider **the player** is set to, which is why `seed`
takes no token: it adopts that setting.

**Config, then seed, then nextbatch** is the order this is meant to be used in.
`config` says which provider the queue should draw from — and, since it writes the
player's own setting too, which one the player should; `seed` adopts that and gives
the queue something to work from; `nextbatch` is the loop from then on.

Seeding is worth doing deliberately rather than leaving it to `nextbatch`, even
though nothing below insists on it. A seed can name the track the queue is to be
built around, which `nextbatch` cannot, so the queue `nextbatch` establishes for
itself is built from the plugin's own random selection instead. Seeding is also the
deliberate moment at which a queue is started over.

What is left is one call that works on its own. With the player already set to a
provider in LMS:

```
["", ["remoteplayercompanion", "dstm", "nextbatch", "playerid:02:00:79:b3:5d:7c", "count:20"]]
```

`nextbatch` finds no queue, establishes one, and hands out a batch — the same
establishment `seed` performs, minus the track a named seed would supply. It does
the same for a queue that has a provider but nothing for it to work from, and in
that case it keeps the provider the queue already has: a batch request is no place
to re-point somebody's queue, where `seed` is the command that deliberately
re-adopts the player's setting.

**A player set to no provider is the one thing that cannot be worked around.**
`seed` and `nextbatch` both answer `NO_PROVIDER`, and say where to set one.

#### After that it is a loop

`nextbatch` takes from the front of the queue and refills the tail in the
background, so it is called again and again and there is nothing to re-arm between
calls. It answers at once with whatever the queue holds, however short of `count`
that falls. It waits only when the queue is empty, since then there is nothing to
return at all.

`config` does not have to be called again either. Its depth persists in the queue
record, across restarts.

#### Seed again when the player's provider changes

The provider is a **snapshot**: a queue goes on drawing from the one it adopted
until something adopts another. Changing the provider in LMS does not reach a
running queue. `seed` again — with or without a track — is what picks up a change,
and it also refreshes the queue's derivation material.

**A seed starts the queue over.** It drops the tracks, and the material a previous
seed established along with it, because a queue that kept either would go on
deriving from a provider — or a track — the caller has moved on from. So seeding a
queue that is playing throws away whatever it was holding, and seeding twice in a
row does the work twice. That is the price of the only way to pick up a provider
change.

Both modes start over, and they differ only in what replaces what:

- A seed that **names a track** sets the derivation material to that one track.
  "I am playing this now" is a statement about the present, so the previous
  material is replaced rather than added to.
- A seed that **names nothing** fills the queue to half its depth, from
  the plugin's own selection.

### `sources` — the providers `config` can be given

```
["", ["remoteplayercompanion", "dstm", "sources", "playerid:02:00:79:b3:5d:7c"]]
```

| Parameter | Default | |
|---|---|---|
| `all` | 0 | `1` lists DSTM's registry unfiltered, favourites and all |

```json
{ "playerid": "…", "selected_provider": "", "count": 24, "hidden": 179,
  "sources_loop": [ { "token": "PLUGIN_RANDOM_TRACK", "name": "Song Mix",
                      "selected": 0 }, … ] }
```

`sources` lists the providers this plugin will accept, which are the ones
`config token:` takes: each entry's `token` is the value to pass there, and the
list is how a caller finds out what is available without having to know DSTM's own
names for things. A queue does not have to be given one of these — `config` takes
any token DSTM knows, and turns away the ones a queue cannot use — but these are
the ones worth choosing from.

`count` is how many were listed and `hidden` how many were left out —
[A note on `sources`](#a-note-on-sources) has the reason and the rule. `selected`
marks the token the queue is already configured with, and that token stays in the
list even when it would not otherwise be offered. `selected_provider` is the same
token, or empty for a queue with no provider.

Fails with `DSTM_DISABLED` when Dont Stop The Music is not enabled.

### `config` — the queue's depth, and the provider the player uses

```
["", ["remoteplayercompanion", "dstm", "config", "playerid:02:00:79:b3:5d:7c",
                                            "token:PLUGIN_RANDOM_TRACK", "max:50"]]
```

| Parameter | Default | |
|---|---|---|
| `token` | — | A provider to point the queue at, empty to disable the queue, or omitted to leave the player's own configuration alone |
| `max` | 50 | How deep the queue is, 1–100. Persisted, so it survives a restart |

```json
{ "playerid": "…", "max": 50, "provider": "PLUGIN_RANDOM_TRACK", "total": 0 }
```

`total` is what the queue holds at the moment of the answer. On one being set up for
the first time it is `0`, because `config` starts no fill: that is not a failure,
and it is not a reason to read the queue again on the next line.

**`token:` is about the system's Dont Stop The Music configuration, not only about
this queue.** Naming a provider writes it to two places: the queue's record, and
the player's own `plugin.dontstopthemusic:provider` setting — the same setting
LMS's Dont Stop The Music pages read and write. So it does not merely point one
queue somewhere: it **overwrites the provider that player is configured with**, and
LMS's own screens will show the new one afterwards. Configuring a queue for a
player changes that player.

Leaving `token:` out is what leaves that configuration alone, and it is why the
parameter is described as optional: a queue with no provider of its own adopts the
player's, so what it uses is the system's configuration as it stands. That is also
why `seed` takes no token of its own.

**An empty `token:` disables the queue.** Sending no provider is not the same as
sending none: `config max:` on its own leaves the queue's provider alone, where
`config token:` clears it. Disabling clears the provider from **both** places — the
record and the player's own setting — and empties the tracks along with the seed.
The player's setting has to go too, and that is not tidiness: a queue with no
provider establishes one from the player the next time anything asks it for tracks,
so a disable that stopped at the record would be undone by the next `nextbatch`.

`status` is how the two states are told apart afterwards: a disabled queue reports
`configured: 1` with an empty `provider` and `total: 0`, where a queue that was
never established reports `configured: 0`.

Fails with `BAD_MAX`, `UNKNOWN_PROVIDER`, `PROVIDER_NOT_OFFERED` or
`DSTM_DISABLED`.

### `seed` — establish a queue, or start one over

```
["", ["remoteplayercompanion", "dstm", "seed", "playerid:02:00:79:b3:5d:7c"]]
["", ["remoteplayercompanion", "dstm", "seed", "playerid:02:00:79:b3:5d:7c",
                                              "url:file:///music/what-im-playing.flac"]]
```

| Parameter | Default | |
|---|---|---|
| `url` | — | A library track to build the queue around. Never handed to the player |
| `id` | — | The same, by track id. Give one or the other, not both |

There is **no `count`**: a seed fills to half the queue's depth and no size of its
own — 25 tracks at the default depth of 50, which is not meant to line up with
`nextbatch`'s default of 10. The two answer different questions. A caller that passes one has it **ignored**, not refused, because parameters
this plugin does not read are simply not read. That is worth knowing when updating
a caller.

```json
{ "playerid": "…", "max": 50, "provider": "PLUGIN_RANDOM_TRACK",
  "added": 25, "total": 25, "seeded_track": "" }
```

The queue as it now stands, plus what the seeding did: `added` is how many tracks
went in, `total` is what the queue holds afterwards. `seeded_track` is the track the queue is
now built around, if one was named — reported so that a caller can tell a seed that
was taken from one that was ignored, because a seed that never lands otherwise
looks exactly like a queue that has not filled yet.

[The order to call them in](#the-order-to-call-them-in) has what a seed does to a
queue that is already running, and what the two modes replace.

Fails with `NO_PROVIDER`, `UNKNOWN_PROVIDER`, `PROVIDER_NOT_OFFERED`,
`DSTM_DISABLED`, `SEED_NOT_IN_LIBRARY`, `NO_SEED_AVAILABLE` or `BAD_PARAMETER`
(both `url:` and `id:` given).

### `nextbatch` — the loop

```
["", ["remoteplayercompanion", "dstm", "nextbatch", "playerid:02:00:79:b3:5d:7c",
                                                     "count:20", "tags:ydtalc"]]
```

| Parameter | Default | |
|---|---|---|
| `count` | 10 | How many to hand out, **at most 50 in one call** |
| `tags` | `ydtalc` | Which track fields to return — see [What each entry carries](#what-each-entry-carries) |

```json
{
  "playerid": "02:00:79:b3:5d:7c",
  "count": 2,
  "total": 18,
  "source": "PLUGIN_RANDOM_TRACK",
  "filling": 1,
  "batch_loop": [ { "url": "file:///music/a.flac", "id": 1234,
                    "title": "…", "artist": "…", "album": "…",
                    "year": "1957", "tracknum": "5", "duration": 679.523,
                    "coverid": "30776732" } ]
}
```

`count` is what was actually handed out, `total` what is left in the queue behind
it, `source` the provider it came from, and `filling` whether a refill is running.

There is no `complete`. How much arrived, how much is left and how deep the queue
is are all in the answer already, and a caller comparing those knows more about
what happened than a flag could tell it.

**Asking for more than 50 gets 50**, silently: the answer says what was handed
over, and the caller asked for the rest and can see it did not come.

**A short batch is a normal answer, not an error**, and it comes back at once:
anything at all in the queue is handed over rather than the caller being held
while a fill tries to do better. Waiting on a provider is time the caller spends
for the provider's sake, and a cached player draining its queue wants the tracks
it has, not a fuller batch later.

Only an **empty** queue waits — there is nothing to return, and the alternative
is an empty answer. The wait ends when the fill delivers, when the fill concludes
with nothing (answered with `count: 0` and no error, because a provider having
nothing new is a valid answer), or when the budget runs out.

Fails with `NOT_CONFIGURED`, `NO_PROVIDER`, `UNKNOWN_PROVIDER`,
`PROVIDER_NOT_OFFERED`, `DSTM_DISABLED`, `NO_SEED_AVAILABLE` or `SOURCE_TIMEOUT`.

### `queue` — read the queue without consuming it

```
["", ["remoteplayercompanion", "dstm", "queue", "playerid:02:00:79:b3:5d:7c",
                                                 "offset:0", "count:50"]]
```

| Parameter | Default | |
|---|---|---|
| `offset` | 0 | Page start |
| `count` | 50 | Page size. No ceiling, unlike `nextbatch`'s |
| `tags` | `ydtalc` | As `nextbatch` — see [What each entry carries](#what-each-entry-carries) |

```json
{ "playerid": "…", "total": 18, "offset": 0, "count": 2,
  "queue_loop": [ { … }, { … } ] }
```

`total` is everything the queue holds, `offset` and `count` describe the page, and
entries carry the same fields a batch does. Nothing is consumed, so this is how a
caller looks at what is coming without taking it.

### `status` — what a queue is

```
["", ["remoteplayercompanion", "dstm", "status", "playerid:02:00:79:b3:5d:7c"]]
```

```json
{ "playerid": "…", "configured": 1, "total": 18, "max": 50, "provider": "…",
  "filling": 0, "created": 1760000000, "updated": 1760000100 }
```

Everything a caller can know about a queue without asking for its contents, and
the cheapest way to tell whether one exists at all. `configured` is `0` for a
`playerid` no queue has been established for, and the other fields are then
defaults — `status` answers for a queue that does not exist rather than refusing.
`created` and `updated` are unix times, and `updated` moves whenever the record is
written.

`last_error` appears only when a fill has ended in an error, and carries a code and
a message. It is the answer to "why is this queue not filling" — see
[Errors](#errors) for why an empty batch on its own does not say.

### `clear` — empty the tracks

```
["", ["remoteplayercompanion", "dstm", "clear", "playerid:02:00:79:b3:5d:7c"]]
```

```json
{ "playerid": "…", "removed": 18 }
```

`removed` is how many tracks it dropped. The queue, its depth, its provider and its
seed all stay: this is only the tracks. The dedup memory goes with it — a queue
that has already served a track would otherwise refuse to hold it again — so a
cleared queue may hand out tracks it has served before.

### `forget` — drop the queue's record

```
["", ["remoteplayercompanion", "dstm", "forget", "playerid:02:00:79:b3:5d:7c"]]
```

```json
{ "playerid": "…", "forgotten": 1 }
```

`forgotten` says whether there was a record to drop, and asking twice is not an
error. This is the only way back to the state a player that has never used the
plugin is in, and the player's own Dont Stop The Music setting is left alone: that
setting belongs to the player rather than to this queue, and it is where the next
queue for this player will adopt its provider from.

### What each entry carries

`nextbatch` and `queue` return their entries through LMS's own tag machinery, so
`tags:` takes **LMS's own letters** and means here exactly what it means there.
LMS's `tracks` command takes the same parameter, and its documentation is the list
of letters to refer to; an unrecognised one is skipped rather than being an error.

There is no mapping of our own, deliberately: a second one would be a second thing
to keep in step with LMS, and a field LMS adds to its own would go missing here.

With no `tags:`, an entry carries `url`, `id`, `title`, `artist`, `album`, `year`,
`duration`, `tracknum` and `coverid` — the set these commands returned before there
was a `tags` parameter, plus `coverid`. `id` and `title` come back whatever the
tags say, and so does `url`, which is set from the queue rather than fetched from
the database.

**The types are LMS's own, and they are not uniform.** Measured on a real answer:
`id` is a number, `duration` is **seconds as a floating-point number** (`679.523`,
not `"11:19"`), and `year`, `tracknum` and `coverid` are **strings** (`"1957"`,
`"5"`, `"30776732"`). A caller that parses these should not assume a number, and
should not assume a string either.

`url` is always the one the queue handed out, which can differ from the
database's — a cue sheet gives a url a `#start-end` suffix — and it is the queue's
that the player has to be able to fetch. A track whose fields LMS cannot resolve —
an entry the database does not hold — comes back with its `url` alone rather than
taking the whole answer down.

**Artwork is a `coverid`, not a URL.** LMS builds an artwork URL that points at the
LMS itself, and a cached player is offline by the time it plays — the URL would be
dead on arrival. So the id is handed over and fetching the image is left to the
player, which can do it while it still has a connection. Anything that needs a URL
can build one from the id and the server it already knows.

## Errors

| Code | Meaning |
|---|---|
| `MISSING_PARAMETER` / `BAD_PARAMETER` | `playerid` absent or malformed, or `seed` given both `url:` and `id:` |
| `NOT_CONFIGURED` | The queue disappeared while the request was being served — reachable only when `forget` races a `nextbatch`. Nothing leaves a caller without a queue otherwise: `seed` and `nextbatch` both establish one |
| `NO_PROVIDER` | No Dont Stop The Music provider is set for the player, so there was nothing for `seed` — or for a `nextbatch` establishing a queue for itself — to adopt |
| `UNKNOWN_PROVIDER` | A token DSTM does not know — named in `config`, or found in the player's setting |
| `PROVIDER_NOT_OFFERED` | A token DSTM knows but `sources` would not offer, from either route |
| `SEED_NOT_IN_LIBRARY` | A named seed that is not a track in this library |
| `BAD_MAX` | `max` outside 1–100 |
| `NO_SEED_AVAILABLE` | Seeding could select no tracks at all — RandomPlay unavailable, or an empty library |
| `DSTM_DISABLED` | Don't Stop The Music is not enabled |
| `NO_HANDLER` | DSTM knows the token but resolved no handler |
| `HANDLER_DIED` | The provider **threw**. The exception is logged, since it is the only clue about the object it was handed |
| `SOURCE_TIMEOUT` | The fill budget expired, or a `nextbatch` waited out its own budget. The provider took the call and never delivered — not an error it reported |
| `UNRESOLVED_ENTITY` / `UNSUPPORTED_ENTITY` | A provider handed back a `db:` entity that could not be turned into tracks |
| `INTERNAL` | A fallback, for a failure with no code of its own |

**Not every failure is an error result.** `NO_HANDLER`, `HANDLER_DIED` and a fill
that ends at its budget without producing anything are recorded on the queue rather
than returned: `nextbatch` answers with however many tracks it has — possibly none
— and `status` carries `last_error`. An empty batch is therefore ambiguous on its
own, and `last_error` is what says why.

**Which command raises what.** `NO_PROVIDER` and the provider refusals come from
establishing a queue, so from `seed` and `nextbatch` alike; `BAD_MAX` is `config`'s;
`SEED_NOT_IN_LIBRARY` is `seed`'s, and `NO_SEED_AVAILABLE` is either of them when
the plugin can find nothing to seed with.

**A refusal changes nothing.** Everything that could refuse is checked before
anything is written, so a command that is turned away leaves the queue exactly as it
was — its provider included. Refusing is never a way to undo a queue that is already
working.

## A note on `sources`

DSTM's registry is a grab bag. RandomPlay, LastMix, Spotty and the rest name their
tokens `PLUGIN_<SOMETHING>`, but Favorites registers **one provider per favourite
under the favourite's own title** — radio stations and albums alike, and a library
with many favourites produces far more of those than it does real providers — while
other plugins simply use their own display names.

`sources` therefore offers the `PLUGIN_`-prefixed tokens plus the ones listed in
`EXTRA_TOKENS` (`DSTM/Provider.pm`), and reports how many it left out as `hidden`.
Pass `all:1` to see the registry as it stands. Add a token to `EXTRA_TOKENS` when it
generates a mix but carries no prefix; `BlissMixer`'s `BLISSMIXER_DSTM` is there
already.

The rule is a whitelist rather than a filter because a filter cannot be made
correct: DSTM resolves one handler per token and keeps its registry lexical, so
there is no way to ask a token who registered it. Subtracting the favourites by
title works for those and misses everything else, and matching names would have
thrown away real providers — BBC Sounds and BlissMixer register providers that
carry no `PLUGIN_` prefix at all.

## A note on choosing a provider

Not every token `sources` lists is one a remote player should be pointed at.

A cached player is offline by definition: it plays what it has already synced. A
provider that falls back to a streaming service when a candidate is not in the
local library answers with URLs the player can never cache, so the queue fills with
tracks that cannot be played on the road. That is the wrong direction for this
plugin, whatever the token's name suggests.

LastMix's tokens differ only in flags, and show the distinction plainly.
`PLUGIN_LASTMIX_DSTM_ITEM` is the plain mix: for every candidate the local database
does not hold, it asks a registered streaming service — Qobuz, Spotty, TIDAL — to
find the track instead. `PLUGIN_LASTMIX_DSTM_MYMUSIC_ONLY` and
`PLUGIN_LASTMIX_DSTM_CURRENT_LIBRARYVIEW_ONLY` set `myMusicOnly`, which skips that
step entirely; a stream cannot be cached, so they are the ones a queue wants.

The difference is not only one of taste. The service step runs *inside* the
provider, on the event loop, after the fill has already been started, and a service
handler that throws takes the whole provider chain down with it. The fill then ends
at its budget having added nothing — which, before the fill recorded why it ended,
was indistinguishable at the API from a provider that politely had nothing to give.
`status`'s `last_error` now tells the two apart, but the advice stands: prefer a
provider that stays inside the library. `sources` reports what DSTM has registered;
which of those reach outside it is not something the registry records, and not
something we can ask a token.

**Even a provider that stays inside the library can hand back something
uncacheable.** Tracks from integrated streaming services live in the same LMS
database as local files, so a `PLUGIN_RANDOM_TRACK` queue — about as local as a
provider gets — returns the occasional `qobuz://` URL. A caller that caches what it
is given has to filter on the URL scheme it can actually fetch, and treat what it
drops as normal rather than as an error.

## Logging

Everything the plugin logs goes under one category, `plugin.remoteplayercompanion`,
which LMS offers in its logging settings beside every other logger. It is left at
ERROR, so a healthy server says nothing; setting it to DEBUG is what makes the
queue's own account of every fill, seed, batch and refusal appear in `server.log`.

It is worth knowing that the category has to be *registered* to appear there — a
plugin that creates a logger with `logger()` alone gets a logger and no category,
so it logs and cannot be turned up from the settings page. That is an easy mistake
and an invisible one.
