# changelog.d

Release notes for the next version. Every pull request with a change SDK consumers would
notice adds **one new file** here instead of editing `CHANGELOG.md`, so release notes never
cause merge conflicts. At release time, `scripts/changelog.py roll` collects these files into
a version section of `CHANGELOG.md` and deletes them.

Pure chores (CI, tooling, internal refactors, docs, tests) with no consumer-visible change
need no file — say so in the PR body.

## Adding a note

Name the file after the change, in short kebab-case: `changelog.d/spin-live-show-fields.md`.
Use one or more of these headings, each followed by `- ` bullets:

```markdown
### Added

- **`Spin.liveShowId` — live-show metadata on each scheduled spin.** Every spin can now
  carry the UUID of the live show it belongs to. The field is optional, so older payloads
  decode exactly as before.

### Fixed

- First play no longer sits silent after loading reaches 100% on a slow AirPlay route.
```

The rules are strict, and the release fails (naming the file and line) if a note breaks them:

- Allowed headings, exactly: `### Added`, `### Changed`, `### Removed`, `### Fixed`.
- Every note is a bullet starting with `- ` under one of those headings.
- A bullet may continue onto following lines indented with spaces, including nested lists.
- `<!-- ... -->` comments are allowed but must fit on one line; they are not copied.
- Nothing else: no prose paragraphs, no other headings, no empty files.

Check your note locally with `python3 scripts/changelog.py check` (CI runs it too).

## Releasing

1. On the branch you are releasing from (`develop` for a main-line release, or the
   `release/X.Y.Z` branch for a patch), run:

   ```sh
   python3 scripts/changelog.py roll X.Y.Z
   ```

   This writes `## X.Y.Z - <today>` into `CHANGELOG.md` from any bullets still under
   `## [Unreleased]` followed by every file here (in filename order), empties
   `## [Unreleased]`, and deletes exactly the files it read. Nothing changes if a note is
   malformed or `CHANGELOG.md` already has a section for `X.Y.Z`. Use `--date YYYY-MM-DD`
   to set a different date.
2. Review the new section — add a lead paragraph above its headings if the release needs
   one — and commit it.
3. Ship as usual: the `develop` → `main` release PR, then tag `X.Y.Z` (for a patch line,
   tag the `release/X.Y.Z` branch tip directly).

Patch releases cut on a `release/*` branch: when the fix's note also sits here on
`develop`, record the patch's section on `develop` too (copy it below `## [Unreleased]`) and
delete the fragment it shipped, so the next main-line release doesn't repeat it. A
`release/*` branch older than `changelog.d/` has no script; edit its `CHANGELOG.md` by hand.
