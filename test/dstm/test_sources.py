#!/usr/bin/env python3
"""What 'sources' lists, and whether what it lists actually works.

Being listed and being usable are different things, and the difference is
easy to measure wrongly. Each provider is offered a queue that already holds
a seed, because several of them select from what the queue holds -- so a
non-zero buffer proves nothing. What counts is the provider adding tracks
*beyond* the seed, and that has to be waited for: config answers before the
provider does, so reading the buffer straight after a config measures nothing.

The sweep is done once, in setUpClass, and the test methods assert over what
it recorded. Offering every provider a queue is the most expensive thing in
the suite, and three of these tests used to run it separately.

A provider that adds nothing is recorded rather than failed: Last.fm-backed
ones answer with an empty list when it knows nothing similar, rating-based
ones when the library holds nothing matching. An error or a throw would be a
fault.
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase, SEED_TOKEN, seed_queue, wait_for_fill  # noqa: E402

SEED_N = 10
TARGET = 30
WAIT = 24


class Sources(DSTMTestCase):
    queue = "test-sources"

    #: {token: {'added': n, 'error': code or None}}, filled in once
    sweep = {}
    filtered = set()
    everything = set()

    @classmethod
    def _configure(cls, token):
        """Configure the queue with a provider. Returns an error string, or None.

        The response is what decides this. Reading the provider back
        afterwards cannot tell a refusal from a request that never arrived,
        and a flaky network would then be reported as a provider that cannot
        be configured -- an environment problem dressed up as a defect.
        """
        r = cls.lms.dstm("config", cls.playerid, f"token:{token}", f"max:{TARGET}")

        if r.get("_error"):
            return f"transport: {r['_error']}"

        code = (r.get("error") or {}).get("code")
        if code:
            return code

        if r.get("provider") != token:
            return f"accepted, but reads back as {r.get('provider')!r}"

        return None

    @classmethod
    def _sweep_one(cls, token):
        """Offer one provider a seeded queue. Returns {'added': n, 'error': ...}."""
        refused = cls._configure(token)
        if refused:
            return {"added": 0, "error": refused}

        # seed_queue, not cls.seed: the latter is an instance method, and
        # calling it on the class passes the class where self belongs.
        seeded = seed_queue(cls.lms, cls.playerid, SEED_TOKEN, SEED_N)
        if seeded == 0:
            return {"added": 0, "error": "could not seed a queue"}

        # Seeding pointed the queue at the seeding token, so point it back at
        # the provider under test before waiting on it.
        refused = cls._configure(token)
        if refused:
            return {"added": 0, "error": refused}

        buffered, err = wait_for_fill(cls.lms, cls.playerid, WAIT)

        return {"added": buffered - seeded, "error": err}

    @classmethod
    def setUpClass(cls):
        super().setUpClass()

        cls.filtered, cls.everything = cls.lms.tokens(cls.playerid)
        cls.sweep = {}

        # Progress as it goes: this is the longest part of a run, and silence
        # through it is indistinguishable from a hang.
        print(f"\nsources: offering {len(cls.filtered)} providers a seeded queue")

        for token in sorted(cls.filtered):
            started = time.time()
            cls.sweep[token] = outcome = cls._sweep_one(token)
            took = time.time() - started

            result = outcome["error"] or (f"+{outcome['added']}"
                                          if outcome["added"] > 0 else "nothing")
            print(f"  {token:<48} {result:<10} {took:>5.1f}s", flush=True)

        cls.lms.clear(cls.playerid)

    # --- what sources reports, which costs nothing ---

    def test_the_filtered_view_is_a_subset_of_the_unfiltered_one(self):
        self.assertTrue(self.filtered, "sources offered nothing")
        self.assertTrue(self.everything, "all:1 offered nothing")
        self.assertLessEqual(self.filtered, self.everything)

    def test_sources_reports_how_many_it_left_out(self):
        r = self.lms.dstm("sources", self.playerid)
        self.assertIsInstance(r.get("hidden"), int)

    def test_the_hidden_count_accounts_for_the_difference(self):
        r = self.lms.dstm("sources", self.playerid)
        self.assertEqual(len(self.filtered) + r.get("hidden", 0), len(self.everything),
                         "the filtered view plus the hidden count is not the whole registry")

    # --- what the sweep found ---

    def test_every_offered_provider_could_be_configured(self):
        refused = {t: v["error"] for t, v in self.sweep.items() if v["error"]}
        self.assertEqual(refused, {}, f"offered but refused: {refused}")

    def test_no_provider_errored(self):
        errored = {t: v["error"] for t, v in self.sweep.items() if v["error"]}
        self.assertEqual(errored, {}, f"providers that errored: {errored}")

    def test_at_least_one_provider_adds_tracks(self):
        """A server where nothing can fill a queue is not one to test on."""
        added = [t for t, v in self.sweep.items() if v["added"] > 0]
        self.assertTrue(added, f"not one of {len(self.sweep)} providers added anything")

    def test_the_providers_that_added_nothing_are_named(self):
        """Not a failure: recorded, so that a change in them is visible."""
        quiet = sorted(t for t, v in self.sweep.items() if not v["error"] and v["added"] <= 0)
        print(f"\n  offered but added nothing: {', '.join(quiet) or 'none'}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
