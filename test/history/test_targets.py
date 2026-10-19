#!/usr/bin/env python3
"""Where a reported play lands: LMS's play count, then APC's play history.

The play count cannot be restored: reporting a play increments a real
library track's count by one, permanently. The test prints what it was and
what it became. APC rows are local and can be removed from APC's own UI.
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


def playcount(lms, track_id):
    r = lms.call(["songinfo", 0, 100, f"track_id:{track_id}", "tags:O"])
    for item in r.get("songinfo_loop") or []:
        if "playcount" in item:
            return item["playcount"]
    return None


class Targets(unittest.TestCase):
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
        self.playerid = f"rpc-target-{RUN_ID}"
        # A play time of this run's own, so the duplicate store does not
        # mistake it for a previous run's play.
        self.played = int(time.time()) - 30 - (os.getpid() % 300)

    def report(self):
        r = self.lms.history(self.playerid, f"id:{self.track['id']}",
                             f"played:{self.played}")
        self.assertIsNone(code_of(r), f"report refused: {r}")
        return r

    def test_a_reported_play_increments_the_play_count(self):
        before = playcount(self.lms, self.track["id"])
        if before is None:
            self.skipTest("songinfo does not answer with a play count")

        r = self.report()

        after = playcount(self.lms, self.track["id"])
        print(f"\n  track {self.track['id']}: play count {before} -> {after}")
        self.assertEqual(r.get("accepted"), 1)
        self.assertEqual(int(after), int(before) + 1)
        self.assertIsInstance(after, str,
                              "songinfo exposes the count as a string")