#!/usr/bin/env python3
"""The 'remoteplayercompanion dstm' commands: ordinary paths and error paths."""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase, SEED_TOKEN, wait_for_count  # noqa: E402


def code_of(result):
    return (result.get("error") or {}).get("code")


class Refusals(DSTMTestCase):
    """What the commands do with arguments they cannot honour."""

    queue = "test-basic-refusals"

    def test_missing_playerid_is_refused(self):
        self.assertEqual(code_of(self.lms.dstm("status", "")), "MISSING_PARAMETER")

    def test_unknown_playerid_reads_as_unconfigured(self):
        r = self.lms.status("no-such-player")
        self.assertEqual(r.get("configured"), 0)

    def test_nextbatch_on_an_unconfigured_queue_is_refused(self):
        r = self.lms.dstm("nextbatch", "no-such-player")
        self.assertEqual(code_of(r), "NOT_CONFIGURED")

    def test_unknown_provider_token_is_refused(self):
        r = self.lms.dstm("config", "probe", "token:NO_SUCH_TOKEN_XYZ")
        self.assertEqual(code_of(r), "UNKNOWN_PROVIDER")

    def test_out_of_range_max_is_refused(self):
        r = self.lms.dstm("config", "probe", f"token:{SEED_TOKEN}", "max:0")
        self.assertEqual(code_of(r), "BAD_MAX")


class Queue(DSTMTestCase):
    """Filling, taking and emptying one queue."""

    queue = "test-basic-queue"

    def test_config_answers_without_waiting_for_the_fill(self):
        started = time.time()
        r = self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        self.assertLess(time.time() - started, 5, "config blocked on the provider")
        self.assertEqual(r.get("max"), 12)

    def test_the_buffer_fills_to_the_configured_depth(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        buffered = wait_for_count(self.lms, self.playerid, 12, 45)
        self.assertGreaterEqual(buffered, 12, "the buffer never reached its depth")

    def test_nextbatch_hands_out_what_was_asked_for(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.dstm("nextbatch", self.playerid, "count:6")
        batch = r.get("batch_loop") or []
        self.assertEqual(len(batch), 6)
        self.assertEqual(r.get("complete"), 1)
        self.assertTrue(all(x.get("url") for x in batch), "an entry had no url")
        self.assertEqual(r.get("filling"), 1, "no refill was started for the tail")

    def test_successive_nextbatch_calls_do_not_repeat_a_track(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:20")
        wait_for_count(self.lms, self.playerid, 20, 45)

        seen = set()
        repeats = []
        for _ in range(4):
            r = self.lms.dstm("nextbatch", self.playerid, "count:5")
            for entry in r.get("batch_loop") or []:
                if entry["url"] in seen:
                    repeats.append(entry["url"])
                seen.add(entry["url"])
        self.assertEqual(repeats, [], f"handed out twice: {repeats[:2]}")

    def test_queue_reports_as_many_tracks_as_it_lists(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.dstm("queue", self.playerid)
        self.assertEqual(r.get("total"), len(r.get("queue_loop") or []))

    def test_the_buffer_stays_within_max(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        wait_for_count(self.lms, self.playerid, 12, 45)
        for _ in range(3):
            self.lms.dstm("nextbatch", self.playerid, "count:5")
        buffered, _filling, _err = self.lms.state(self.playerid)
        self.assertLessEqual(buffered, self.lms.status(self.playerid).get("max"))

    def test_clear_reports_what_it_dropped_and_empties_the_queue(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:12")
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.clear(self.playerid)
        self.assertGreater(r.get("removed", 0), 0)
        self.assertEqual(self.lms.state(self.playerid)[0], 0)


class Invisibility(DSTMTestCase):
    """A remote player is deliberately not an LMS client."""

    queue = "test-basic-invisible"

    def test_no_remote_player_appears_in_the_player_list(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:5")
        wait_for_count(self.lms, self.playerid, 5, 30)

        r = self.lms.call(["players", 0, 999])
        ids = [p.get("playerid") for p in r.get("players_loop") or []]
        self.assertNotIn(self.playerid, ids,
                         f"the queue leaked into LMS's {len(ids)} players")


if __name__ == "__main__":
    unittest.main(verbosity=2)
