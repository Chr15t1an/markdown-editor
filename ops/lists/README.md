# Curated-list pull requests

One pull request per list, ever. `prepare.py` writes everything a PR needs and sends nothing; a
person (or an agent Christian is supervising) opens the five PRs once, with the commands below.

```sh
python3 ops/lists/prepare.py              # fetch each list's current file (read-only) → ops/lists/out/
python3 ops/lists/prepare.py --offline    # entries and PR bodies only
python3 -m unittest discover -s ops/lists -p 'test_*.py'
```

`ops/lists/out/<owner>__<repo>/` (git-ignored) gets `entry.md` (the lines being added),
`pr-body.md` (the PR description, with the list's template filled where it has one) and
`patch.diff` (applies with `git apply` at the root of a fresh clone). Re-run `prepare.py` right
before opening the PRs: the lists change daily and the patch is made against today's file. A list
that already names the repo gets no patch.

## The five lists

| List | Where | Why this one |
|---|---|---|
| `jaywcjlove/awesome-swift-macos-apps` | README.md + README.zh.md › Editors › Markdown (appended) | Swift-only, merges fast; best fit |
| `jaywcjlove/awesome-mac` | README, -zh, -ja, -ko › Markdown Tools (alphabetical, OSS + freeware icons) | biggest list; welcomes AI-assisted PRs; slow |
| `serhii-londar/open-source-mac-os-apps` | `applications.json` (CONTRIBUTING: never README.md) | open-source-only list |
| `iCHAIT/awesome-macOS` | README.md › Utilities (alphabetical, next to MacDown and Typora) | its PR template must be filled or the PR is closed |
| `mundimark/awesome-markdown-editors` | UPCOMING.md › Apple Mac OS X (2026 policy: new entries go there first) | Markdown-specific |

Entry formats come from each list's README, CONTRIBUTING and PR template (read 2026-10-10) and
live in `lists.json`. The zh/ja/ko descriptions for the jaywcjlove lists are machine translations,
and every PR body says the entry was prepared with AI assistance and that the author is submitting it.

**Skipped on purpose:** `sindresorhus/awesome` (a list of lists, and it bans AI-generated PRs) and
`awesome-native-macosx-apps` (excludes self-promoted apps). Never call the app a "clone" anywhere.

## Before opening any PR

- The repo `Chr15t1an/markdown-editor` must be **public**: every list links to the source and
  checks it. The PRs also need the site to serve `app-icon-512.png` (0.3.2 or later deployed).
- Open them from the machine account (classic PAT with `public_repo`; fine-grained tokens and
  GitHub Apps cannot open PRs on other people's public repos), signed in with `gh auth login`.
- Read each `pr-body.md` and `patch.diff` once before running the commands. iCHAIT's template asks the author to confirm they read its guidelines and its AI section: those two boxes are left unticked for you to tick after reading them.

## Opening the five PRs (once, at switch-on)

From an empty scratch folder, signed in as the machine account. `OUT` is this repo's
`ops/lists/out`:

```sh
OUT=~/Documents/GitHub/markdown-editor/ops/lists/out
open_pr() {   # open_pr <owner/repo> <title>
  local repo="$1" title="$2" dir="${1#*/}" slug="${1/\//__}"
  gh repo fork "$repo" --clone --default-branch-only -- --depth 1 &&
  (cd "$dir" && git checkout -b add-markdown-editor &&
   git apply "$OUT/$slug/patch.diff" && git commit -am "$title" &&
   git push -u origin add-markdown-editor &&
   gh pr create --repo "$repo" --title "$title" --body-file "$OUT/$slug/pr-body.md")
}
open_pr jaywcjlove/awesome-swift-macos-apps   "Add Markdown Editor"
open_pr jaywcjlove/awesome-mac                "Add Markdown Editor to Markdown Tools"
open_pr serhii-londar/open-source-mac-os-apps "Add Markdown Editor"
open_pr iCHAIT/awesome-macOS                  "Add Markdown Editor"
open_pr mundimark/awesome-markdown-editors    "Add Markdown Editor (macOS) to Upcoming 2026"
```

Each `gh pr create` is a public post on someone else's repo: run them only with Christian's go.

## After opening

- Answer review comments on these five PRs only; never comment elsewhere. If a maintainer closes
  one, leave it closed unless they say how to fix it.
- Re-opening a stale PR, one time, is allowed; spamming or bumping is not.
