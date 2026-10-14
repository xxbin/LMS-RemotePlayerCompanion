#!/usr/bin/env python3
"""A fill that cannot finish is cut off by its budget, and a provider result
arriving after that is discarded.

A fill only reaches its budget when nothing else ends it, so this needs a
provider that is slow and still productive at 30 seconds. Asking for a buffer
far deeper than it could reach in that time gets there. Such providers answer
with nothing now and then, so the scenario is retried and the test skips
rather than failing on an uncooperative one.
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lmsrpc import DSTMTestCase  # noqa: E402

SEED_N = 12
DEEP = 400          # far more than any provider could deliver within the budget
ATTEMPTS = 3
WATCH = 42          # the budget is 30s; this leaves samples after it


class FillTimeout(DSTMTestCase):
    queue = "test-timeout"

    def _fill_past_the_budget(self):
        """Run a fill that cannot finish, and return its time series.

        Returns None if no attempt reached the budget, which is a fact about
        the provider rather than about the plugin.
        """
        token = self.pick_async()

        for attempt in range(ATTEMPTS):
            seeded = self.seed(SEED_N)
            self.assertGreater(seeded, 0, "could not seed a queue")

            started = time.time()
            self.use_provider(token, DEEP)

            series = []
            ended_at = None
            while time.time() - started < WATCH:
                time.sleep(2)
                total, filling, err = self.lms.state(self.playerid)
                series.append((round(time.time() - started), total, filling, err))

                if filling:
                    continue

                # The fill has stopped, so this attempt is decided: either the
                # budget cut it off, or it finished on its own first. Watching
                # longer cannot change which, and an attempt that ended early
                # would otherwise sit here until the watch ran out.
                if series[-1][0] >= 30:
                    ended_at = series[-1][0]
                break

            # Keep watching after the fill has ended. What is being checked
            # is whether a result still in flight writes afterwards, so the
            # samples that matter are the ones taken now -- stopping at the
            # moment the fill ends would leave nothing to look at.
            if ended_at:
                for _ in range(5):
                    time.sleep(3)
                    total, filling, err = self.lms.state(self.playerid)
                    series.append((round(time.time() - started), total, filling, err))

            if series[-1][3] == "SOURCE_TIMEOUT":
                return series

            # Whether another seed is worth trying depends on why this one
            # ended. A fill that ran dry might be more productive with
            # different seeds, so it is. A fill that was still collecting
            # tracks when it stopped hit the plugin's own call allowance
            # instead -- and another seed would hit exactly the same
            # allowance, at the same cost, for the same answer.
            still_productive = len(series) >= 2 and series[-1][1] > series[-2][1]

            print(f"\n  attempt {attempt + 1}: ended on its own "
                  f"(total={series[-1][1]}, last_error={series[-1][3]})"
                  + (" while still collecting tracks, so another seed would "
                     "only meet the same call allowance" if still_productive else ""))

            if still_productive:
                break

        return None

    @unittest.skip(
        "needs a provider that never calls back, and none is installed. The budget was "
        "verified against one when a broken plugin supplied it; remove this decorator "
        "when another does, or when a provider is installed deliberately to hang.")
    def test_a_stuck_fill_ends_on_its_budget_and_its_late_result_is_dropped(self):
        """One scenario, both properties.

        Running the fill twice would double the most expensive thing in the
        suite -- several attempts, each of which may take the full budget.
        """
        series = self._fill_past_the_budget()
        if series is None:
            self.skipTest(
                f"no fill ran past its budget on {ATTEMPTS} attempts. This needs a "
                "provider that is both slow and still productive at 30 seconds.")

        still_filling = [s for s in series if s[2] == 1]
        self.assertTrue(still_filling, "the fill never reported itself running")
        self.assertGreaterEqual(max(s[0] for s in still_filling), 28,
                                "the fill stopped well before the budget")

        last = series[-1]
        self.assertGreaterEqual(last[0], 30, "the fill ended before its budget")
        self.assertEqual(last[3], "SOURCE_TIMEOUT",
                         "the budget expiring was not recorded as the reason")

        settled = last[1]
        later = [s for s in series if s[0] > last[0]]
        self.assertTrue(later, "nothing was observed after the fill ended")
        for at, total, _filling, _err in later:
            self.assertEqual(total, settled,
                             f"the buffer moved from {settled} to {total} at t+{at}s, "
                             "so a late result was acted on")


if __name__ == "__main__":
    unittest.main(verbosity=2)
