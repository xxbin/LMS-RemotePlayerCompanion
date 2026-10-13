#!/usr/bin/env python3
"""The default queue depth, the default batch size, and what 'seed' does.

Both defaults are exercised by leaving the parameter off, rather than by
reading them out of the source. seed is checked for the two things that make
it safe to call: it fills an empty queue, and it leaves a queue that already
holds enough alone.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase, SEED_TOKEN, wait_for_count  # noqa: E402


class Defaults(DSTMTestCase):
    queue = "test-defaults"

    def test_config_without_a_max_uses_the_queue_default(self):
        r = self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}")
        self.assertIsInstance(r.get("max"), int)
        self.assertGreater(r.get("max"), 0)

    def test_status_reports_the_same_default_depth(self):
        configured = self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}").get("max")
        self.assertEqual(self.lms.status(self.playerid).get("max"), configured)

    def test_nextbatch_without_a_count_uses_the_batch_default(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:20")
        wait_for_count(self.lms, self.playerid, 20, 45)

        r = self.lms.dstm("nextbatch", self.playerid)
        self.assertGreater(r.get("count", 0), 0)

    def test_an_explicit_max_overrides_the_default(self):
        r = self.lms.dstm("config", self.playerid, "max:25")
        self.assertEqual(r.get("max"), 25)

    def test_an_explicit_count_overrides_the_default(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}", "max:20")
        wait_for_count(self.lms, self.playerid, 20, 45)

        r = self.lms.dstm("nextbatch", self.playerid, "count:3")
        self.assertEqual(r.get("count"), 3)


class Seed(DSTMTestCase):
    queue = "test-seed"

    def test_seed_fills_an_empty_queue(self):
        self.lms.dstm("config", self.playerid, f"token:{SEED_TOKEN}")
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

    def test_seed_honours_an_explicit_count(self):
        self.lms.clear(self.playerid)
        r = self.lms.dstm("seed", self.playerid, "count:4")
        self.assertEqual(r.get("added"), 4)
        self.assertEqual(r.get("total"), 4)

    def test_seed_on_an_unconfigured_queue_is_refused(self):
        r = self.lms.dstm("seed", "never-configured")
        self.assertEqual((r.get("error") or {}).get("code"), "NOT_CONFIGURED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
