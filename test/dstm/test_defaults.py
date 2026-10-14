#!/usr/bin/env python3
"""The default queue depth, the default batch size, and what 'seed' does.

Both defaults are exercised by leaving the parameter off, rather than by
reading them out of the source. seed is checked for the things that make it
safe to call -- it fills an empty queue, it leaves a queue that already holds
enough alone -- and for the two things a named seed has to do: keep the named
track out of the player's hands, and refuse a track no provider could derive
from.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import (  # noqa: E402
    DSTMTestCase, SEED_TOKEN, first_library_track, wait_for_count, wait_for_fill)


class Defaults(DSTMTestCase):
    queue = "test-defaults"

    def test_config_without_a_max_uses_the_queue_default(self):
        r = self.use_provider(SEED_TOKEN)
        self.assertIsInstance(r.get("max"), int)
        self.assertGreater(r.get("max"), 0)

    def test_status_reports_the_same_default_depth(self):
        configured = self.use_provider(SEED_TOKEN).get("max")
        self.assertEqual(self.lms.status(self.playerid).get("max"), configured)

    def test_nextbatch_without_a_count_uses_the_batch_default(self):
        self.use_provider(SEED_TOKEN, 20)
        wait_for_count(self.lms, self.playerid, 20, 45)

        r = self.lms.dstm("nextbatch", self.playerid)
        self.assertGreater(r.get("count", 0), 0)

    def test_an_explicit_max_overrides_the_default(self):
        r = self.lms.dstm("config", self.playerid, "max:25")
        self.assertEqual(r.get("max"), 25)

    def test_an_explicit_count_overrides_the_default(self):
        self.use_provider(SEED_TOKEN, 20)
        wait_for_count(self.lms, self.playerid, 20, 45)

        r = self.lms.dstm("nextbatch", self.playerid, "count:3")
        self.assertEqual(r.get("count"), 3)


class Seed(DSTMTestCase):
    queue = "test-seed"

    def test_seed_fills_an_empty_queue(self):
        self.use_provider(SEED_TOKEN)
        self.lms.clear(self.playerid)

        r = self.lms.dstm("seed", self.playerid)
        self.assertGreater(r.get("added", 0), 0)
        self.assertEqual(r.get("seeded"), 1)

    def test_seed_leaves_a_queue_that_already_holds_enough_alone(self):
        self.lms.clear(self.playerid)
        first = self.lms.dstm("seed", self.playerid)
        self.assertGreater(first.get("added", 0), 0)

        again = self.lms.dstm("seed", self.playerid)
        self.assertEqual(again.get("added"), 0)
        self.assertFalse(again.get("seeded"), "it reported seeding an already seeded queue")

    def test_seed_fills_to_half_the_queue_depth(self):
        """A seed only has to be enough for a provider to work from. Half
        leaves the other half for the tracks that provider is about to supply,
        rather than filling the queue with seeds before it has said anything.

        The queue is settled first: config starts a fill of its own, and a
        buffer that is already full would take the early return instead.
        """
        self.use_provider(SEED_TOKEN, 40)
        wait_for_fill(self.lms, self.playerid, 30)

        self.lms.dstm("clear", self.playerid)
        r = self.lms.dstm("seed", self.playerid)

        self.assertEqual(r.get("added"), 20, "seed did not fill to half of max:40")

    def test_a_seeded_track_is_never_handed_out(self):
        """seed names what to build around, not what to play.

        The player already has that track -- it is what they are listening to
        -- so handing it back is the thing this prevents. What the provider
        derives from it is what should come out.
        """
        url = first_library_track(self.lms)
        if not url:
            self.skipTest("the library has no track to seed with")

        self.use_provider(SEED_TOKEN, 30)
        self.lms.dstm("clear", self.playerid)

        r = self.lms.dstm("seed", self.playerid, f"url:{url}")

        # First that it took at all: without this the assertion below passes
        # for the wrong reason, because a url the command ignored is a url
        # that never appears in a batch.
        self.assertEqual(r.get("seeded_track"), url, "the seed was not taken")

        wait_for_fill(self.lms, self.playerid, 30)

        handed = set()
        for _ in range(3):
            r = self.lms.dstm("nextbatch", self.playerid, "count:10")
            handed |= {t["url"] for t in (r.get("batch_loop") or [])}

        self.assertNotIn(url, handed, "the seeded track was handed to the player")
        self.assertTrue(handed, "nothing at all was handed out")

    def test_a_seed_that_is_not_in_the_library_is_refused(self):
        """A URL DSTM cannot resolve gives a deriving provider nothing, which
        is the same silent failure as an empty queue -- so it is refused here
        rather than accepted and quietly ignored."""
        self.use_provider(SEED_TOKEN, 30)

        r = self.lms.dstm("seed", self.playerid, "url:file:///nope/not-a-track.mp3")

        self.assertEqual((r.get("error") or {}).get("code"), "SEED_NOT_IN_LIBRARY")

    def test_seed_without_a_provider_is_refused(self):
        """seed no longer refuses an unconfigured queue -- configuring is what
        it does. What it refuses is a player with nothing to adopt."""
        self.lms.set_provider(self.playerid, "0")   # DSTM's own "none"

        r = self.lms.dstm("seed", self.playerid)

        self.assertEqual((r.get("error") or {}).get("code"), "NO_PROVIDER")


if __name__ == "__main__":
    unittest.main(verbosity=2)
