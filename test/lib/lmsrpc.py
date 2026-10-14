"""Shared plumbing for the integration suites.

Standard library only, so a suite runs anywhere Python 3 does, against any
LMS reachable over HTTP. The server is named by --host/--port, by
LMS_HOST/LMS_PORT, or defaults to a local one.

The suites themselves are unittest.TestCase classes, so they are discovered,
skipped and reported by the standard mechanisms rather than by anything
invented here. This module holds only what they genuinely share: the client,
and the couple of prerequisites that are awkward to express per-test.
"""

import json
import os
import sys
import time
import unittest
import urllib.error
import urllib.request

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = "9000"

HOST = os.environ.get("LMS_HOST", DEFAULT_HOST)
PORT = os.environ.get("LMS_PORT", DEFAULT_PORT)

#: Makes this run's queues its own.
#:
#: The queue names are fixed per suite, so two runs against one server would
#: otherwise work on the same queues -- one clearing the buffer the other is
#: waiting to see fill, and both reporting failures that belong to neither.
#: It reads as a product fault, which is the worst way for a test to be wrong.
RUN_ID = f"{os.getpid():x}"


def url(host=None, port=None):
    return f"http://{host or HOST}:{port or PORT}/jsonrpc.js"


class LMS:
    """A JSON-RPC client for one LMS."""

    def __init__(self, host=None, port=None):
        self.url = url(host, port)

    def call(self, cmd, timeout=90, client=""):
        """Send one slim.request. Returns the result dict, or {'_error': ...}.

        `client` goes in params[0], outside the command array. Commands that
        are about a player rather than about the plugin -- playerpref above all
        -- are meaningless without one, and an empty client closes the socket
        with no body rather than answering.
        """
        body = json.dumps({"id": 1, "method": "slim.request",
                           "params": [client, cmd]}).encode()
        req = urllib.request.Request(
            self.url, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.URLError as exc:
            return {"_error": f"cannot reach {self.url}: {exc}"}
        except OSError as exc:
            return {"_error": f"transport error: {exc}"}
        if not raw.strip():
            return {"_error": "empty response body"}
        try:
            return json.loads(raw).get("result") or {}
        except ValueError:
            return {"_error": f"unparsable response: {raw[:200]}"}

    # The plugin's own commands, so a suite need not repeat the prefix.

    def dstm(self, action, playerid, *params, timeout=90):
        return self.call(["remoteplayercompanion", "dstm", action,
                          f"playerid:{playerid}", *params], timeout=timeout)

    def status(self, playerid):
        return self.dstm("status", playerid)

    def clear(self, playerid):
        return self.dstm("clear", playerid)

    def state(self, playerid):
        """(buffered, filling, last_error_code) -- what most suites look at."""
        r = self.status(playerid)
        return (r.get("total", 0), r.get("filling"),
                (r.get("last_error") or {}).get("code"))

    def tokens(self, playerid):
        """Every registered token, filtered view and unfiltered."""
        filtered = {s["token"] for s in
                    (self.dstm("sources", playerid).get("sources_loop") or [])}
        everything = {s["token"] for s in
                      (self.dstm("sources", playerid, "all:1").get("sources_loop") or [])}
        return filtered, everything

    # --- the player a queue adopts its provider from ---

    def players(self):
        """Ids of the players LMS knows, from its own players query."""
        return [p["playerid"] for p in
                (self.call(["players", 0, 100]).get("players_loop") or [])]

    def get_provider(self, playerid):
        """The Dont Stop The Music provider set for a player, or None.

        playerpref answers under a key named for the value's position in the
        request, so the value arrives as _p2 rather than under a name.
        """
        r = self.call(["playerpref", DSTM_PROVIDER_PREF, "?"], client=playerid)
        if r.get("_error"):
            return None

        values = [v for k, v in r.items() if k.startswith("_p") and k != "_p0"]
        value = values[0] if values else None

        # Dont Stop The Music's own settings write '0' for its "none" choice,
        # and reads a provider back through `|| ''`, so '0' means unset every
        # bit as much as a missing key does. '~' is what an unset preference
        # looks like in the file.
        return value if value and value not in ("~", "0") else None

    def set_provider(self, playerid, token):
        """Set a player's DSTM provider. True if it took."""
        r = self.call(["playerpref", DSTM_PROVIDER_PREF, token], client=playerid)
        return not r.get("_error") and not r.get("error")


# Providers that answer slowly and keep answering, which is what the suites
# about refills in flight need. Tried in this order.
ASYNC_CANDIDATES = ("BLISSMIXER_DSTM", "PLUGIN_LASTMIX_DSTM_MYMUSIC_ONLY")

# How a queue is given a starting point when a suite needs one. RandomPlay
# answers with a recipe the plugin expands itself, so it needs no seed of its
# own -- which is what makes it usable here.
SEED_TOKEN = "PLUGIN_RANDOM_TRACK"

#: The preference Dont Stop The Music keeps a player's provider in. A queue
#: adopts it for the player whose id the queue is named by, which is why a
#: suite needs a real player to test against at all.
DSTM_PROVIDER_PREF = "plugin.dontstopthemusic:provider"

#: The player the suites drive. Taken from the environment, else discovered.
#: Never hardcoded: this repository is public and a MAC address is a device.
PLAYER = os.environ.get("LMS_PLAYER") or None
PLAYER_FROM_ENV = bool(os.environ.get("LMS_PLAYER"))


def first_library_track(lms, limit=1):
    """A library track URL to seed with, or None if the library has none.

    LMS answers a `tracks` query under titles_loop, not tracks_loop.
    """
    r = lms.call(["tracks", 0, limit, "tags:u"])
    for t in (r.get("titles_loop") or []):
        if t.get("url"):
            return t["url"]
    return None


#: The provider each player had before this run touched it, recorded the first
#: time a suite drives that player. Kept here rather than per test class,
#: because a class whose setUpClass skips never reaches its tearDownClass --
#: and it is that path that leaves a test token behind on somebody's player.
#: Recorded once, every later class restores the right value.
_PROVIDER_ORIGINAL = {}


def remember_provider(lms, playerid):
    return _PROVIDER_ORIGINAL.setdefault(playerid, lms.get_provider(playerid))


def restore_provider(lms, playerid):
    """Put a player's provider back, or to DSTM's 'none' if it had none."""
    if playerid in _PROVIDER_ORIGINAL:
        lms.set_provider(playerid, _PROVIDER_ORIGINAL[playerid] or "0")


def require_player(lms):
    """A real player to test against, or skip stating why.

    A queue adopts its provider from the player it is named for, so a suite
    without a player cannot configure one at all.
    """
    if PLAYER:
        return PLAYER

    found = lms.players()
    if not found:
        raise unittest.SkipTest(
            "no player known to LMS, so no DSTM provider can be adopted; "
            "connect one or set LMS_PLAYER")
    return found[0]


class DSTMTestCase(unittest.TestCase):
    """One LMS, and a queue name of its own per test class.

    Suites expect a server they can reach and a plugin that answers; a server
    without RandomPlay cannot be tested at all, and says so by skipping
    rather than by failing.
    """

    #: the queue these tests use, before the run's own suffix is added
    queue = "test-unnamed"

    #: set from `queue` in setUpClass; the name the tests actually use
    playerid = "test-unnamed"

    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        reachable = cls.lms.call(["players", 0, 1])
        if reachable.get("_error"):
            raise unittest.SkipTest(f"no LMS at {cls.lms.url}: {reachable['_error']}")

        # A queue adopts its provider from the player it is named for, so the
        # queue IS the player. There is no per-run name any more, and two runs
        # against one server will share a queue and collide.
        cls.playerid = require_player(cls.lms)

        # Put back at the end: this is somebody's real player. Recorded once
        # per run rather than once per class, so that a class which skips
        # before its tearDownClass cannot strand a test token.
        cls._provider_before = remember_provider(cls.lms, cls.playerid)
        print(f"\n  player {cls.playerid}; its DSTM provider is "
              f"{cls._provider_before!r} and will be put back afterwards")

        _filtered, everything = cls.lms.tokens(cls.playerid)
        if SEED_TOKEN not in everything:
            raise unittest.SkipTest(
                f"{SEED_TOKEN} is not registered, so no queue can be seeded "
                "(is RandomPlay enabled?)")

    @classmethod
    def tearDownClass(cls):
        # Unconditionally, and against the value remembered for this player
        # rather than this class: the common original state is *no* provider,
        # which is falsy, and a class that skipped has no captured value at all.
        restore_provider(cls.lms, cls.playerid)

    @classmethod
    def use_provider(cls, token, max_depth=None):
        """Point this suite's queue at a provider, the way a user would.

        config names it -- which writes it into the player's own Dont Stop The
        Music setting as well as into the record -- and seed then adopts it
        back and creates the queue. Returns seed's response, or config's if
        config refused.

        That setting belongs to somebody's real player, so setUpClass
        remembered what it was and tearDownClass puts it back. A classmethod
        because setUpClass needs it too, and a classmethod cannot reach
        skipTest, which is an instance method.
        """
        params = [f"token:{token}"]
        if max_depth is not None:
            params.append(f"max:{max_depth}")

        r = cls.lms.dstm("config", cls.playerid, *params)
        if (r.get("error") or {}).get("code") or r.get("_error"):
            return r

        return cls.lms.dstm("seed", cls.playerid)

    def setUp(self):
        self.lms.clear(self.playerid)

    def tearDown(self):
        self.lms.clear(self.playerid)

    # --- the two things several suites need and none of them owns ---

    def seed(self, count=10):
        """Give the queue a starting point, and say how many it holds."""
        return seed_queue(self.lms, self.playerid, SEED_TOKEN, count)

    def pick_async(self):
        """A slow provider this server has, or skip the test."""
        token = pick_async(self.lms, self.playerid)
        if not token:
            self.skipTest("no asynchronous provider available (looked for: "
                          + ", ".join(ASYNC_CANDIDATES) + ")")
        return token


def pick_async(lms, playerid):
    """The first of ASYNC_CANDIDATES this server has, or None.

    Asking rather than assuming, so that a suite needing a slow provider can
    skip with a reason instead of failing on a server that has neither.
    """
    _filtered, everything = lms.tokens(playerid)
    for token in ASYNC_CANDIDATES:
        if token in everything:
            return token
    return None


def seed_queue(lms, playerid, token=SEED_TOKEN, count=10, cap=30):
    """Give a queue a starting point with a provider that needs none.

    Providers that select from what the queue holds answer with nothing when
    it is empty, so they are tested against a seeded queue and measured by
    what they add *beyond* it. Measuring the buffer's size instead would just
    be measuring the seed.

    Waits for the fill to stop rather than for a fixed time: seeding is on the
    critical path of every provider a sweep tries, and a fixed wait there
    costs minutes.

    The provider is adopted from the player's own Dont Stop The Music setting,
    which has to be set first -- config no longer takes a token -- and seed is
    what adopts it and fills the buffer from the plugin's own selection.
    """
    if not lms.set_provider(playerid, token):
        raise unittest.SkipTest(f"cannot set the DSTM provider for {playerid}")

    lms.clear(playerid)
    lms.dstm("config", playerid, f"max:{count}")

    # No count: seed fills to half the queue's depth and the provider's own
    # fill carries it the rest of the way to max, so the buffer still ends up
    # holding `count`.
    lms.dstm("seed", playerid)

    wait_for_fill(lms, playerid, cap)
    return lms.state(playerid)[0]


def wait_for_count(lms, playerid, target, seconds):
    """Poll until the buffer holds at least target, and return what it holds.

    Returns the count rather than a truth value: a predicate-based helper
    reads naturally but hands back whatever the predicate returned, which is
    how a caller ends up comparing True against a number.
    """
    deadline = time.time() + seconds
    while True:
        total = lms.state(playerid)[0]
        if total >= target or time.time() >= deadline:
            return total
        time.sleep(2)


def wait_for_fill(lms, playerid, seconds, quiet=1.0, interval=0.5):
    """Wait for a fill to finish, and return (buffered, last_error).

    A fill is deferred, so looking once and seeing an idle queue does not mean
    there is nothing to wait for -- it may be about to start. Two consecutive
    idle samples tell "not started yet" from "finished", which is what a fixed
    grace period was doing before, at four seconds a call and two calls per
    provider. This is the difference between a sweep taking four minutes and
    taking one.
    """
    deadline = time.time() + seconds
    idle_since = None
    total, err = lms.state(playerid)[0], None

    while time.time() < deadline:
        total, filling, err = lms.state(playerid)
        now = time.time()

        if filling:
            idle_since = None
        elif idle_since is None:
            idle_since = now
        elif now - idle_since >= quiet:
            break

        time.sleep(interval)

    return total, err


def run():
    """Run every suite, for callers that want one command rather than discover."""
    loader = unittest.TestLoader()
    start = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    suite = loader.discover(start, pattern="test_*.py")
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run())
