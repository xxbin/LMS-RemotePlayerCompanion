#!/usr/bin/env python3
"""Where a reported play lands: LMS's play count, APC's count and history.

Both play counts cannot be restored: reporting a play increments a real
library track's count, permanently, in LMS's table and in APC's. The test
prints what it was and what it became. APC rows are local and can be removed
from APC's own UI.
"""

import datetime
import os
import re
import sys
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import (LMS, RUN_ID, library_track_with_stats,  # noqa: E402
                    remove_listening_history, require_player)


def code_of(result):
    return (result.get("error") or {}).get("code")


def playcount(lms, track_id):
    r = lms.call(["songinfo", 0, 100, f"track_id:{track_id}", "tags:O"])
    for item in r.get("songinfo_loop") or []:
        if "playcount" in item:
            return item["playcount"]
    return None


def apc_playcount(lms, client, track_id):
    """APC's own count for a track, or None when APC does not show it.

    The line only appears when APC's count differs from LMS's, unless APC is
    configured to always show its values; None is a skip, not a failure.
    """
    r = lms.call(["trackinfo", "items", 0, 100,
                  f"track_id:{track_id}", "menu:trackinfo"], client=client)
    if r.get("_error"):
        return None
    for item in r.get("item_loop") or []:
        text = item.get("text") or ""
        if text.startswith("APC Play Count: "):
            try:
                return int(text.rsplit(":", 1)[1])
            except ValueError:
                return None
    return None


#: The play time APC's history shows, as MM/DD/YYYY HH:MM in server time.
STAMP = re.compile(r"(\d{2}/\d{2}/\d{4} \d{2}:\d{2})")


def history_stamp(text):
    match = STAMP.search(text or "")
    if not match:
        return None
    return datetime.datetime.strptime(match.group(1), "%m/%d/%Y %H:%M")


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
        # Per test, because a test may use an id of its own: the Listening
        # History rows a report writes must be found under the id it was
        # reported for.
        self.addCleanup(self._clean_up_listening_history)

        # A play time of this run's own, so the duplicate store does not
        # mistake it for a previous run's play.
        # Unique per test as well as per run: two tests of one class would
        # otherwise report the same play and the second would be a duplicate.
        # A play time of this run's own, so the duplicate store does not
        # mistake it for a previous run's play. The plugin's future allowance
        # covers the skew between this machine's clock and the server's.
        self.played = (int(time.time()) - 30
                       - zlib.crc32(self.id().encode()) % 300)

    def _clean_up_listening_history(self):
        remove_listening_history(self.lms, self.playerid)

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

    def test_a_reported_play_increments_the_apc_play_count(self):
        """APC's own count, not LMS's: the destination used to write only its
        history table. The line is read from the track's information page,
        which is where APC shows it."""
        player = require_player(self.lms)

        before = apc_playcount(self.lms, player, self.track["id"])
        if before is None:
            self.skipTest(
                "APC does not show its play count for this track (it hides "
                "it when it equals LMS's count); nothing to measure")

        r = self.report()

        after = apc_playcount(self.lms, player, self.track["id"])
        print(f"\n  track {self.track['id']}: APC play count {before} -> {after}")
        self.assertEqual(r.get("accepted"), 1)
        self.assertIsNotNone(after, "APC's count disappeared after the report")
        self.assertEqual(after, before + 1)

    def test_a_reported_play_keeps_its_play_time(self):
        """Two plays two hours apart, reported today. If APC's own "now" were
        left in the rows, both would carry the same minute and the difference
        would be zero."""
        player = require_player(self.lms)
        self.playerid = f"rpc-target-{RUN_ID}-time"

        first = int(time.time()) - 2 * 86400
        second = first + 2 * 3600 + 11 * 60

        r = self.lms.history(
            self.playerid,
            f"id:{self.track['id']},{self.track['id']}",
            f"played:{first},{second}")
        self.assertIsNone(code_of(r), f"report refused: {r}")
        self.assertEqual(r.get("accepted"), 2)

        history = self.lms.call(
            ["alternativeplaycount", "jiveplayhistoryitems", "all", "",
             self.playerid],
            client=player,
        )
        if history.get("_error"):
            self.skipTest(f"Alternative Play Count does not answer: "
                          f"{history['_error']}")

        stamps = [history_stamp(item.get("text"))
                  for item in history.get("item_loop") or []]
        stamps = sorted((s for s in stamps if s), reverse=True)

        if len(stamps) < 2:
            self.skipTest(
                "APC's history does not list both plays for this player "
                f"(listed {len(stamps)})")

        delta = int((stamps[0] - stamps[1]).total_seconds())
        print(f"\n  APC history: {stamps[0]} and {stamps[1]} "
              f"({delta // 60} minutes apart)")
        self.assertEqual(delta, 2 * 3600 + 11 * 60)
        self.assertGreater(stamps[0], stamps[1],
                           "the later play is listed first")

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
