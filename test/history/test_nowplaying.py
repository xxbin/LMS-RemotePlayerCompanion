#!/usr/bin/env python3
"""The AudioScrobbler side of a report: the queue and now-playing.

A report is consumed on success, so `queued` and `nowplaying_status` are the
only two things a caller can observe about scrobbling.

Both are observable without an account, but a server that has one will submit
to a real Last.fm profile when a report is accepted. The assertions that
need an account therefore run only under LMS_HISTORY_SCROBBLE=1; the rest of
the suite submits anyway and cannot avoid it, which is a side effect stated in
test/README.md.
"""

import os
import sys
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import (LMS, RUN_ID, remove_listening_history)  # noqa: E402

#: Set to "1" to let the tests that need an account actually submit to it.
SCROBBLE = os.environ.get("LMS_HISTORY_SCROBBLE") == "1"


def code_of(result):
    return (result.get("error") or {}).get("code")


def scrobbling(lms):
    """(enabled, how many accounts) or None when the server will not say.

    The accounts preference holds credentials, so only its length is kept and
    nothing read from it is ever printed.
    """
    enabled = lms.call(["pref", "plugin.audioscrobbler:enable_scrobbling", "?"])
    if enabled.get("_error") or "_p2" not in enabled:
        return None

    accounts = lms.call(["pref", "plugin.audioscrobbler:accounts", "?"])
    if accounts.get("_error") or "_p2" not in accounts:
        return None

    listed = accounts.get("_p2")
    if not isinstance(listed, list):
        return None

    return (enabled.get("_p2") not in ("0", 0), len(listed))


def long_library_track(lms):
    """A library track with a play count and at least 30 seconds, or None.

    Thirty seconds is AudioScrobbler's own floor: anything shorter is refused
    as too_short, which would look like the queue not working.
    """
    r = lms.call(["tracks", 0, 500, "tags:uOd"])
    for track in (r.get("titles_loop") or []):
        if (track.get("url") and "playcount" in track
                and float(track.get("duration") or 0) >= 30):
            return track
    return None


class NowPlaying(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        probe = cls.lms.call(["remoteplayercompanion", "history", "report"])
        if probe.get("_error") and not probe.get("error"):
            raise unittest.SkipTest(
                f"the history command does not answer at {cls.lms.url}: "
                f"{probe['_error']}")

        state = scrobbling(cls.lms)
        if state is None:
            raise unittest.SkipTest(
                "cannot read the AudioScrobbler preferences, so whether an "
                "account is configured is unknown")
        cls.enabled, cls.accounts = state

        cls.track = long_library_track(cls.lms)
        if not cls.track:
            raise unittest.SkipTest(
                "no library track of 30 seconds or more carries a play count")

    def setUp(self):
        # A player of this test's own: several tests report the same track
        # at the same second, and the duplicate store outlives the process.
        tag = zlib.crc32(self.id().encode()) % 100000
        self.playerid = f"rpc-now-{RUN_ID}-{tag}"
        self.now = int(time.time())
        self.duration = int(float(self.track.get("duration") or 0))

    def tearDown(self):
        remove_listening_history(self.lms, self.playerid)

    def report(self, *params):
        r = self.lms.history(self.playerid, *params)
        self.assertIsNone(code_of(r), f"report refused: {r}")
        return r

    def test_a_play_inside_its_duration_is_now_playing(self):
        if not (self.enabled and self.accounts):
            r = self.report(f"id:{self.track['id']}",
                            f"played:{self.now - 5}")
            self.assertEqual(r.get("nowplaying_status"), "unavailable")
            return

        if not SCROBBLE:
            self.skipTest(
                "this would announce a track to the configured Last.fm "
                "account; set LMS_HISTORY_SCROBBLE=1 to run it")

        r = self.report(f"id:{self.track['id']}", f"played:{self.now - 5}")

        self.assertEqual(r.get("nowplaying_status"), "requested")

    def test_a_play_that_has_ended_is_not_now_playing(self):
        # Ten minutes past the track's end, so the two clocks' few minutes
        # of disagreement cannot make it look current.
        r = self.report(f"id:{self.track['id']}",
                        f"played:{self.now - self.duration - 600}")

        self.assertEqual(r.get("nowplaying_status"), "skipped")

    def test_the_order_of_entries_does_not_decide(self):
        # The current play is listed first and the finished one second: the
        # later entry is not the newest play, the play time is.
        params = (f"id:{self.track['id']},{self.track['id']}",
                  f"played:{self.now - 5},{self.now - self.duration - 600}")

        if not (self.enabled and self.accounts):
            r = self.report(*params)
            self.assertEqual(r.get("nowplaying_status"), "unavailable")
            return

        if not SCROBBLE:
            self.skipTest(
                "this would announce a track to the configured Last.fm "
                "account; set LMS_HISTORY_SCROBBLE=1 to run it")

        r = self.report(*params)

        self.assertEqual(r.get("nowplaying_status"), "requested")

    def test_a_finished_play_does_not_hide_a_current_one(self):
        params = (f"id:{self.track['id']},{self.track['id']}",
                  f"played:{self.now - self.duration - 600},{self.now - 5}")

        if not (self.enabled and self.accounts):
            r = self.report(*params)
            self.assertEqual(r.get("nowplaying_status"), "unavailable")
            return

        if not SCROBBLE:
            self.skipTest(
                "this would announce a track to the configured Last.fm "
                "account; set LMS_HISTORY_SCROBBLE=1 to run it")

        r = self.report(*params)

        self.assertEqual(r.get("nowplaying_status"), "requested")

    def test_an_eligible_track_is_queued(self):
        if not (self.enabled and self.accounts):
            self.skipTest("no AudioScrobbler account is configured")
        if not SCROBBLE:
            self.skipTest(
                "this would scrobble a real play to the configured Last.fm "
                "account; set LMS_HISTORY_SCROBBLE=1 to run it")

        r = self.report(f"id:{self.track['id']}",
                        f"played:{self.now - self.duration - 600}")

        self.assertEqual(r.get("accepted"), 1)
        self.assertEqual(r.get("queued"), 1)

    def test_without_an_account_nothing_is_queued(self):
        if self.enabled and self.accounts:
            self.skipTest(
                "scrobbling is configured; the queued test covers this server")

        r = self.report(f"id:{self.track['id']}",
                        f"played:{self.now - self.duration - 600}")

        self.assertEqual(r.get("accepted"), 1)
        self.assertEqual(r.get("queued"), 0)
