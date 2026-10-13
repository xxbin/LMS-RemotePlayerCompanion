"""The packaging contract, checked against the real source tree.

LMS installs a zip only when install.xml is at its top level with no wrapper
directory, and it replaces the plugin directory wholesale when it does. A zip
that gets this wrong builds, uploads, and then does nothing on someone else's
server, so these assertions are the ones worth having.

Nothing here talks to a server, so this does not inherit DSTMTestCase.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def manifest():
    """install.xml, parsed, without importing build.py."""
    import xml.etree.ElementTree as ET

    return ET.parse(os.path.join(ROOT, "src", "install.xml")).getroot()


def version():
    """The version install.xml declares."""
    return manifest().findtext("version").strip()


def min_version():
    """The floor install.xml declares. The listing's minTarget must match it:
    the two are read by different code paths for the same decision."""
    return manifest().find("targetApplication").findtext("minVersion").strip()


def build(*args, cwd=ROOT):
    """Run build.py.

    GITHUB_REPOSITORY is set explicitly so the suite does not depend on the
    developer's git remote -- build.py falls back to it when the variable is
    absent, and a fresh clone with no origin would otherwise fail here.
    """
    env = dict(os.environ, GITHUB_REPOSITORY="xxbin/LMS-RemotePlayerCompanion")

    return subprocess.run(
        [sys.executable, os.path.join(ROOT, "build.py"), *args],
        cwd=cwd, env=env, capture_output=True, text=True)


class Packaging(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = tmp.name
        self.version = version()
        self.result = build("--out", self.out)
        self.assertEqual(self.result.returncode, 0, self.result.stderr)

    def zip_path(self):
        return os.path.join(self.out, f"RemotePlayerCompanion-{self.version}.zip")

    def names(self):
        with zipfile.ZipFile(self.zip_path()) as z:
            return z.namelist()

    def test_the_zip_has_install_xml_at_its_top_level(self):
        self.assertIn("install.xml", self.names())

    def test_no_entry_is_wrapped_in_a_directory(self):
        for name in self.names():
            self.assertFalse(name.startswith("./"), f"entry {name!r} is relative-prefixed")
            self.assertFalse(name.startswith("src/"), f"entry {name!r} carries src/")
        self.assertNotIn("src/install.xml", self.names())

    def test_the_zip_is_named_for_its_version(self):
        self.assertTrue(os.path.exists(self.zip_path()),
                        f"no RemotePlayerCompanion-{self.version}.zip in {self.out}")

    def test_the_plugin_module_travels_with_it(self):
        self.assertIn("Plugin.pm", self.names())
        self.assertTrue(any(n.startswith("DSTM/") for n in self.names()))

    def test_every_entry_carries_the_fixed_timestamp(self):
        """Not 'now': a zip stamped with the build time cannot be rebuilt to
        the same bytes, which is what makes the published sha checkable."""
        with zipfile.ZipFile(self.zip_path()) as z:
            stamps = {i.date_time for i in z.infolist()}
        self.assertEqual(stamps, {(1980, 1, 1, 0, 0, 0)})

    def test_entries_are_in_a_stable_order(self):
        """os.walk returns filesystem order, which differs between machines.
        Rebuilding here cannot catch an unsorted walk -- same machine, same
        order -- so the order is asserted directly."""
        names = self.names()
        self.assertEqual(names, sorted(names))

    def test_a_second_build_produces_the_same_bytes(self):
        def digest():
            with open(self.zip_path(), "rb") as fh:
                return hashlib.sha1(fh.read()).hexdigest()

        before = digest()
        self.assertEqual(build("--out", self.out).returncode, 0)
        self.assertEqual(before, digest())

    def test_it_builds_from_any_working_directory(self):
        """Paths come from __file__, not from where the script was invoked."""
        elsewhere = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, elsewhere, True)

        self.assertEqual(build("--out", elsewhere, cwd=elsewhere).returncode, 0)
        self.assertTrue(os.path.exists(
            os.path.join(elsewhere, f"RemotePlayerCompanion-{self.version}.zip")))

    # --- the listing, which is what an LMS client actually reads ---

    def listing(self):
        import xml.etree.ElementTree as ET

        return ET.parse(os.path.join(self.out, "repo.xml")).getroot()

    def test_the_listing_names_the_plugin_lms_will_install(self):
        plugin = self.listing().find("plugins/plugin")
        self.assertEqual(plugin.get("name"), "RemotePlayerCompanion")

    def test_the_listing_version_matches_the_zip(self):
        plugin = self.listing().find("plugins/plugin")
        self.assertEqual(plugin.get("version"), self.version)

    def test_the_listing_sha_is_the_zip_sha(self):
        plugin = self.listing().find("plugins/plugin")
        with open(self.zip_path(), "rb") as fh:
            actual = hashlib.sha1(fh.read()).hexdigest()
        self.assertEqual(plugin.findtext("sha"), actual)

    def test_the_listing_url_points_at_this_repositorys_versioned_asset(self):
        """The whole prefix, not just the shape: a url naming the wrong owner
        is a 404 on every client, which the client cannot tell apart from a
        plugin that was never published."""
        plugin = self.listing().find("plugins/plugin")
        url = plugin.findtext("url")
        self.assertTrue(url.startswith(
            "https://github.com/xxbin/LMS-RemotePlayerCompanion/releases/download/"
            f"v{self.version}/"), url)
        self.assertTrue(url.endswith(f"RemotePlayerCompanion-{self.version}.zip"))

    def test_the_listing_carries_the_floor_install_xml_declares(self):
        """Read from install.xml rather than pinned: a literal here would keep
        passing after someone bumped one file and forgot the other."""
        plugin = self.listing().find("plugins/plugin")
        self.assertEqual(plugin.get("minTarget"), min_version())
        self.assertEqual(plugin.get("maxTarget"), "*")

    def test_a_tag_that_disagrees_with_the_version_is_refused(self):
        result = build("--out", self.out, "--tag", "v9.9.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("9.9.9", result.stderr)

    def test_no_placeholder_survives_into_the_listing(self):
        with open(os.path.join(self.out, "repo.xml")) as fh:
            self.assertNotIn("@", fh.read())

    def test_a_stale_artifact_does_not_change_the_listing(self):
        """A leftover zip from an older build sits in the same directory. The
        digest has to describe this build's file, not whatever is lying around."""
        stale = os.path.join(self.out, "RemotePlayerCompanion-0.0.9.zip")
        with open(stale, "w") as fh:
            fh.write("not a zip")

        self.assertEqual(build("--out", self.out).returncode, 0)

        plugin = self.listing().find("plugins/plugin")
        with open(self.zip_path(), "rb") as fh:
            actual = hashlib.sha1(fh.read()).hexdigest()

        self.assertEqual(plugin.findtext("sha"), actual)
        self.assertEqual(plugin.get("version"), self.version)


class Listing(unittest.TestCase):
    """render_listing in isolation, where a value can be arranged to be hostile.

    The end-to-end tests build from the real tree, whose version is a plain
    semver, so they cannot reach the cases below at all.
    """

    TEMPLATE = (
        '<extensions><plugins>'
        '<plugin name="RemotePlayerCompanion" version="@VERSION@" minTarget="@MINTARGET@">'
        '<url>@URL@</url><sha>@SHA@</sha>'
        '</plugin></plugins></extensions>'
    )

    def setUp(self):
        sys.path.insert(0, ROOT)
        import build

        self.build = build
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = tmp.name

    def template(self, text=None):
        path = os.path.join(self.out, "t.in")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text or self.TEMPLATE.replace("@MINTARGET@", min_version()))
        return path

    def test_a_version_with_an_ampersand_still_produces_valid_xml(self):
        """read_version unescapes character references, so substitution has to
        escape them again. Otherwise the listing is malformed, and LMS answers
        a parse error by offering no plugins at all rather than one bad entry."""
        import xml.etree.ElementTree as ET

        path = self.build.render_listing(
            self.out, "1.0&beta", "0" * 40, template=self.template())

        ET.parse(path)

    def test_a_min_target_that_disagrees_with_install_xml_is_refused(self):
        """The listing's minTarget and install.xml's minVersion are read by
        different code paths for the same decision. Letting them drift ships a
        listing that advertises the wrong floor to every client."""
        template = self.template(
            self.TEMPLATE.replace("@MINTARGET@", "7.0"))

        with self.assertRaises(SystemExit) as caught:
            self.build.render_listing(self.out, "0.1.0", "0" * 40, template=template)

        self.assertIn("minTarget", str(caught.exception))

    def test_a_non_ascii_template_survives_a_non_utf8_locale(self):
        """open()'s default encoding is the locale's, and under LC_ALL=C that is
        ASCII -- so an accented character in the template would raise instead of
        producing a listing. Run in a subprocess, because the default encoding
        is fixed when the interpreter starts and cannot be changed after."""
        template = os.path.join(self.out, "accented.in")
        with open(template, "w", encoding="utf-8") as fh:
            fh.write(self.TEMPLATE.replace("@MINTARGET@", min_version())
                     .replace("<url>", '<desc lang="EN">Björk</desc><url>'))

        script = (
            "import sys; sys.path.insert(0, {root!r}); import build;"
            "build.render_listing({out!r}, '0.1.0', '0' * 40, template={tmpl!r})"
            .format(root=ROOT, out=self.out, tmpl=template))

        env = dict(os.environ, LC_ALL="C", LANG="C",
                   PYTHONCOERCECLOCALE="0", PYTHONUTF8="0")

        result = subprocess.run([sys.executable, "-c", script],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        with open(os.path.join(self.out, "repo.xml"), encoding="utf-8") as fh:
            self.assertIn("Björk", fh.read())

    def test_a_repository_that_is_not_owner_slash_name_is_refused(self):
        """A malformed value yields a syntactically valid url that 404s on
        every client, which the client cannot tell apart from a plugin that
        was never published."""
        for bad in ("RemotePlayerCompanion", "owner/name/extra", "owner/", "/name"):
            with self.subTest(repo=bad):
                with self.assertRaises(SystemExit):
                    self.build.release_url("0.1.0", repo=bad)

    def test_a_well_formed_repository_produces_the_asset_url(self):
        self.assertEqual(
            self.build.release_url("0.1.0", repo="owner/name"),
            "https://github.com/owner/name/releases/download/v0.1.0/"
            "RemotePlayerCompanion-0.1.0.zip")


if __name__ == "__main__":
    unittest.main(verbosity=2)
