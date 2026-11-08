# PlayolaPlayer Agent Notes

Read and follow `CLAUDE.md` for build, test, style, and review rules.

## Changelog
- Never edit `CHANGELOG.md` in a pull request, except for its bootstrap change or generated changelog edits in a `develop` → `main` release PR. Add one new file `changelog.d/<short-kebab-description>.md` instead (format and allowed headings in `changelog.d/README.md`). Pure chores with no consumer-visible change need no file — say so in the PR body.
- Validate notes with `python3 scripts/changelog.py check`; test the script with `python3 -m unittest discover -s scripts/tests`.
- At release time, `python3 scripts/changelog.py roll X.Y.Z` collects the files into `CHANGELOG.md` and deletes them (see "Releasing" in `changelog.d/README.md`).
