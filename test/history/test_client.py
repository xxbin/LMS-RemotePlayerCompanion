#!/usr/bin/env python3
"""The identity of the synthetic client a report creates.

AudioScrobbler stores a client's *id*, not the object, and keeps that
client's account choice and pending scrobbles in `_client:<id>` preferences.
So the id has to be one the server can look up later.

It is the remote player's own id -- the same value APC records as `client_id`
and the duplicate store keys on. One remote player is one id in every
destination, so the `_client:<id>` preferences describe the same player that
APC's history does.

The id itself is not part of the API, so there is nothing here to read it
from. What can be checked is the consequence: after a report, a client with
the player id answers a `playerpref` request. A client under any other id does
not, and the JSON-RPC socket closes with no body.
"""

import os
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from lmsrpc import LMS, RUN_ID, library_track_with_stats  # noqa: E402


def pref_value(result):
    """The value a pref query answered, or None if it did not answer."""
    if result.get("_error"):
        return None

    values = [v for k, v in result.items() if k.startswith("_p") and k != "_p0"]
    return values[0] if values else None


class ClientId(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lms = LMS()

        probe = cls.lms.call(["remoteplayercompanion", "history", "report"])
        if probe.get("_error") and not probe.get("error"):
            raise unittest.SkipTest(
                f"the history command does not answer at {cls.lms.url}: "
                f"{probe['_error']}")

        # The client exists only when the plugin can talk to AudioScrobbler;
        # without it there is no client to ask about.
        enabled = cls.lms.call(["pref", "plugin.audioscrobbler:enable_scrobbling", "?"])
        if enabled.get("_error") or "_p2" not in enabled:
            raise unittest.SkipTest(
                "AudioScrobbler is not installed, so no client is created")

        cls.track = library_track_with_stats(cls.lms)
        if not cls.track:
            raise unittest.SkipTest(
                "no library track carries a tracks_persistent row")

    def setUp(self):
        self.playerid = f"rpc-client-{RUN_ID}"

    def test_the_client_answers_under_the_player_id(self):
        # A day old: well inside the window, and far from now-playing.
        r = self.lms.history(
            self.playerid,
            f"id:{self.track['id']}",
            f"played:{int(time.time()) - 86400}")
        self.assertIsNone((r.get("error") or {}).get("code"),
                          f"report refused: {r}")

        # Writing an uncommon preference and reading it back is how the
        # client's identity is observed: either it is there under this id, or
        # the request is refused at dispatch and the socket closes.
        written = self.lms.call(
            ["playerpref", "plugin.audioscrobbler:ignoreTitles",
             "value:rpc-client-probe"], client=self.playerid)
        self.assertNotIn("_error", written,
                         f"no client answers at {self.playerid}: {written}")

        read = self.lms.call(
            ["playerpref", "plugin.audioscrobbler:ignoreTitles", "?"],
            client=self.playerid)
        self.assertEqual(pref_value(read), "rpc-client-probe")


if __name__ == "__main__":
    unittest.main()