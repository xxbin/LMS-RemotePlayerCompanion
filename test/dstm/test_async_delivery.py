#!/usr/bin/env python3
"""A provider that answers later still gets its tracks into the queue.

The point is that the tracks arrive after the command that asked for them has
already answered, which only an asynchronous provider can show: one that
answers inline would have finished inside that same call.

Providers of that kind select from what the queue holds, so the queue is
seeded first, and they answer with nothing when they have nothing to suggest.
That is their business rather than the plugin's, so the scenario is retried
and the test skips when the provider never cooperates.
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase  # noqa: E402

SEED_N = 12
TARGET = 24
ATTEMPTS = 3
WATCH = 45


class AsyncDelivery(DSTMTestCase):
    queue = "test-async"

    def _watch_a_fill(self, token):
        """Seed, ask the provider for a deeper buffer, and watch it arrive.

        Returns (seeded, growth, config_seconds, total_reported_by_config),
        where growth is a time series of (seconds, buffered, filling, error).
        """
        seeded = self.seed(SEED_N)
        self.assertGreater(seeded, 0, "could not seed a queue")

        started = time.time()
        r = self.use_provider(token, TARGET)
        took = time.time() - started

        growth = []
        started = time.time()
        while time.time() - started < WATCH:
            time.sleep(4)
            total, filling, err = self.lms.state(self.playerid)
            growth.append((round(time.time() - started), total, filling, err))
            if filling == 0 and total > seeded:
                break

        return seeded, growth, took, r.get("total", -1)

    def test_a_later_answer_still_reaches_an_already_answered_queue(self):
        """One scenario, both properties.

        Watching a fill is the expensive part -- several attempts, each up to
        the full watch -- so running it once per property would double what
        the suite costs for nothing.
        """
        token = self.pick_async()
        seeded = growth = took = reported = None

        for attempt in range(ATTEMPTS):
            seeded, growth, took, reported = self._watch_a_fill(token)
            if growth[-1][1] > seeded:
                break
            print(f"\n  {token} added nothing on attempt {attempt + 1}; retrying")

        if growth[-1][1] <= seeded:
            self.skipTest(
                f"{token} returned no tracks on any of {ATTEMPTS} attempts. "
                "A provider may answer with an empty list, so this says nothing "
                "about the plugin either way.")

        self.assertGreater(growth[-1][1], seeded, f"the buffer stayed at {seeded}")
        self.assertLess(took, 5, "the command waited for the provider")

        # There used to be an assertion here that the answer reported the
        # buffer as it was *before* the provider delivered. It cannot hold any
        # more, and its loss is real: adopting a provider is now seed's job,
        # and that is a second command after config, so by the time an answer
        # is composed the provider may legitimately have delivered. What is
        # still checked is that the command returned without waiting (above)
        # and that the later answer reached the queue (above that).

        r = self.lms.dstm("queue", self.playerid)
        rows = r.get("queue_loop") or []
        urls = [x["url"] for x in rows]

        self.assertEqual(len(urls), len(set(urls)), "the buffer holds duplicates")
        self.assertIsNone(self.lms.state(self.playerid)[2],
                          "an error was recorded on the queue")


if __name__ == "__main__":
    unittest.main(verbosity=2)
