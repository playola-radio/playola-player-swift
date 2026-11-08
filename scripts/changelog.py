#!/usr/bin/env python3
"""Collect changelog.d/ fragments into CHANGELOG.md at release time.

Each pull request adds its own note file under changelog.d/ (format in
changelog.d/README.md) instead of editing CHANGELOG.md, so release notes never
conflict. At release time:

    python3 scripts/changelog.py check          # validate + preview the notes
    python3 scripts/changelog.py roll 0.22.0    # write the version section

`roll` reads any bullets still under `## [Unreleased]` (from branches opened
before changelog.d/ existed) followed by every fragment, writes one dated
`## <version> - <date>` section, leaves `## [Unreleased]` holding only a
pointer comment, and deletes exactly the fragment files it read. Parsing is
strict: anything that is not an allowed heading, a `- ` bullet (with indented
continuation lines), a blank line, or a one-line `<!-- -->` comment is an error
naming file:line, and nothing is written. If deleting a fragment fails after
CHANGELOG.md is written, restore with git and rerun.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HEADINGS = ("Added", "Changed", "Removed", "Fixed")
UNRELEASED_COMMENT = (
    "<!-- Don't add notes here. Each pull request adds a file to changelog.d/ "
    "(see changelog.d/README.md); the release collects them. -->"
)
FRAGMENT_README = "README.md"

_REPO_ROOT = Path(__file__).resolve().parent.parent
_COMMENT_RE = re.compile(r"<!--(?:(?!-->).)*-->")
_UNRELEASED_RE = re.compile(r"^## \[Unreleased\][ \t]*$", re.MULTILINE)
_NEXT_SECTION_RE = re.compile(r"^## ", re.MULTILINE)
_VERSION_SECTION_RE = re.compile(r"##[ \t]+\[?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\]?(?=[ \t(]|$)", re.MULTILINE)
_VERSION_RE = re.compile(r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")

Notes = Dict[str, List[str]]


class ChangelogError(Exception):
    pass


def parse_notes(text: str, source: str, first_line: int = 1) -> Notes:
    """Parse release-note markdown into {heading: [bullet, ...]}.

    A bullet keeps its indented continuation lines (and blank lines between
    them) verbatim. Raises ChangelogError naming `source:line` on anything else.
    """
    notes: Notes = {}
    heading = None
    bullet: Optional[List[str]] = None

    def finish_bullet():
        if bullet is not None:
            while bullet and not bullet[-1]:
                bullet.pop()
            notes[heading].append("\n".join(bullet))

    for number, line in enumerate(text.split("\n"), start=first_line):
        stripped = line.strip()
        where = f"{source}:{number}"

        if stripped.startswith("<!--"):
            if not _COMMENT_RE.fullmatch(stripped):
                raise ChangelogError(f"{where}: a comment must be alone on one line: '{stripped}'")
            continue
        if not stripped:
            if bullet is not None:
                bullet.append("")
            continue
        if line.startswith("#"):
            match = re.fullmatch(r"### (\w+)", line.rstrip())
            if match is None or match.group(1) not in HEADINGS:
                allowed = ", ".join(f"'### {h}'" for h in HEADINGS)
                raise ChangelogError(f"{where}: unknown heading '{stripped}' (allowed: {allowed})")
            finish_bullet()
            bullet = None
            heading = match.group(1)
            notes.setdefault(heading, [])
            continue
        if line.startswith("- "):
            if heading is None:
                raise ChangelogError(f"{where}: bullet comes before any '### ' heading")
            if not line[2:].strip():
                raise ChangelogError(f"{where}: empty bullet")
            finish_bullet()
            bullet = [line]
            continue
        if line[0] in " \t":
            if bullet is None:
                raise ChangelogError(f"{where}: indented line is not part of a '- ' bullet")
            bullet.append(line)
            continue
        raise ChangelogError(
            f"{where}: expected a '### ' heading, a '- ' bullet, or a <!-- --> comment, got '{stripped}'"
        )

    finish_bullet()
    return {h: bullets for h, bullets in notes.items() if bullets}


def _unreleased_body(text: str) -> Tuple[int, int, int]:
    """Return (start, end, first_line) of the body under `## [Unreleased]`."""
    heading = _UNRELEASED_RE.search(text)
    if heading is None:
        raise ChangelogError("CHANGELOG.md has no '## [Unreleased]' heading")
    start = heading.end() + 1 if heading.end() < len(text) else len(text)
    next_section = _NEXT_SECTION_RE.search(text, start)
    end = next_section.start() if next_section else len(text)
    if next_section and not _VERSION_SECTION_RE.match(text, end):
        line = text.count("\n", 0, end) + 1
        heading = text[end:].split("\n", 1)[0]
        raise ChangelogError(f"CHANGELOG.md:{line}: expected a version heading after [Unreleased], got '{heading}'")
    first_line = text.count("\n", 0, start) + 1
    return start, end, first_line


def collect(changelog_text: str, fragments: List[Tuple[str, str]]) -> Notes:
    """Merge legacy `[Unreleased]` bullets, then each fragment, in order."""
    start, end, first_line = _unreleased_body(changelog_text)
    sources = [parse_notes(changelog_text[start:end], "CHANGELOG.md", first_line)]
    for name, text in fragments:
        notes = parse_notes(text, name)
        if not notes:
            raise ChangelogError(f"{name}:1: fragment has no '- ' bullets")
        sources.append(notes)

    merged: Notes = {}
    for notes in sources:
        for heading, bullets in notes.items():
            merged.setdefault(heading, []).extend(bullets)
    return merged


def render(notes: Notes) -> str:
    blocks = []
    for heading in HEADINGS:
        if heading in notes:
            blocks.append(f"### {heading}\n\n" + "\n\n".join(notes[heading]) + "\n\n")
    return "".join(blocks)


def roll_text(changelog_text: str, fragments: List[Tuple[str, str]], version: str, date: str) -> str:
    if not _VERSION_RE.match(version or ""):
        raise ChangelogError(f"invalid version '{version}' (expected e.g. 0.22.0 or 0.22.0-beta.1)")
    existing = re.compile(rf"^##[ \t]+\[?{re.escape(version)}(?![\w.-])", re.MULTILINE)
    if existing.search(changelog_text):
        raise ChangelogError(f"CHANGELOG.md already has a section for {version}")

    notes = collect(changelog_text, fragments)
    if not notes:
        raise ChangelogError("no pending release notes to roll")
    start, end, _ = _unreleased_body(changelog_text)
    section = f"## {version} - {date}\n\n" + render(notes)
    return changelog_text[:start] + f"\n{UNRELEASED_COMMENT}\n\n" + section + changelog_text[end:]


def _read_fragments(fragments_dir: Path, root: Path) -> Tuple[List[Path], List[Tuple[str, str]]]:
    paths = []
    for path in sorted(fragments_dir.iterdir()):
        if path.name.startswith(".") or path.name == FRAGMENT_README:
            continue
        if not path.is_file() or path.suffix != ".md":
            raise ChangelogError(f"{path}: changelog.d/ may only contain .md note files")
        paths.append(path)
    return paths, [(str(path.relative_to(root)), path.read_text()) for path in paths]


def roll(changelog_path: Path, fragments_dir: Path, version: str, date: str) -> List[Path]:
    """Roll notes into CHANGELOG.md and delete the fragments read."""
    paths, fragments = _read_fragments(fragments_dir, changelog_path.parent)
    rolled = roll_text(changelog_path.read_text(), fragments, version, date)

    tmp = changelog_path.with_name(changelog_path.name + ".tmp")
    tmp.write_text(rolled)
    os.replace(tmp, changelog_path)
    for path in paths:
        path.unlink()
    return paths


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect changelog.d/ fragments into CHANGELOG.md.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate all pending notes and print them")
    roll_parser = commands.add_parser("roll", help="write a version section and delete the fragments")
    roll_parser.add_argument("version", help="the version being released, e.g. 0.22.0")
    args = parser.parse_args(argv)
    changelog_path = _REPO_ROOT / "CHANGELOG.md"
    fragments_dir = _REPO_ROOT / "changelog.d"

    try:
        if args.command == "check":
            _, fragments = _read_fragments(fragments_dir, _REPO_ROOT)
            notes = collect(changelog_path.read_text(), fragments)
            print(render(notes).rstrip() or "No pending release notes.")
        else:
            date = datetime.date.today().isoformat()
            deleted = roll(changelog_path, fragments_dir, args.version, date)
            print(f"Wrote '## {args.version} - {date}' to CHANGELOG.md; deleted {len(deleted)} fragment(s).")
    except (ChangelogError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
