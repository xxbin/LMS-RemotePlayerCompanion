#!/usr/bin/env python3
"""Taking from the queue while a refill is writing to it never repeats a track.

A refill calls its provider asynchronously, and takes happen meanwhile.
Writing back the record as it stood before that call would undo the take: the
taken tracks go back into the buffer and the next caller is handed one of
them again, which a caching player would download twice. This drives that
window deliberately, by keeping a slow provider refilling while nextbatch
keeps taking.

The window only means something if the refill actually wrote during it, so
the test also insists that tracks arrived from the provider. Without that, a
run where the provider did nothing would look like a pass.
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase  # noqa: E402

SEED_N = 12
DEEP = 400
WINDOW = 35
ATTEMPTS = 4


class ConcurrentTake(DSTMTestCase):
    queue = "test-race"

    def _take_while_refilling(self):
        """Take one at a time while a refill runs.

        Returns (handed, from_provider, saw_a_refill), or None if no attempt
        got a refill that was both in flight and writing.
        """
        token = self.pick_async()

        for attempt in range(ATTEMPTS):
            seeded = self.seed(SEED_N)
            self.assertGreater(seeded, 0, "could not seed a queue")

            r = self.lms.dstm("queue", self.playerid)
            seeds = {x["url"] for x in r.get("queue_loop") or []}

            self.use_provider(token, DEEP)

            handed, from_provider, saw_a_refill = [], 0, False
            started = time.time()
            while time.time() - started < WINDOW:
                r = self.lms.dstm("nextbatch", self.playerid, "count:1")
                for entry in r.get("batch_loop") or []:
                    handed.append(entry["url"])
                    if entry["url"] not in seeds:
                        from_provider += 1

                if self.lms.state(self.playerid)[1]:
                    saw_a_refill = True
                time.sleep(0.4)

            if saw_a_refill and from_provider:
                return handed, from_provider, saw_a_refill

            print(f"\n  attempt {attempt + 1}: {len(handed)} takes, "
                  f"{from_provider} of them from the provider"
                  + ("" if saw_a_refill else ", no refill was ever in flight"))

        return None

    def test_no_track_is_handed_out_twice_while_a_refill_writes(self):
        outcome = self._take_while_refilling()
        if outcome is None:
            self.skipTest(
                f"could not exercise the window on {ATTEMPTS} attempts. It needs a "
                "refill that is in flight and adding tracks while takes happen; "
                "nothing is concluded either way.")

        handed, from_provider, _saw = outcome
        seen, repeats = set(), []
        for url in handed:
            if url in seen:
                repeats.append(url)
            seen.add(url)

        self.assertEqual(
            repeats, [],
            f"handed out twice while a refill was writing: {repeats[:2]} "
            f"({len(handed)} takes, {from_provider} from the provider)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
