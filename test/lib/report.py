"""A reporter that is readable during a long run, not just after it.

unittest's own verbose format prints 'test_id ... ok' per test. That is fine
in a CI log and poor to read when a run takes eight minutes: the ids are the
class and method names, there is no timing, and while a test is waiting on a
server there is nothing on screen to say whether it is working or stuck.

This changes only what is printed. It is a TextTestResult, which is what
TextTestRunner's resultclass argument exists for, so discovery, assertions,
skipping and exit codes all stay the standard ones.
"""

import time
import unittest


def humanise(name):
    """'test_the_tracks_fill' -> 'the tracks fill'."""
    if name.startswith("test_"):
        name = name[5:]
    return name.replace("_", " ")


def describe(test):
    """(group, label) for a test, or for a class-level skip or error.

    When setUpClass skips, unittest reports it through an _ErrorHolder rather
    than a TestCase -- so nothing may be assumed about the attributes.
    """
    label = getattr(test, "_testMethodName", None)

    if label is None:
        # A class-level outcome: the holder's string is like
        # 'setUpClass (dstm.test_basic.Queue)'.
        text = str(test)
        label = "the whole class"
        group = text.split(" (", 1)[1].rstrip(")") if " (" in text else "class setup"
        return group.rsplit(".", 1)[0] if "." in group else group, label

    module = test.__class__.__module__.replace(".test_", ".")
    return f"{module} · {test.__class__.__name__}", humanise(label)


class ReadableResult(unittest.TextTestResult):
    """Prints one line per test, grouped by class, with how long it took."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._group = None
        self._started = None
        self._finished = None

    def startTest(self, test):
        super().startTest(test)
        now = time.time()
        self._started = now

        group, _label = describe(test)
        if group != self._group:
            # A class's setUpClass runs before its first startTest, so the
            # gap since the previous test is mostly that. It is not timed by
            # unittest and would otherwise be invisible -- which reads as the
            # run having hung.
            if self._group is not None and self._finished:
                gap = now - self._finished
                if gap > 2:
                    self.stream.writeln(f"  (class setup: {gap:.1f}s)")

            self._group = group
            self.stream.writeln("")
            self.stream.writeln(group)

    def addSuccess(self, test):
        super().addSuccess(test)
        self._line(test, "ok")

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self._line(test, f"skipped: {reason}")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._line(test, "FAILED")

    def addError(self, test, err):
        super().addError(test, err)
        self._line(test, "ERROR")

    def _line(self, test, verdict):
        took = time.time() - self._started if self._started else 0
        group, label = describe(test)

        # A class-level outcome never goes through startTest, so the heading
        # has to be able to appear here too.
        if group != self._group:
            self._group = group
            self.stream.writeln("")
            self.stream.writeln(group)

        self.stream.writeln(
            f"  {_shorten(label, 48):<48} {_shorten(verdict, 38):<38} {took:>5.1f}s")
        self.stream.flush()

        self._finished = time.time()


def _shorten(text, width):
    return text if len(text) <= width else text[: width - 3] + "..."


class ReadableRunner(unittest.TextTestRunner):
    resultclass = ReadableResult

    def __init__(self, **kwargs):
        kwargs.setdefault("verbosity", 0)     # our result does the printing
        super().__init__(**kwargs)
