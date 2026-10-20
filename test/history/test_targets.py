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
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import (LMS, RUN_ID, library_track_with_stats,  # noqa: E402
                    require_player)


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
        # Unique per test as well as per run: two tests of one class would
        # otherwise report the same play and the second would be a duplicate.
        # A play time of this run's own, so the duplicate store does not
        # mistake it for a previous run's play. The plugin's future allowance
        # covers the skew between this machine's clock and the server's.
        self.played = (int(time.time()) - 30
                       - zlib.crc32(self.id().encode()) % 300)

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

    def test_a_reported_play_appears_in_the_apc_history(self):
        """The row is filtered by the remote player's id, which this run
        invented, so anything returned is the row this request wrote."""
        player = require_player(self.lms)

        r = self.report()
        self.assertEqual(r.get("accepted"), 1)

        history = self.lms.call(
            ["alternativeplaycount", "jiveplayhistoryitems", "all", "",
             self.playerid],
            client=player,
        )
        if history.get("_error"):
            self.skipTest(f"Alternative Play Count does not answer: "
                          f"{history['_error']}")

        enabled = self.lms.call(
            ["pref", "plugin.alternativeplaycount:playhistory", "?"])
        if enabled.get("_p2") in ("0", 0):
            self.skipTest("Alternative Play Count's play history is off")

        items = history.get("item_loop") or []
        texts = [i.get("text", "") for i in items]
        self.assertTrue(
            any(self.track["title"][:25] in t for t in texts),
            "the report did not reach APC's play history: "
            f"{texts[:2]}")
