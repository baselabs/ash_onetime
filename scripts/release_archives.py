#!/usr/bin/env python3
"""Build and inspect what a release uploads, the same way in qualification and publication.

    python3 scripts/release_archives.py version
        Print the version mix.exs declares.
    python3 scripts/release_archives.py build ASSETS_DIR
        Build the Hex package with mix hex.build and inspect it with scripts/check_package.exs,
        build the docs with mix docs and pack them into a reproducible tarball, check its
        pages, and write SHA256SUMS over both archives. Writes version= and package_sha256=
        to $GITHUB_OUTPUT when it is set.
    python3 scripts/release_archives.py notes ASSETS_DIR
        Write NOTES.md from the dated CHANGELOG.md section for the version; refuse when the
        section is missing, undated or still Unreleased.

The release gates run build on every candidate and publish.yml runs build and notes before
its keyed step, so publication uploads bytes from the path qualification exercises. Run it
from the repository root; build runs Mix, so it runs in CI only.
"""

import datetime
import gzip
import hashlib
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

PACKAGE = "ash_onetime"
# Pages every docs build must hold; each but index.html names the version in its sidebar.
DOCS_PAGES = ("index.html", "readme.html", "changelog.html", "AshOnetime.Resource.html")


def version():
    found = re.findall(
        r'^\s*@version\s+"([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)"\s*$',
        Path("mix.exs").read_text(),
        re.MULTILINE,
    )
    if len(found) != 1:
        raise SystemExit("expected exactly one @version in mix.exs")
    return found[0]


def mix(*arguments):
    # The Ash matrix selector must never freeze the published dependency requirement.
    environment = {k: v for k, v in os.environ.items() if k != "ASH_ONETIME_ASH_VERSION"}
    subprocess.run(["mix", *arguments], check=True, env=environment)


def docs_archive(root, docs):
    with docs.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for source in sorted(root.rglob("*")):
                    if source.is_symlink() or not (source.is_file() or source.is_dir()):
                        raise SystemExit(f"unexpected docs entry: {source}")
                    info = archive.gettarinfo(str(source), arcname=source.relative_to(root).as_posix())
                    info.mtime = info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mode = 0o755 if source.is_dir() else 0o644
                    if source.is_file():
                        with source.open("rb") as contents:
                            archive.addfile(info, contents)
                    else:
                        archive.addfile(info)


def inspect_docs(docs, release):
    with tarfile.open(docs, "r:gz") as archive:
        for page in DOCS_PAGES:
            try:
                contents = archive.extractfile(page)
            except KeyError:
                contents = None
            if contents is None:
                raise SystemExit(f"docs archive lacks {page}")
            if page != "index.html" and f"v{release}" not in contents.read().decode():
                raise SystemExit(f"docs page {page} does not name v{release}")


def build(assets):
    release = version()
    assets.mkdir(parents=True, exist_ok=True)
    package = assets / f"{PACKAGE}-{release}.tar"
    docs = assets / f"{PACKAGE}-{release}-docs.tar.gz"

    mix("hex.build", "--output", str(package))
    mix("run", "scripts/check_package.exs", str(package))
    mix("docs", "--warnings-as-errors")
    docs_archive(Path("doc"), docs)
    inspect_docs(docs, release)

    digests = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (package, docs)}
    (assets / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for name, digest in sorted(digests.items()))
    )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"version={release}\npackage_sha256={digests[package.name]}\n")


def notes(assets):
    release = version()
    changelog = Path("CHANGELOG.md").read_text()
    sections = list(re.finditer(r"^## (.+)$", changelog, re.MULTILINE))
    prefix = f"v{release} — "
    matching = [i for i, section in enumerate(sections) if section[1].startswith(prefix)]
    if len(matching) != 1:
        raise SystemExit(f"expected one dated CHANGELOG section for v{release}, not Unreleased")
    index = matching[0]
    heading = sections[index]
    date = heading[1].removeprefix(prefix)
    try:
        datetime.datetime.strptime(date, "%B %d, %Y")
    except ValueError:
        raise SystemExit(f"CHANGELOG section for v{release} has no valid date: {date}")
    end = sections[index + 1].start() if index + 1 < len(sections) else len(changelog)
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "NOTES.md").write_text(changelog[heading.start():end].rstrip() + "\n")


def main(arguments):
    match arguments:
        case ["version"]:
            print(version())
        case ["build", assets]:
            build(Path(assets))
        case ["notes", assets]:
            notes(Path(assets))
        case _:
            raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
