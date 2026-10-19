#!/usr/bin/env python3
"""The 'remoteplayercompanion history report' command: request validation.

A successful answer tells the caller to delete its copy, so every request the
plugin cannot take ownership of must be refused before anything is written.
These are those requests.
"""

import os
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import LMS, library_track_with_stats  # noqa: E402


def code_of(result):
    return (result.get("error") or {}).get("code")


class HistoryTestCase(unittest.TestCase):
    """One LMS whose plugin offers the history family."""

    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        # An unregistered command closes the JSON-RPC socket with no body,
        # which arrives as a transport error and no result. A registered one
        # answers with MISSING_PARAMETER for this bare request.
        probe = cls.lms.call(["remoteplayercompanion", "history", "report"])
        if probe.get("_error") and not probe.get("error"):
            raise unittest.SkipTest(
                f"the history command does not answer at {cls.lms.url}: "
                f"{probe['_error']}")

    def library_track(self):
        track = library_track_with_stats(self.lms)
        if not track:
            self.skipTest("no library track carries a tracks_persistent row")
        return track


class Refusals(HistoryTestCase):
    """Requests the plugin must not consume."""

    def test_missing_playerid_is_refused(self):
        r = self.lms.call(["remoteplayercompanion", "history", "report"])
        self.assertEqual(code_of(r), "MISSING_PARAMETER")

    def test_no_track_source_is_refused(self):
        r = self.lms.history("living-room")
        self.assertEqual(code_of(r), "MISSING_PARAMETER")

    def test_both_id_and_url_are_refused(self):
        r = self.lms.history("living-room", "id:1", "url:file:///x.mp3")
        self.assertEqual(code_of(r), "BAD_PARAMETER")

    def test_malformed_playerid_is_refused(self):
        r = self.lms.history("bad*id", "id:1")
        self.assertEqual(code_of(r), "BAD_PARAMETER")

    def test_an_empty_item_is_refused(self):
        r = self.lms.history("living-room", "id:1,,2")
        self.assertEqual(code_of(r), "BAD_PARAMETER")

    def test_an_empty_list_is_refused(self):
        r = self.lms.history("living-room", "id:")
        self.assertEqual(code_of(r), "BAD_PARAMETER")

    def test_a_trailing_comma_is_refused(self):
        """A plain split() would drop the empty tail, hiding the mistake."""
        r = self.lms.history("living-room", "id:1,")
        self.assertEqual(code_of(r), "BAD_PARAMETER")

    def test_an_unknown_id_is_refused(self):
        r = self.lms.history("living-room", "id:999999999")
        self.assertEqual(code_of(r), "UNRESOLVED_TRACK")

    def test_an_unresolvable_local_url_is_refused(self):
        r = self.lms.history("living-room", "url:file:///nonexistent/x.mp3")
        self.assertEqual(code_of(r), "UNRESOLVED_TRACK")

    def test_a_list_length_mismatch_is_refused(self):
        r = self.lms.history("living-room", "id:1,2", "played:1")
        self.assertEqual(code_of(r), "LIST_LENGTH_MISMATCH")

    def test_a_non_integer_played_is_refused(self):
        for value in ("abc", "-1", "1.5", ""):
            with self.subTest(value=value):
                r = self.lms.history("living-room", "id:1", f"played:{value}")
                self.assertEqual(code_of(r), "INVALID_PLAYED")

    def test_a_play_older_than_the_window_is_refused(self):
        r = self.lms.history("living-room", "id:1",
                             f"played:{int(time.time()) - 8 * 86400}")
        self.assertEqual(code_of(r), "INVALID_PLAYED")

    def test_a_play_far_in_the_future_is_refused(self):
        r = self.lms.history("living-room", "id:1",
                             f"played:{int(time.time()) + 3600}")
        self.assertEqual(code_of(r), "INVALID_PLAYED")

    def test_too_many_entries_are_refused(self):
        r = self.lms.history("living-room", "id:" + ",".join(["1"] * 501))
        self.assertEqual(code_of(r), "TOO_MANY_TRACKS")


class Receipt(HistoryTestCase):
    """What a request the plugin accepts answers with."""

    def test_a_normal_report_answers_with_the_receipt(self):
        track = self.library_track()

        r = self.lms.history("living-room", f"id:{track['id']}")

        self.assertIsNone(code_of(r), f"report refused: {r}")
        self.assertEqual(r.get("playerid"), "living-room")
        self.assertEqual(set(r) & {"accepted", "duplicates", "queued",
                                   "nowplaying_status"},
                         {"accepted", "duplicates", "queued",
                          "nowplaying_status"})
        self.assertEqual(r.get("nowplaying_status"), "skipped")

    def test_nowplaying_alone_is_a_valid_request(self):
        track = self.library_track()

        r = self.lms.history("living-room", f"nowplaying:{track['id']}")

        self.assertIsNone(code_of(r), f"now-playing-only refused: {r}")
        self.assertEqual(r.get("accepted"), 0)

    def test_a_successful_answer_carries_no_loop(self):
        """A loop item would be per-destination detail the caller ignores."""
        track = self.library_track()

        r = self.lms.history("living-room", f"id:{track['id']}")

        for key in r:
            if key.endswith("_loop"):
                self.fail(f"the receipt carries a loop: {key}")