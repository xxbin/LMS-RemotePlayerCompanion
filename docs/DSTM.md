# The `dstm` family

Detail for the `dstm` family of [Remote Player Companion](../README.md): the
commands, what they take and what they answer with, and why the queue works
the way it does.

A rolling queue of tracks to play next, filled from the providers Dont Stop
The Music has registered. The remote player asks for a batch to cache, and the
plugin answers from a buffer it keeps topped up in the background — so the
player never waits on a slow or asynchronous music-discovery provider.

All of these are registered with `needsClient = 0`, and carry the queue in the
`playerid` parameter with `params[0]` left empty.

| Command | Does | Blocking |
|---|---|---|
| `sources playerid:<id> [all:<0\|1>]` | Lists the DSTM providers worth pointing a queue at | no |
| `seed playerid:<id> [url:<u> \| id:<n>]` | Establishes a queue, or starts one over: adopts the player's provider, and gives it something to work from | no |
| `config playerid:<id> [token:<T>] [max:<N>]` | Sets the queue's depth, and optionally its provider. Optional — `seed` creates a queue without it | no |
| `nextbatch playerid:<id> [count:<N>] [tags:<letters>]` | Hands out the front of the buffer and refills the tail. Establishes a queue itself when there is none to serve from | only when the buffer is empty |
| `queue playerid:<id> [offset:<N>] [count:<N>] [tags:<letters>]` | Reads the buffer without consuming it | no |
| `status playerid:<id>` | Queue metadata, including whether a fill is running | no |
| `clear playerid:<id>` | Empties the buffer | no |
| `forget playerid:<id>` | Drops the queue's record — the only way back to the state a player that has never used the plugin is in | no |

## The order to call them in

One thing is needed and everything else is optional or a repeat: **a queue that
has adopted a provider**. One call gets there — there are two that do it, and
either can be the first.

| | Step | |
|---|---|---|
| 0 | `sources playerid:<id>` | optional — what there is to point a queue at |
| 1 | `seed playerid:<id> [url:<u> \| id:<n>]` | **required once**, unless `config token:` names a provider or `nextbatch` is left to establish the queue itself — adopts the provider the player is set to, and creates the queue |
| 2 | `config playerid:<id> [token:<T>] [max:<N>]` | optional — `token:` is the other way in, and creates the queue too; `max` is the buffer depth, 50 unless said |
| 3 | `nextbatch playerid:<id> [count:<N>] [tags:<letters>]` | the loop — call it whenever the player wants more. Establishes a queue itself when there is none to serve from |
| 4 | `queue`, `status` | optional, any time — both read-only |
| 5 | `clear`, `forget playerid:<id>` | optional — `clear` empties the buffer, `forget` drops the queue's record |

A queue draws from the provider **the player** is set to, which is why `seed`
takes no token: it adopts that setting.

Seeding first is the intended order, and it is worth doing even though nothing
below insists on it. A seed can name the track the queue is to be built around,
which `nextbatch` cannot, so the queue `nextbatch` establishes for itself is
built from the plugin's own random selection instead. Seeding is also the
deliberate moment at which a queue is started over.

What is left is one call that works on its own. With the player already set to
a provider in LMS:

```
["", ["remoteplayercompanion", "dstm", "nextbatch", "playerid:02:00:79:b3:5d:7c", "count:20"]]
```

`nextbatch` finds no queue, establishes one, and hands out a batch — the same
establishment `seed` performs, minus the track a named seed would supply.
`config` and `seed` remain how the queue is pointed somewhere in particular:
`seed url:<u>` builds it around a track, and `config token:<T>` names a
provider, writing it to the player's setting as well as to the record.

**A player set to no provider is the one thing that cannot be worked around.**
`seed` and `nextbatch` both answer `NO_PROVIDER`, and say where to set one.

### After that it is a loop

`nextbatch` takes from the front of the buffer and refills the tail in the
background, so it is called again and again and there is nothing to re-arm
between calls. It answers at once with whatever the buffer holds, however short
of `count` that falls. It waits only
when the buffer is empty, since then there is nothing to return at all.

`config` does not have to be called again either. Its depth persists in the
queue record, across restarts.

### Seed again when the player's provider changes

The provider is a **snapshot**: a queue goes on drawing from the one it adopted
until something adopts another. Changing the provider in LMS does not reach a
running queue. `seed` again — with or without a track — is what picks up a
change, and it also refreshes the queue's derivation material.

**A seed starts the queue over.** It drops the buffer, and the material a
previous seed established along with it, because a queue that kept either would
go on deriving from a provider — or a track — the caller has moved on from. So
seeding a queue that is playing throws away whatever it was holding, and seeding
twice in a row does the work twice. That is the price of the only way to pick up
a provider change.

Both modes start over, and they differ only in what replaces what:

- A seed that **names a track** sets the derivation material to that one track.
  "I am playing this now" is a statement about the present, so the previous
  material is replaced rather than added to.
- A seed that **names nothing** fills the buffer to half the queue's depth, from
  the plugin's own selection.

### What each step can fail with

`NO_PROVIDER` and the provider refusals come from establishing a queue, so from
`seed` and `nextbatch` alike; `BAD_MAX` is `config`'s; `SEED_NOT_IN_LIBRARY` is
`seed`'s, and `NO_SEED_AVAILABLE` is either of them when the plugin can find
nothing to seed with. The rest are in [Errors](#errors).

## Parameters

| Parameter | Used by | Default | Notes |
|---|---|---|---|
| `playerid` | all | — | Required. Identifies the queue, and must be an **id LMS knows** — see the note on where the provider comes from |
| `token` | `config` | — | A provider to point the queue at. Written to the record **and** to the player's own Dont Stop The Music setting |
| `max` | `config` | 50 | Buffer depth, 1–100. Persisted, so it survives a restart |
| `count` | `nextbatch`, `queue` | 10 / 50 | How many to hand out. `nextbatch` carries **at most 50 in one call**; `queue`'s is its page size and has no such ceiling. `seed` has none — see below |
| `url` | `seed` | — | A library track to build the queue around. Never handed to the player |
| `id` | `seed` | — | The same, by track id. Give one or the other, not both |
| `offset` | `queue` | 0 | Page start |
| `all` | `sources` | 0 | `1` lists DSTM's registry unfiltered |
| `tags` | `nextbatch`, `queue` | `ydtalc` | Which track fields to return. Letters are LMS's own — see below |

**`seed` has no `count`.** It fills the buffer to **half the queue's depth**,
because a seed only has to be enough for the provider to work from: half leaves
the other half for the tracks that provider is about to supply, rather than
filling the queue with seeds before it has said anything. With the default
depth of 20 that comes to 10, which is what `nextbatch` hands out by default
too — the two agree, but the seed's size follows the queue rather than a
constant of its own.

A caller that still passes `count:` to `seed` has it **ignored**, not refused,
because parameters this plugin does not read are simply not read. That is worth
knowing when updating a caller.

### Where a provider can come from

Named in `config token:`, or adopted by `seed` from the player's own Dont Stop
The Music setting. Both are sources and neither is privileged; the last one
written is the one both sides read.

[The note below](#a-note-on-where-the-provider-comes-from) has what follows
from that — including why the `playerid` has to be an id LMS knows.

## Responses

`nextbatch`:

```json
{
  "playerid": "02:00:79:b3:5d:7c",
  "count": 20,
  "total": 30,
  "source": "PLUGIN_RANDOM_TITLEMIX_WITH_GENRES",
  "filling": 1,
  "batch_loop": [ { "url": "file:///music/a.flac", "id": 1234,
                    "title": "…", "artist": "…", "album": "…", "duration": "3:26" } ]
}
```

`count` is what was actually handed out; `total` is what is left in the buffer
behind it; `source` is the provider it came from; `filling` says whether a
refill is running.

There is no `complete`. How much arrived, how much is left and how deep the
queue is are all in the answer already, and a caller comparing those knows more
about what happened than a flag could tell it.

**A single call carries at most 50 tracks.** Ask for more and the request is cut
down to that, silently: the answer says what was handed over, and the caller
asked for the rest and can see it did not come. Asking for 200 gets 50.

**A short batch is a normal answer, not an error**, and it comes back at once:
anything at all in the buffer is handed over rather than the caller being held
while a fill tries to do better. Waiting on a provider is time the caller spends
for the provider's sake, and a cached player draining its buffer wants the
tracks it has, not a fuller batch later.

Only an **empty** buffer waits — there is nothing to return, and the
alternative is an empty answer. The wait ends when the fill delivers, when the
fill concludes with nothing (answered with `count: 0` and no error, because a
provider having nothing new is a valid answer), or when the budget runs out
(`SOURCE_TIMEOUT`).

### What each track carries

`nextbatch` and `queue` build their entries through LMS's own tag machinery
(`Slim::Control::Queries::_songData`), so `tags:` takes **LMS's own letters** and
means here exactly what it means to `songinfo`. That is deliberate: a second,
hand-kept mapping would be a second thing to keep in step with LMS, and a field
LMS adds to its map would quietly go missing here.

With no `tags:`, an entry carries `url`, `id`, `title`, `artist`, `album`,
`year`, `duration`, `tracknum` and `coverid` — the set this command returned
before there was a `tags` parameter, plus `coverid`. `id` and `title` come back
whatever the tags say; `url` is always the one the buffer handed out, which can
differ from the database's (a cue sheet gives a url a `#start-end` suffix), and
it is the buffer's that the player has to be able to fetch.

`tags:cdg` would add `genre`; `tags:aAlbiz` adds the contributor roles
(`artist`, `trackartist`, `composer`, `albumartist`) and the work. An
unrecognised letter is skipped rather than being an error.

**Artwork is a `coverid`, not a URL.** LMS builds an artwork URL that points at
the LMS itself, and a cached player is offline by the time it plays — the URL
would be dead on arrival. So the id is handed over and fetching the image is
left to the player, which can do it while it still has a connection. Anything
that needs a URL can build one from the id and the server it already knows.

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
| `SOURCE_TIMEOUT` | The fill budget expired. The provider took the call and never delivered — not an error it reported |
| `UNRESOLVED_ENTITY` / `UNSUPPORTED_ENTITY` | A provider handed back a `db:` entity that could not be turned into tracks |
| `INTERNAL` | A fallback, for a failure with no code of its own |

## A note on where the provider comes from

Whichever way a provider arrives — named in `config`, or adopted by `seed` from
the player's own `plugin.dontstopthemusic:provider` — it ends up in the same
two places: the queue's record, and that player's Dont Stop The Music setting.
Both are sources, neither is privileged, and the last one written is the one
both sides read. So the player keeps behaving the way its queue does, and a
queue can be configured without going into LMS's UI.

Three consequences follow, and all three surprise people:

- **The queue's `playerid` must be an id LMS knows.** The preference is keyed
  by client id, so a queue named for something LMS has never heard of has no
  setting to read and no provider to adopt.
- **It is a snapshot.** Changing the player's provider in LMS does not change a
  running queue; the new one is taken the next time `seed` or `config` runs.
  That is deliberate — the queue reports one provider and draws from that same
  one — but it does mean "I changed the setting and nothing happened" is
  expected rather than a fault.
- **The whitelist is narrow, on both routes.** See below.

Each player's provider is independent of every other's, by construction: the
record is keyed by playerid and the setting is keyed by client id.

**Why the whitelist is narrow.** DSTM's registry carries one entry per
favourite alongside the real providers — radio stations and albums alike, under
the favourite's own title. A queue pointed at one of those is pointed at a
single favourite rather than at a mix, so `seed` refuses it with
`PROVIDER_NOT_OFFERED` and names `sources`, which lists what can be used.

**A refused `seed` changes nothing.** The provider is read and checked before
the record is touched, so a seed that fails leaves the queue exactly as it was,
provider included. Refusing is never a way to unconfigure a running queue.

## A note on `seed`

Several providers derive their selection from what the queue already holds —
LastMix looks for tracks similar to it, RatingsLight reads it to decide what to
rate — and a provider handed an empty queue either answers with nothing or
fails outright. LastMix asks DSTM for the properties of whatever the queue
holds, DSTM answers `undef` when there is nothing there, and LastMix passes
that to `Storable::dclone` without checking. Since `config` leaves a new queue
empty, such a provider could not be used at all without this.

`seed` fills the buffer to half the queue's depth and then triggers a refill, so
the queue's own provider takes over from the very next fill. It fills by
starting over rather than topping up — see
[Seed again when the player's provider changes](#seed-again-when-the-players-provider-changes).

The tracks come from the plugin's own selection, not from the queue's provider
— asking a provider that needs a seed to supply that seed is the problem, not
the solution. It is a starting point, not a curated one.

Providers that do not want one need none: `PLUGIN_RANDOM_*` answers with a
recipe the plugin expands itself, and RatingsLight selects from the whole
library, so both work on an empty queue.

### Naming the track to build around

With `url:` or `id:`, the seed is not a starting point but a subject: the
queue is built around that track, and **that track is never handed to the
player**. It is what the player is listening to already; handing it back is
not what was asked for.

The two are kept in separate lists for exactly this reason. The buffer is what
`nextbatch` serves; the named seed is what the provider derives from. The
provider is given both, so LastMix's similarity search and RandomPlay's genre
tokens both see the named track — while `take` never touches it and `total`
does not count it.

The named track must be in the library. DSTM resolves buffer URLs through
`Slim::Schema->objectForUrl`, and a URL it cannot resolve yields nothing, which
for a deriving provider is the same silent failure as an empty queue — so
`seed` resolves it first and answers `SEED_NOT_IN_LIBRARY` rather than
accepting it and quietly doing nothing.

A named seed **replaces** any previous one. "I am playing this now" is a
statement about the present, not an accumulation. It is also applied to a
queue that is already full, which the usual "already holds enough" early
return would otherwise swallow.

## A note on `sources`

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

## A note on choosing a provider

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

## Design notes

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

Everything the plugin logs goes under one category, `plugin.remoteplayercompanion`,
which LMS offers in its logging settings beside every other logger. It is left at
ERROR, so a healthy server says nothing; setting it to DEBUG is what makes the
lines above — and the queue's own account of every fill, seed, batch and refusal —
appear in `server.log`.

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
