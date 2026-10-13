#!/usr/bin/env python3
"""Build the plugin zip, and the repository listing that points at it.

The plugin is everything under src/, so the archive is built from inside it
rather than from the repository root. That is the whole reason for the src/
layout: there is no list of things to exclude, and therefore no list to fall
out of date.

The zip is reproducible -- sorted entries, a fixed timestamp, a fixed
compression level -- so rebuilding from the same tree yields the same bytes.
That is what lets anyone verify the published sha by checking out the tag.

Standard library only, so CI needs no install step.
"""

import argparse
import hashlib
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
DEFAULT_OUT = os.path.join(HERE, "build")

PLUGIN = "RemotePlayerCompanion"
MANIFEST = "install.xml"

# The earliest timestamp a zip can represent. Fixed so that the archive does
# not depend on when it was built.
ZIP_TIME = (1980, 1, 1, 0, 0, 0)

# Named rather than left to the zlib default, so the archive does not change
# when a Python release changes that default.
#
# What this does not buy: the deflate stream still comes from whichever zlib
# the interpreter links, so a verifier on a different one can get a different
# digest from an identical tree. Byte-stability is for a given toolchain, not
# across every one, and a mismatch is not by itself evidence of tampering.
COMPRESS_LEVEL = 9


def read_version(src=SRC):
    """The version install.xml declares. The single source of truth."""
    import xml.etree.ElementTree as ET

    root = ET.parse(os.path.join(src, MANIFEST)).getroot()
    version = (root.findtext("version") or "").strip()

    if not version:
        raise SystemExit(f"{MANIFEST} declares no <version>")

    return version


def plugin_files(src=SRC):
    """Every file under src/, as paths relative to it, in a stable order."""
    found = []

    for dirpath, dirnames, filenames in os.walk(src):
        dirnames.sort()

        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            found.append(os.path.relpath(full, src).replace(os.sep, "/"))

    return sorted(found)


def build_zip(src=SRC, out=DEFAULT_OUT, version=None):
    """Write RemotePlayerCompanion-<version>.zip and return its path."""
    version = version or read_version(src)
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"{PLUGIN}-{version}.zip")

    names = plugin_files(src)

    if MANIFEST not in names:
        raise SystemExit(f"{MANIFEST} is not in {src}/ -- LMS will not install this")

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16

            # Pinned rather than left to the platform default, so that a
            # verifier on Windows rebuilds the same bytes as CI on Linux.
            info.create_system = 3  # Unix

            with open(os.path.join(src, name), "rb") as fh:
                # The level goes here, not on ZipFile: with an explicit ZipInfo
                # the constructor's compresslevel is ignored, so passing it
                # there would leave the default in force while reading as
                # though it had been fixed.
                z.writestr(info, fh.read(), compresslevel=COMPRESS_LEVEL)

    return path


def sha1(path):
    digest = hashlib.sha1()

    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)

    return digest.hexdigest()


TEMPLATE = os.path.join(HERE, "repo.xml.in")
PLACEHOLDERS = ("@VERSION@", "@URL@", "@SHA@")


def release_url(version, repo=None):
    """Where this version's zip will live once CI has published it.

    GitHub builds release asset URLs out of the tag and the asset's filename,
    which is why the version has to be in the filename: the URL is the
    immutable address of one version's bytes.
    """
    repo = repo or os.environ.get("GITHUB_REPOSITORY") or origin_repo()

    # Checked, because a malformed value still composes into a URL that reads
    # as valid -- and a listing whose url 404s is indistinguishable, from the
    # client's side, from a plugin that was never published.
    if not re.fullmatch(r"[^/]+/[^/]+", repo):
        raise SystemExit(f"{repo!r} is not owner/name, so there is no way to "
                         "tell which repository this is being published from")

    return (f"https://github.com/{repo}/releases/download/v{version}/"
            f"{PLUGIN}-{version}.zip")


def origin_repo():
    """owner/name from the origin remote, for a local build."""
    import subprocess

    url = subprocess.run(["git", "remote", "get-url", "origin"],
                         cwd=HERE, capture_output=True, text=True).stdout.strip()
    match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)

    if not match:
        raise SystemExit(
            "cannot tell which repository to publish from: set GITHUB_REPOSITORY "
            f"or give origin a GitHub URL (origin is {url!r})")

    return match.group(1)


def read_min_version(src=SRC):
    """The LMS floor install.xml declares.

    The listing carries the same value as minTarget, and the two are read by
    different code paths for the same decision: PluginManager checks
    install.xml before loading, ExtensionsManager reads the listing before
    offering an update. Drift between them is what this function exists to
    catch.
    """
    import xml.etree.ElementTree as ET

    target = ET.parse(os.path.join(src, MANIFEST)).getroot().find("targetApplication")
    version = ((target.findtext("minVersion") if target is not None else "") or "").strip()

    if not version:
        raise SystemExit(f"{MANIFEST} declares no <targetApplication><minVersion>")

    return version


def render_listing(out, version, digest, template=TEMPLATE):
    """Fill the template and write repo.xml. Returns its path."""
    import xml.etree.ElementTree as ET

    with open(template, encoding="utf-8") as fh:
        text = fh.read()

    missing = [p for p in PLACEHOLDERS if p not in text]

    if missing:
        raise SystemExit(f"{template} is missing {', '.join(missing)}")

    # Escaped, not pasted. read_version goes through a parser, which unescapes
    # character references, so a value can arrive here holding a bare '&' that
    # would render the listing malformed.
    for placeholder, value in zip(PLACEHOLDERS, (version, release_url(version), digest)):
        text = text.replace(placeholder, escape(value))

    # A client that cannot parse the listing offers no plugins at all, rather
    # than one bad entry -- so a listing that does not parse is never written.
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        raise SystemExit(f"{template} renders to malformed XML: {exc}")

    plugin = root.find("plugins/plugin")
    rendered = plugin.get("minTarget") if plugin is not None else None
    declared = read_min_version()

    if rendered != declared:
        raise SystemExit(
            f"the listing's minTarget is {rendered!r} but {MANIFEST} declares "
            f"minVersion {declared!r}; the two decide the same thing and must agree")

    path = os.path.join(out, "repo.xml")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)

    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="where to write the artifacts (default: build/)")
    parser.add_argument("--tag", default=None,
                        help="the release tag, e.g. v0.1.0; checked against the version")
    args = parser.parse_args(argv)

    version = read_version()

    if args.tag is not None and args.tag != f"v{version}":
        raise SystemExit(f"tag {args.tag!r} disagrees with install.xml's version "
                         f"{version!r}; expected v{version}")

    path = build_zip(out=args.out, version=version)
    digest = sha1(path)
    listing = render_listing(args.out, version, digest)

    print(f"{os.path.relpath(path)}  sha1={digest}")
    print(os.path.relpath(listing))

    return 0


if __name__ == "__main__":
    sys.exit(main())
