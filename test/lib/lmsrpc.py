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

    def call(self, cmd, timeout=90):
        """Send one slim.request. Returns the result dict, or {'_error': ...}."""
        body = json.dumps({"id": 1, "method": "slim.request",
                           "params": ["", cmd]}).encode()
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


# Providers that answer slowly and keep answering, which is what the suites
# about refills in flight need. Tried in this order.
ASYNC_CANDIDATES = ("BLISSMIXER_DSTM", "PLUGIN_LASTMIX_DSTM_MYMUSIC_ONLY")

# How a queue is given a starting point when a suite needs one. RandomPlay
# answers with a recipe the plugin expands itself, so it needs no seed of its
# own -- which is what makes it usable here.
SEED_TOKEN = "PLUGIN_RANDOM_TRACK"


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
        cls.playerid = f"{cls.queue}-{RUN_ID}"
        cls.lms = LMS()

        reachable = cls.lms.call(["players", 0, 1])
        if reachable.get("_error"):
            raise unittest.SkipTest(f"no LMS at {cls.lms.url}: {reachable['_error']}")

        _filtered, everything = cls.lms.tokens(cls.playerid)
        if SEED_TOKEN not in everything:
            raise unittest.SkipTest(
                f"{SEED_TOKEN} is not registered, so no queue can be seeded "
                "(is RandomPlay enabled?)")

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
    """
    lms.clear(playerid)
    lms.dstm("config", playerid, f"token:{token}", f"max:{count}")
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
