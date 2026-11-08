import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import changelog  # noqa: E402
from changelog import ChangelogError  # noqa: E402

UNRELEASED_COMMENT = changelog.UNRELEASED_COMMENT

CHANGELOG = """# Changelog

Don't edit this file in a pull request.

## [Unreleased]

{unreleased}
## 0.21.1

### Added

- An older note.
"""


def changelog_with(unreleased=UNRELEASED_COMMENT + "\n"):
    return CHANGELOG.format(unreleased=unreleased)


class ParseNotesTests(unittest.TestCase):
    def test_reads_bullets_under_each_heading(self):
        notes = changelog.parse_notes(
            "### Added\n\n- New thing.\n\n### Fixed\n\n- Broken thing.\n", "a.md"
        )
        self.assertEqual(notes, {"Added": ["- New thing."], "Fixed": ["- Broken thing."]})

    def test_keeps_indented_continuation_lines_with_their_bullet(self):
        notes = changelog.parse_notes(
            "### Changed\n\n- First line\n  second line\n  - nested\n\n- Next.\n", "a.md"
        )
        self.assertEqual(
            notes["Changed"], ["- First line\n  second line\n  - nested", "- Next."]
        )

    def test_keeps_blank_lines_inside_a_bullet(self):
        notes = changelog.parse_notes("### Added\n\n- Intro:\n\n  1. step\n\n", "a.md")
        self.assertEqual(notes["Added"], ["- Intro:\n\n  1. step"])

    def test_ignores_comment_lines(self):
        notes = changelog.parse_notes(
            "<!-- hello -->\n### Added\n  <!-- inline -->\n- Thing.\n", "a.md"
        )
        self.assertEqual(notes, {"Added": ["- Thing."]})

    def test_rejects_unknown_heading_with_location(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:3: .*'### Ops'"):
            changelog.parse_notes("### Added\n- x\n### Ops\n- ENV: Y\n", "a.md")

    def test_rejects_prose_line(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:2: "):
            changelog.parse_notes("### Added\nJust some prose.\n", "a.md")

    def test_rejects_bullet_before_any_heading(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:1: "):
            changelog.parse_notes("- Orphan.\n", "a.md")

    def test_rejects_non_dash_bullet(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:2: "):
            changelog.parse_notes("### Added\n* Star bullet.\n", "a.md")

    def test_rejects_empty_bullet(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:2: "):
            changelog.parse_notes("### Added\n- \n", "a.md")

    def test_rejects_indented_line_with_no_bullet_above(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:2: "):
            changelog.parse_notes("### Added\n  dangling\n", "a.md")

    def test_rejects_unterminated_comment(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:1: "):
            changelog.parse_notes("<!-- starts\n  ends -->\n", "a.md")

    def test_rejects_text_between_two_comments(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:2: "):
            changelog.parse_notes("### Added\n<!-- a --> visible <!-- b -->\n", "a.md")

    def test_keeps_trailing_spaces_inside_a_bullet(self):
        notes = changelog.parse_notes("### Added\n- First  \n  second\n", "a.md")
        self.assertEqual(notes["Added"], ["- First  \n  second"])

    def test_counts_only_newlines_as_line_breaks(self):
        with self.assertRaisesRegex(ChangelogError, r"^a\.md:3: "):
            changelog.parse_notes("### Added\n- x\u2028y\nprose\n", "a.md")

    def test_counts_lines_from_the_given_offset(self):
        with self.assertRaisesRegex(ChangelogError, r"^CHANGELOG\.md:12: "):
            changelog.parse_notes("### Added\nprose\n", "CHANGELOG.md", first_line=11)


class CollectTests(unittest.TestCase):
    def test_puts_legacy_unreleased_bullets_ahead_of_fragments(self):
        text = changelog_with("### Fixed\n\n- Legacy fix.\n\n")
        notes = changelog.collect(text, [("a.md", "### Fixed\n- Fragment fix.\n")])
        self.assertEqual(notes, {"Fixed": ["- Legacy fix.", "- Fragment fix."]})

    def test_rejects_empty_fragment(self):
        with self.assertRaisesRegex(ChangelogError, r"^changelog\.d/a\.md:1: "):
            changelog.collect(changelog_with(), [("changelog.d/a.md", "<!-- x -->\n")])

    def test_reports_malformed_legacy_line_by_changelog_line_number(self):
        text = changelog_with("### Added\n\nnot a bullet\n\n")
        with self.assertRaisesRegex(ChangelogError, r"^CHANGELOG\.md:9: "):
            changelog.collect(text, [])

    def test_rejects_non_version_heading_ending_unreleased(self):
        text = changelog_with("## Fixed\n\n- Stranded.\n\n")
        with self.assertRaisesRegex(ChangelogError, r"^CHANGELOG\.md:7: .*'## Fixed'"):
            changelog.collect(text, [])

    def test_rejects_version_lookalike_heading_ending_unreleased(self):
        text = changelog_with("## 0.22.0Migration\n\n### Fixed\n\n- Stranded.\n\n")
        with self.assertRaisesRegex(ChangelogError, r"^CHANGELOG\.md:7: "):
            changelog.collect(text, [])

    def test_accepts_bracketed_and_prerelease_version_headings_after_unreleased(self):
        for heading in ("## [4.40.1] - 2026-11-04", "## 0.21.0-beta.4", "## [1.0.0](https://x)"):
            with self.subTest(heading=heading):
                text = f"## [Unreleased]\n\n### Added\n\n- A.\n\n{heading}\n"
                self.assertEqual(changelog.collect(text, []), {"Added": ["- A."]})

    def test_requires_unreleased_heading(self):
        with self.assertRaisesRegex(ChangelogError, r"Unreleased"):
            changelog.collect("# Changelog\n\n## 0.1.0\n", [])


class RollTextTests(unittest.TestCase):
    def test_writes_dated_section_and_empties_unreleased(self):
        rolled = changelog.roll_text(
            changelog_with("### Added\n\n- Legacy.\n\n"),
            [("a.md", "### Fixed\n- Fix.\n"), ("b.md", "### Added\n- New.\n")],
            "0.22.0",
            "2026-11-07",
        )
        expected = changelog_with(
            UNRELEASED_COMMENT
            + "\n\n## 0.22.0 - 2026-11-07\n\n"
            + "### Added\n\n- Legacy.\n\n- New.\n\n"
            + "### Fixed\n\n- Fix.\n"
        )
        self.assertEqual(rolled, expected)

    def test_orders_headings_added_changed_removed_fixed(self):
        rolled = changelog.roll_text(
            changelog_with(),
            [("a.md", "### Fixed\n- F.\n### Removed\n- R.\n### Changed\n- C.\n### Added\n- A.\n")],
            "0.22.0",
            "2026-11-07",
        )
        positions = [rolled.index(f"### {h}\n\n- {h[0]}.") for h in changelog.HEADINGS]
        self.assertEqual(positions, sorted(positions))

    def test_rejects_existing_version_section(self):
        with self.assertRaisesRegex(ChangelogError, r"0\.21\.1"):
            changelog.roll_text(changelog_with(), [("a.md", "### Added\n- x\n")], "0.21.1", "2026-11-07")

    def test_rejects_existing_bracketed_version_section(self):
        text = changelog_with() + "\n## [0.20.0] - 2026-01-01\n"
        with self.assertRaisesRegex(ChangelogError, r"0\.20\.0"):
            changelog.roll_text(text, [("a.md", "### Added\n- x\n")], "0.20.0", "2026-11-07")

    def test_prerelease_of_existing_version_is_not_a_duplicate(self):
        rolled = changelog.roll_text(
            changelog_with(), [("a.md", "### Added\n- x\n")], "0.21.1-beta.1", "2026-11-07"
        )
        self.assertIn("## 0.21.1-beta.1 - 2026-11-07", rolled)

    def test_rejects_missing_or_malformed_version(self):
        for version in ("", "v0.22.0", "0.22", "01.22.0", "0.22.0-beta..1", "0.22.0-beta."):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ChangelogError, r"version"):
                    changelog.roll_text(changelog_with(), [("a.md", "### Added\n- x\n")], version, "2026-11-07")

    def test_rejects_empty_release(self):
        with self.assertRaisesRegex(ChangelogError, r"no pending release notes"):
            changelog.roll_text(changelog_with(), [], "0.22.0", "2026-11-07")

    def test_does_not_treat_a_split_heading_as_a_version_section(self):
        text = changelog_with(UNRELEASED_COMMENT + "\n\n## \n0.20.0\n")
        with self.assertRaisesRegex(ChangelogError, r"expected a version heading"):
            changelog.collect(text, [])

    def test_does_not_treat_a_split_heading_as_an_existing_version(self):
        text = changelog_with() + "\n## \n0.20.0\n"
        rolled = changelog.roll_text(text, [("a.md", "### Added\n- x\n")], "0.20.0", "2026-11-07")
        self.assertIn("## 0.20.0 - 2026-11-07", rolled)

    def test_rejects_existing_version_heading_with_link_or_extra_spaces(self):
        for heading in ("## [0.20.0](https://example.com)", "##  0.20.0"):
            with self.subTest(heading=heading):
                text = changelog_with() + f"\n{heading}\n"
                with self.assertRaisesRegex(ChangelogError, r"0\.20\.0"):
                    changelog.roll_text(text, [("a.md", "### Added\n- x\n")], "0.20.0", "2026-11-07")


class RollFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.changelog_path = self.root / "CHANGELOG.md"
        self.fragments = self.root / "changelog.d"
        self.fragments.mkdir()
        (self.fragments / "README.md").write_text("# How to\n\nprose that is not a note\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_changelog_and_deletes_exactly_the_fragments_it_read(self):
        self.changelog_path.write_text(changelog_with())
        (self.fragments / "a.md").write_text("### Added\n- A.\n")
        (self.fragments / ".DS_Store").write_text("junk")

        changelog.roll(self.changelog_path, self.fragments, "0.22.0", "2026-11-07")

        self.assertIn("## 0.22.0 - 2026-11-07\n\n### Added\n\n- A.\n", self.changelog_path.read_text())
        self.assertEqual(sorted(p.name for p in self.fragments.iterdir()), [".DS_Store", "README.md"])

    def test_changes_nothing_when_a_fragment_is_malformed(self):
        original = changelog_with()
        self.changelog_path.write_text(original)
        (self.fragments / "a.md").write_text("### Added\n- A.\n")
        (self.fragments / "b.md").write_text("### Added\nprose\n")

        with self.assertRaisesRegex(ChangelogError, r"b\.md:2: "):
            changelog.roll(self.changelog_path, self.fragments, "0.22.0", "2026-11-07")

        self.assertEqual(self.changelog_path.read_text(), original)
        self.assertTrue((self.fragments / "a.md").exists())

    def test_rejects_non_markdown_files_in_fragment_dir(self):
        self.changelog_path.write_text(changelog_with())
        (self.fragments / "a.txt").write_text("### Added\n- A.\n")

        with self.assertRaisesRegex(ChangelogError, r"a\.txt"):
            changelog.roll(self.changelog_path, self.fragments, "0.22.0", "2026-11-07")


if __name__ == "__main__":
    unittest.main()
