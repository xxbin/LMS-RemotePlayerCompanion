#!/usr/bin/env python3
"""Establishing a queue from nothing, and re-establishing one.

Three behaviours that only make sense together:

'forget' drops a queue's record, which is the only way to get back to the
state a caller who has never used the plugin is in -- and the state these
tests need to set up. Nothing else removes a record: 'clear' empties the
buffer and keeps the record, and the record outlives a server restart.

'seed' rebuilds a queue rather than topping it up, so a queue that already
holds enough is started over rather than left alone.

'nextbatch' establishes a queue itself when there is none to serve from, so a
caller whose player is already set to a provider in LMS can ask for a batch
as its first call. What it cannot do is invent a provider: a player set to
none is refused with NO_PROVIDER, which names the setting to go and make.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase, SEED_TOKEN, wait_for_count  # noqa: E402


class Forget(DSTMTestCase):
    queue = "test-forget"

    def test_forget_drops_the_queue_record(self):
        self.use_provider(SEED_TOKEN, 20)
        self.assertEqual(self.lms.status(self.playerid).get("configured"), 1,
                         "nothing to forget: config and seed did not leave a queue")

        r = self.lms.dstm("forget", self.playerid)

        self.assertEqual(r.get("forgotten"), 1)
        self.assertEqual(self.lms.status(self.playerid).get("configured"), 0)

    def test_forgetting_a_queue_that_was_never_configured_is_not_an_error(self):
        """Idempotent, like 'clear': asking twice is a caller being safe, not
        a mistake."""
        self.lms.dstm("forget", self.playerid)

        r = self.lms.dstm("forget", self.playerid)

        self.assertIsNone((r.get("error") or {}).get("code"))
        self.assertEqual(r.get("forgotten"), 0)

    def test_a_forgotten_queue_is_gone_rather_than_emptied(self):
        """The difference from 'clear', which is the whole reason it exists:
        clear leaves a configured queue behind, forget does not."""
        self.use_provider(SEED_TOKEN, 20)
        self.lms.clear(self.playerid)

        self.assertEqual(self.lms.status(self.playerid).get("configured"), 1)
        self.lms.dstm("forget", self.playerid)
        self.assertEqual(self.lms.status(self.playerid).get("configured"), 0)


class SeedRebuildsTheQueue(DSTMTestCase):
    queue = "test-reseed"

    def test_seed_rebuilds_a_queue_that_already_holds_enough(self):
        """seed used to top a queue up and return early once it held enough,
        which left a queue drawing from derivation material it had already
        moved on from. It now starts over."""
        self.use_provider(SEED_TOKEN, 40)
        wait_for_count(self.lms, self.playerid, 20, 45)

        r = self.lms.dstm("seed", self.playerid)

        self.assertEqual(r.get("added"), 20,
                         "seed did not rebuild a queue that was already full")


class NextbatchEstablishesTheQueue(DSTMTestCase):
    queue = "test-bootstrap"

    def _set_provider(self, token):
        if not self.lms.set_provider(self.playerid, token):
            self.skipTest(f"cannot set the DSTM provider for {self.playerid}")

    def test_nextbatch_establishes_a_queue_nobody_seeded(self):
        """A caller whose player is already set to a provider in LMS can ask
        for a batch without configuring or seeding anything first."""
        self.lms.dstm("forget", self.playerid)
        self._set_provider(SEED_TOKEN)

        r = self.lms.dstm("nextbatch", self.playerid, "count:5")

        self.assertIsNone((r.get("error") or {}).get("code"),
                          f"nextbatch refused instead of bootstrapping: {r.get('error')}")
        self.assertGreater(r.get("count", 0), 0, "bootstrapped but handed out nothing")

    def test_a_bootstrapped_queue_is_a_configured_one_afterwards(self):
        """It does not re-bootstrap on every call: the second call finds the
        queue the first one established."""
        self.lms.dstm("forget", self.playerid)
        self._set_provider(SEED_TOKEN)

        self.lms.dstm("nextbatch", self.playerid, "count:5")

        status = self.lms.status(self.playerid)
        self.assertEqual(status.get("configured"), 1)
        self.assertEqual(status.get("provider"), SEED_TOKEN)

    def test_nextbatch_on_a_player_with_no_provider_says_which_setting_to_make(self):
        """What bootstrapping cannot do is invent a provider. NOT_CONFIGURED
        would say the caller forgot a step; NO_PROVIDER says the player's own
        Dont Stop The Music setting is the thing to go and set."""
        self.lms.dstm("forget", self.playerid)
        self._set_provider("0")          # DSTM's own "none"

        r = self.lms.dstm("nextbatch", self.playerid, "count:5")

        self.assertEqual((r.get("error") or {}).get("code"), "NO_PROVIDER")

    def test_a_refused_bootstrap_leaves_no_queue_behind(self):
        """Refusing must not be a way to half-configure a queue: the caller
        gets NO_PROVIDER and the next attempt starts from the same place."""
        self.lms.dstm("forget", self.playerid)
        self._set_provider("0")

        self.lms.dstm("nextbatch", self.playerid, "count:5")

        self.assertEqual(self.lms.status(self.playerid).get("configured"), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
