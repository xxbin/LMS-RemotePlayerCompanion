#!/usr/bin/env python3
"""Run the suites against a server, and print something readable.

    LMS_HOST=lms.local python3 test/run.py            # everything
    LMS_HOST=lms.local python3 test/run.py defaults   # just the matching ones

Equivalent to `python3 -m unittest discover -s test -p "test_*.py"`, with a
reporter that groups the tests by class and gives each one its duration. The
plain unittest entry point still works, as does pytest:

    python3 -m unittest discover -s test -p "test_*.py"      # standard output
    python3 -m pytest test                                   # if pytest is around
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))

from report import ReadableRunner  # noqa: E402


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def main(argv):
    only = argv[0] if argv else None

    found = unittest.TestLoader().discover(HERE, pattern="test_*.py")
    tests = [t for t in flatten(found) if not only or only in t.id()]

    if not tests:
        print(f"no tests found under {HERE}" + (f" matching {only!r}" if only else ""))
        return 1

    result = ReadableRunner(stream=sys.stdout).run(unittest.TestSuite(tests))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
