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
        """The token now comes from the player's own DSTM setting, so that is
        where an unknown one has to be put for seed to refuse it."""
        self.lms.set_provider(self.playerid, "NO_SUCH_TOKEN_XYZ")

        r = self.lms.dstm("seed", self.playerid)

        self.assertEqual(code_of(r), "UNKNOWN_PROVIDER")

    def test_a_provider_that_is_not_offered_is_refused(self):
        """DSTM's registry holds one entry per favourite as well as the real
        providers, and a queue pointed at one of those is pointed at a single
        favourite rather than at a mix."""
        favourite = next((t for t in self.lms.tokens(self.playerid)[1]
                          if not t.startswith("PLUGIN_") and t != "BLISSMIXER_DSTM"),
                         None)
        if not favourite:
            self.skipTest("this server has no non-offered provider to try")

        self.lms.set_provider(self.playerid, favourite)

        r = self.lms.dstm("seed", self.playerid)

        self.assertEqual(code_of(r), "PROVIDER_NOT_OFFERED")

    def test_out_of_range_max_is_refused(self):
        r = self.lms.dstm("config", self.playerid, "max:0")
        self.assertEqual(code_of(r), "BAD_MAX")

    def test_config_sets_the_players_own_provider_too(self):
        """Both are sources, so naming one here has to reach both.

        Otherwise a queue configured through the plugin would draw from one
        provider while the player it is named for drew from another.
        """
        before = self.lms.get_provider(self.playerid)

        r = self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}")

        self.assertIsNone(code_of(r), f"config refused: {r}")
        self.assertEqual(self.lms.get_provider(self.playerid), SEED_TOKEN,
                         "the player's own DSTM setting was not written")
        self.assertEqual(r.get("provider"), SEED_TOKEN,
                         "the queue's record was not written")

    def test_a_refused_provider_writes_neither_side(self):
        """Checked before either is written, so a refusal leaves the queue and
        the player exactly as they were."""
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}")
        before = self.lms.get_provider(self.playerid)
        self.assertEqual(before, SEED_TOKEN, "could not set up the precondition")

        r = self.lms.dstm("config", self.playerid, "token:NO_SUCH_TOKEN_XYZ")

        self.assertEqual(code_of(r), "UNKNOWN_PROVIDER")
        self.assertEqual(self.lms.get_provider(self.playerid), before,
                         "a refused token was written to the player anyway")
        self.assertEqual(self.lms.status(self.playerid).get("provider"), before,
                         "a refused token was written to the queue anyway")


class Queue(DSTMTestCase):
    """Filling, taking and emptying one queue."""

    queue = "test-basic-queue"

    def test_config_answers_without_waiting_for_the_fill(self):
        started = time.time()
        r = self.use_provider(SEED_TOKEN, 12)
        self.assertLess(time.time() - started, 5, "config blocked on the provider")
        self.assertEqual(r.get("max"), 12)

    def test_the_buffer_fills_to_the_configured_depth(self):
        self.use_provider(SEED_TOKEN, 12)
        buffered = wait_for_count(self.lms, self.playerid, 12, 45)
        self.assertGreaterEqual(buffered, 12, "the buffer never reached its depth")

    def test_nextbatch_hands_out_what_was_asked_for(self):
        self.use_provider(SEED_TOKEN, 12)
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.dstm("nextbatch", self.playerid, "count:6")
        batch = r.get("batch_loop") or []
        self.assertEqual(len(batch), 6)
        self.assertEqual(r.get("complete"), 1)
        self.assertTrue(all(x.get("url") for x in batch), "an entry had no url")
        self.assertEqual(r.get("filling"), 1, "no refill was started for the tail")

    def test_successive_nextbatch_calls_do_not_repeat_a_track(self):
        self.use_provider(SEED_TOKEN, 20)
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
        self.use_provider(SEED_TOKEN, 12)
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.dstm("queue", self.playerid)
        self.assertEqual(r.get("total"), len(r.get("queue_loop") or []))

    def test_the_buffer_stays_within_max(self):
        self.use_provider(SEED_TOKEN, 12)
        wait_for_count(self.lms, self.playerid, 12, 45)
        for _ in range(3):
            self.lms.dstm("nextbatch", self.playerid, "count:5")
        buffered, _filling, _err = self.lms.state(self.playerid)
        self.assertLessEqual(buffered, self.lms.status(self.playerid).get("max"))

    def test_clear_reports_what_it_dropped_and_empties_the_queue(self):
        self.use_provider(SEED_TOKEN, 12)
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.clear(self.playerid)
        self.assertGreater(r.get("removed", 0), 0)
        self.assertEqual(self.lms.state(self.playerid)[0], 0)


class TrackFields(DSTMTestCase):
    """What a batch says about each track, and how to ask for more."""

    queue = "test-basic-fields"

    def a_batch(self, *params):
        self.use_provider(SEED_TOKEN, 12)
        wait_for_count(self.lms, self.playerid, 12, 45)

        r = self.lms.dstm("nextbatch", self.playerid, "count:5", *params)
        batch = r.get("batch_loop") or []
        self.assertTrue(batch, "nothing to inspect")
        return batch

    def test_a_batch_carries_a_cover_id(self):
        """The id, not a URL. An artwork URL would point at the LMS, which the
        player cannot reach once it is offline -- so the plugin hands over the
        id and leaves fetching the image to the player, which can do it while
        it still has a connection."""
        batch = self.a_batch()

        self.assertTrue(any("coverid" in t for t in batch),
                        "no track carried a coverid")
        for t in batch:
            self.assertNotIn("artwork_url", t, "an artwork URL was invented")

    def test_a_batch_keeps_the_fields_it_always_had(self):
        batch = self.a_batch()

        for t in batch:
            for field in ("url", "id", "title"):
                self.assertIn(field, t, f"{field} went missing from a track")

    def test_tags_ask_for_more(self):
        """The letters are LMS's own, so a caller who knows them gets what
        songinfo would have given for the same letter."""
        batch = self.a_batch("tags:g")

        self.assertTrue(any(t.get("genre") for t in batch),
                        "tags:g returned no genre on any track")

    def test_a_tag_the_caller_did_not_ask_for_is_not_returned(self):
        batch = self.a_batch("tags:g")

        self.assertFalse(any("year" in t for t in batch),
                         "a field arrived that was not asked for")


class Invisibility(DSTMTestCase):
    """A queue is deliberately not an LMS client of its own.

    It used to be asserted that the queue's id was absent from the player
    list, which held while queue ids were invented names. A queue now takes
    its provider from the player it is named for, so its id IS a player's --
    and the claim is the one that was always the point: configuring a queue
    adds no client to LMS.
    """

    queue = "test-basic-invisible"

    def test_configuring_a_queue_adds_no_player(self):
        before = {p.get("playerid") for p in
                  (self.lms.call(["players", 0, 999]).get("players_loop") or [])}

        self.use_provider(SEED_TOKEN, 5)
        wait_for_count(self.lms, self.playerid, 5, 30)

        after = {p.get("playerid") for p in
                 (self.lms.call(["players", 0, 999]).get("players_loop") or [])}

        self.assertEqual(before, after,
                         f"configuring a queue changed LMS's player list: "
                         f"{after - before} appeared")
        self.assertIn(self.playerid, after,
                      "the queue's player is not one LMS knows, so its "
                      "provider could not have been adopted")


if __name__ == "__main__":
    unittest.main(verbosity=2)
