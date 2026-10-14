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
from lmsrpc import (  # noqa: E402
    DSTMTestCase, SEED_TOKEN, wait_for_count, wait_for_fill)


def lastmix_token(lms, playerid):
    """A LastMix token this server has, or None.

    LastMix is what these suites ask for when the property is about a provider
    being *handed* something: it is the one that dies outright on an empty
    queue, where a provider that merely answers with nothing cannot be told
    apart from one that was never asked.
    """
    _filtered, everything = lms.tokens(playerid)

    for token in sorted(everything):
        if token.startswith("PLUGIN_LASTMIX_DSTM"):
            return token

    return None


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

    def test_a_queue_with_a_provider_but_nothing_to_work_from_establishes_itself(self):
        """A queue can have a provider and still have nothing for it to work
        from: `config token:` sets the provider and, deliberately, leaves the
        queue empty. Asking for a batch is then asking a provider that derives
        from the queue to derive from nothing, which for LastMix is fatal. So
        nextbatch gives the queue material the same way it gives it a provider.
        """
        token = lastmix_token(self.lms, self.playerid)
        if not token:
            self.skipTest("no LastMix provider is registered to try this with")

        self.lms.dstm("forget", self.playerid)
        r = self.lms.dstm("config", self.playerid, f"token:{token}", "max:50")
        self.assertIsNone((r.get("error") or {}).get("code"),
                          f"config refused: {r.get('error')}")

        r = self.lms.dstm("nextbatch", self.playerid, "count:5", timeout=90)

        self.assertIsNone((r.get("error") or {}).get("code"),
                          f"refused instead of establishing a queue: {r.get('error')}")
        # `batch_loop` rather than `count`: an empty loop is left out of the
        # answer entirely, and asserting on its presence says "tracks came
        # back" without depending on how the count is typed on the wire.
        self.assertTrue(r.get("batch_loop"),
                        "established a queue but handed out nothing")

    def test_establishing_a_queue_leaves_the_provider_it_already_had(self):
        """config writes a provider both ways, so a queue and its player agree
        -- until somebody changes the player's setting in LMS. A batch request
        is no place to notice that: it gives a queue the material it lacks, and
        leaves the provider it draws from alone. seed is the command that
        deliberately picks up a changed setting."""
        kept = lastmix_token(self.lms, self.playerid)

        if not kept or kept == SEED_TOKEN:
            self.skipTest("no second provider to tell the queue's own from")

        self.lms.dstm("forget", self.playerid)

        # The queue is given one provider...
        self.lms.dstm("config", self.playerid, f"token:{kept}", "max:50")

        # ...and the player's own setting is then made to say something else.
        if not self.lms.set_provider(self.playerid, SEED_TOKEN):
            self.skipTest(f"cannot set the DSTM provider for {self.playerid}")

        r = self.lms.dstm("nextbatch", self.playerid, "count:5", timeout=90)

        self.assertEqual(r.get("source"), kept,
                         "a batch request re-pointed the queue at the player's setting")


class SeedOutlivesTheBuffer(DSTMTestCase):
    """A queue that has served anything always has something to derive from.

    A provider that derives its selection from the queue -- LastMix above all
    -- must not be handed an empty one. `getMixableProperties` answers undef
    for an empty playlist, and LastMix passes that to `Storable::dclone`
    without checking and dies. So the seed follows the queue: every batch that
    hands tracks over leaves the last of them as what the queue is about, and
    a batch that hands over nothing leaves it as it was.
    """

    queue = "test-anchor"

    def test_a_drained_queue_still_has_something_to_derive_from(self):
        token = lastmix_token(self.lms, self.playerid)
        if not token:
            self.skipTest("no LastMix provider is registered to try this with")

        if not self.lms.set_provider(self.playerid, token):
            self.skipTest(f"cannot set the DSTM provider for {self.playerid}")

        self.lms.dstm("forget", self.playerid)
        self.lms.dstm("seed", self.playerid)

        # Settled first, so that the drain below is what starts the next fill
        # rather than a fill already in flight, which would carry the playlist
        # it was given before the drain.
        wait_for_fill(self.lms, self.playerid, 45)
        self.assertGreater(self.lms.state(self.playerid)[0], 0, "nothing to drain")

        # More than a queue can hold, so this takes all of it whatever is
        # there. A batch that emptied the buffer and left nothing behind would
        # meet the next fill with nothing at all to derive from.
        self.lms.dstm("nextbatch", self.playerid, "count:50")
        wait_for_fill(self.lms, self.playerid, 45)

        self.assertNotEqual(
            self.lms.state(self.playerid)[2], "HANDLER_DIED",
            "the provider was handed a queue with nothing in it")


if __name__ == "__main__":
    unittest.main(verbosity=2)
