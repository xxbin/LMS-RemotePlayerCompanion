#!/usr/bin/env python3
"""Listening History: the entry its own app lists for a reported play.

The plugin keeps its history in its own SQLite store. That store is not read
here: the test asks the plugin's By-player feed, the same view a user sees, so
a row that lands in the database but not in the feed still fails.

Every test uses a player id and display name of its own, so anything under
them is what this run wrote. Entries are removed afterwards through the
plugin's own `listeninghistory remove`.
"""

import os
import sys
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import (LMS, RUN_ID, remove_listening_history,  # noqa: E402
                    require_player)


def code_of(result):
    return (result.get("error") or {}).get("code")


def item_text(item):
    """Every human-readable field an OPML item may carry."""
    parts = [item.get(k, "") for k in ("text", "name", "line1", "line2")]
    return " ".join(p for p in parts if isinstance(p, str))


def library_tracks(lms, limit=1000):
    """Library tracks with the fields this suite names them by."""
    r = lms.call(["tracks", 0, limit, "tags:uald"])
    return [t for t in (r.get("titles_loop") or [])
            if t.get("id") and t.get("url") and t.get("title")]


def two_tracks_of_one_album(tracks):
    """A pair from one album, short enough for a realistic second start."""
    by_album = {}
    for track in tracks:
        if not track.get("album") or not track.get("duration"):
            continue
        if float(track["duration"]) > 600:
            continue
        by_album.setdefault(track["album"], []).append(track)

    for album_tracks in by_album.values():
        if len(album_tracks) >= 2:
            return album_tracks[0], album_tracks[1]
    return None


class ListeningHistory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        probe = cls.lms.call(["remoteplayercompanion", "history", "report"])
        if probe.get("_error") and not probe.get("error"):
            raise unittest.SkipTest(
                f"the history command does not answer at {cls.lms.url}: "
                f"{probe['_error']}")

        cls.tracks = library_tracks(cls.lms)
        if not cls.tracks:
            raise unittest.SkipTest("the library has no playable track")

        cls.track = cls.tracks[0]
        cls.album_pair = two_tracks_of_one_album(cls.tracks)

        cls.player = require_player(cls.lms)

        # The plugin's own app, and the By-player tile inside it. Both have
        # to answer for this suite to conclude anything. The tile is found by
        # its icon as well as its English label, so a server running another
        # language still works.
        items = cls._items(cls.lms, cls.player, [])
        if items is None:
            raise unittest.SkipTest(
                "Listening History does not answer its own app feed")

        cls.by_player_id = None
        for item in items:
            if ("By player" in item_text(item)
                    or "speaker" in (item.get("icon") or "")):
                params = (item.get("actions") or {}).get("go", {}).get("params") or {}
                cls.by_player_id = params.get("item_id")
                break

        if cls.by_player_id is None:
            raise unittest.SkipTest(
                "Listening History has no By player feed")

    @classmethod
    def _items(cls, lms, player, params):
        """The item_loop of one menu query, or None if the app does not answer."""
        r = lms.call(["listeninghistory", "items", 0, 200, "menu:1", *params],
                     client=player)
        if r.get("_error") or r.get("error"):
            return None
        return r.get("item_loop") or []

    def setUp(self):
        name = self.id().rsplit(".", 1)[-1].replace("_", "-")[:24]
        self.playerid = f"rpc-lh-{RUN_ID}-{name}"[:64]
        self.playername = f"RPC LH {RUN_ID} {name}"[:64]

        # An hour or two ago: inside the seven-day window, clear of other
        # tests' plays and of the future allowance.
        self.played = (int(time.time()) - 3600
                       - zlib.crc32(self.id().encode()) % 600)

    def tearDown(self):
        # By the player's own name, not by ids collected as the entries were
        # read: a test that fails before reading them has still written them.
        remove_listening_history(self.lms, self.playerid, self.playername)

    def report(self, *params, accepted=1):
        r = self.lms.history(self.playerid, *params)
        self.assertIsNone(code_of(r), f"report refused: {r}")
        self.assertEqual(r.get("accepted"), accepted)
        return r

    def player_row(self):
        items = self._items(self.lms, self.player,
                            [f"item_id:{self.by_player_id}"])
        if items is None:
            self.fail("Listening History stopped answering its By player feed")

        for item in items:
            if self.playername in item_text(item):
                return item

        self.fail(f"no Listening History player row for {self.playername!r}: "
                  f"{[item_text(i) for i in items]}")

    def entry_items(self, player_row):
        params = (player_row.get("actions") or {}).get("go", {}).get("params") or {}
        item_id = params.get("item_id")
        self.assertIsNotNone(item_id, f"player row has no go action: {player_row}")

        items = self._items(self.lms, self.player, [f"item_id:{item_id}"])
        if items is None:
            self.fail("Listening History stopped answering an entry list")

        # A history entry is playable; the sort row at the top is a link.
        return [i for i in items if i.get("type") in ("audio", "playlist")]

    def test_a_reported_play_is_an_entry_for_this_player(self):
        self.report(f"id:{self.track['id']}",
                    f"played:{self.played}",
                    f"playername:{self.playername}")

        row = self.player_row()
        self.assertIn("(1)", item_text(row),
                      "the player row should say it holds one entry")

        entries = self.entry_items(row)
        self.assertEqual(len(entries), 1, entries)

        text = item_text(entries[0])
        self.assertIn(self.track["title"][:25], text,
                      f"the entry does not name the track: {entries[0]}")

    def test_two_tracks_of_one_album_become_one_album_entry(self):
        if not self.album_pair:
            self.skipTest("the library has no album with two short tracks")

        first, second = self.album_pair
        second_played = (self.played + int(float(first["duration"])) + 120)

        self.report(f"id:{first['id']},{second['id']}",
                    f"played:{self.played},{second_played}",
                    f"playername:{self.playername}",
                    accepted=2)

        row = self.player_row()
        self.assertIn("(1)", item_text(row),
                      "two tracks of one album should be one entry")

        entries = self.entry_items(row)
        self.assertEqual(len(entries), 1, entries)
        self.assertEqual(entries[0].get("type"), "playlist",
                         f"the grouped entry is not an album: {entries[0]}")
        self.assertIn(first["album"][:25], item_text(entries[0]),
                      f"the album entry does not name the album: {entries[0]}")


if __name__ == "__main__":
    unittest.main(verbosity=2)