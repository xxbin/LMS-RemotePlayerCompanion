#!/usr/bin/env python3
"""Re-reporting the same play must not record it twice.

The API carries no idempotency token; the play itself is the token. A player
does not start the same track at the same second twice, so the player, the
resolved URL and the play time identify a repeat.

A request without `played` cannot dedupe: its entries are stamped with one
`now` taken per request, and a retry gets a different one. The documentation
says so; the tests always send `played`.
"""

import os
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import LMS, RUN_ID, library_track_with_stats  # noqa: E402


def code_of(result):
    return (result.get("error") or {}).get("code")


class Duplicates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        probe = cls.lms.call(["remoteplayercompanion", "history", "report"])
        if probe.get("_error") and not probe.get("error"):
            raise unittest.SkipTest(
                f"the history command does not answer at {cls.lms.url}: "
                f"{probe['_error']}")

        cls.track = library_track_with_stats(cls.lms)
        if not cls.track:
            raise unittest.SkipTest(
                "no library track carries a tracks_persistent row")

    def setUp(self):
        # A player and a play time of this run's own: the duplicate store
        # outlives the process, and a previous run's play at the same second
        # would make the first request look like a duplicate.
        self.playerid = f"rpc-dup-{RUN_ID}"
        self.played = int(time.time()) - 60 - (os.getpid() % 600)

    def report(self, **overrides):
        params = [f"id:{self.track['id']}", f"played:{self.played}"]
        r = self.lms.history(overrides.get("playerid", self.playerid), *params)
        self.assertIsNone(code_of(r), f"report refused: {r}")
        return r

    def test_the_same_report_twice_is_counted_once(self):
        first = self.report()
        self.assertEqual(first.get("accepted"), 1)
        self.assertEqual(first.get("duplicates"), 0)

        second = self.report()

        self.assertEqual(second.get("accepted"), 0)
        self.assertEqual(second.get("duplicates"), 1)

    def test_a_repeat_inside_one_report_is_counted_once(self):
        # The identity does not care where the repeat came from: a caller
        # whose local batch repeats a line reports the same play twice in
        # one request, and the store would only catch it on the next one.
        # A player of this test's own: the other test's play is the same
        # track at nearly the same second, and the store outlives the process.
        r = self.lms.history(
            f"rpc-dup-in-{RUN_ID}",
            f"id:{self.track['id']},{self.track['id']}",
            f"played:{self.played},{self.played}",
        )

        self.assertIsNone(code_of(r), f"report refused: {r}")
        self.assertEqual(r.get("accepted"), 1)
        self.assertEqual(r.get("duplicates"), 1)

    def test_two_players_reporting_the_same_second_are_two_plays(self):
        first = self.report(playerid=f"rpc-dup-a-{RUN_ID}")
        second = self.report(playerid=f"rpc-dup-b-{RUN_ID}")

        self.assertEqual(first.get("duplicates"), 0)
        self.assertEqual(second.get("duplicates"), 0)
        self.assertEqual(second.get("accepted"), 1)