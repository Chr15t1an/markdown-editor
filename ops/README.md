# Zero-touch distribution — switch-on checklist

Everything here is built and **off**. Nothing runs on a schedule, posts, pushes or deploys until
Christian does the setup below and ticks an input or passes a flag. This file is the one checklist
to switch it on. Spec: `docs/research/automated-distribution/PLAN.md` ($0 variant: no Apple
Developer ID, no X API, no paid listings).

## What is in the box

| Piece | Where | Off until |
|---|---|---|
| In-app update check | `Sources/MarkdownEditor/UpdateChecker.swift`, feed `site/version.template.json` | ships with the next release (not in 0.3.2; its CHANGELOG section must say so): off per user until they say yes (second-launch sheet or app menu) |
| Release workflow | `.github/workflows/release.yml`, `docs/release.md` §0 | run by hand; deploy / tap / publish / announce each need an input and secrets |
| Homebrew tap cask | `ops/homebrew-tap/` | the tap repo and `TAP_TOKEN` exist |
| Release-note posters | `ops/announce/` | accounts and secrets exist and `announce` is ticked |
| Curated-list PRs | `ops/lists/` | a person runs the five `gh` commands once |
| Weekly metrics | `ops/metrics/`, template `ops/workflows/weekly.yml` | moved to the ops repo |

## One-time setup (Christian), in this order

1. **Make `Chr15t1an/markdown-editor` public.** Every GitHub channel, the lists, the site's
   "Source on GitHub" link and Actions' free minutes depend on it. (Until then the release
   workflow draws on the private-repo free minutes and stops at the quota when no card is on file.)
2. **Give the bot a written scope** (one message): which lists get one PR each, that it may deploy
   the site, and that it may post one release note per release to Bluesky and DEV. Without it,
   every outward step still waits for a live "go".
3. **GitHub machine account** (one per person is allowed) with a classic, no-expiry PAT with
   `public_repo`; it owns a **private ops repo** for the scheduled workflow. Fine-grained tokens and
   GitHub Apps cannot open PRs on other people's public repos.
4. **Cloudflare:** an API token from the "Edit Cloudflare Workers" template for the account that
   owns `chri5tian.com`, plus that account's id → secrets `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
   in `Chr15t1an/markdown-editor`.
5. **Homebrew tap:** create `Chr15t1an/homebrew-tap`, copy `ops/homebrew-tap/Casks/` into it, and
   save a fine-grained token (Contents: read and write, that repo only) as `TAP_TOKEN`
   (`ops/homebrew-tap/README.md`).
6. **Accounts:** Bluesky and DEV (`ops/announce/README.md`); mark the Bluesky profile as a bot.
   AlternativeTo, OpenAlternative and SaaSHub free queues are manual web forms, done once by hand
   (never call the app a "clone" there). Paid priority reviews and X are skipped.
7. **Measurement** (optional, ~30 min): Search Console (DNS verify) + a service account, Bing
   Webmaster + IndexNow key, a Cloudflare analytics token — see § Metrics.

## Switch-on order

Turn on one thing per release and watch it once.

1. Run **Release** (Actions › Release › Run workflow, branch `main`) with every input off: it tests,
   packages and leaves a draft Release. Check the job summary and the draft's assets. The first
   run on the runner's real XCTest settles `scripts/known-test-failures.txt`; edit it if the set differs.
2. Next release: tick `deploy_site`. The run deploys and verifies the live site (version.json,
   install.sh pin, zip SHA-256).
3. Then `deploy_site` + `bump_tap`.
4. Once the repo is public: `deploy_site` + `publish_release`.
5. Then `deploy_site` + `announce` (Bluesky, DEV).
6. Open the five curated-list PRs once (`ops/lists/README.md`).
7. Move `ops/workflows/weekly.yml` and `ops/metrics/` into the ops repo (`.github/workflows/weekly.yml`
   there), add `GH_TRAFFIC_TOKEN` as its secret.

**Mastodon stays off.** The poster is built, but CHANGELOG sections may be AI-written and
mastodon.social forbids solely AI-generated posts. Enable it only with human-reviewed sections or
another instance (`ops/announce/README.md`).

## Secrets and variables

| Name | Kind | Where | Used by |
|---|---|---|---|
| `CLOUDFLARE_API_TOKEN` | secret | markdown-editor | release.yml `deploy_site` (wrangler) |
| `CLOUDFLARE_ACCOUNT_ID` | secret | markdown-editor | release.yml `deploy_site` |
| `TAP_TOKEN` | secret | markdown-editor | release.yml `bump_tap` (checkout + push to the tap) |
| `BLUESKY_HANDLE` | secret | markdown-editor | `ops/announce/post.py` |
| `BLUESKY_APP_PASSWORD` | secret | markdown-editor | `ops/announce/post.py` |
| `BLUESKY_PDS` | variable (optional) | markdown-editor | `ops/announce/post.py`, default `https://bsky.social` |
| `DEV_API_KEY` | secret | markdown-editor | `ops/announce/post.py` |
| `MASTODON_INSTANCE` | secret (unused while off) | markdown-editor | `ops/announce/post.py` |
| `MASTODON_TOKEN` | secret (unused while off) | markdown-editor | `ops/announce/post.py` |
| `GH_TRAFFIC_TOKEN` | secret | ops repo | `ops/metrics/collect.py` (token with push access to markdown-editor, for traffic) |
| `SEARCH_CONSOLE_CREDENTIALS`, `SEARCH_CONSOLE_SITE` | secrets | ops repo | `collect.py` stub |
| `BING_WEBMASTER_API_KEY` | secret | ops repo | `collect.py` stub |
| `CLOUDFLARE_ANALYTICS_TOKEN`, `CLOUDFLARE_ZONE_ID` | secrets | ops repo | `collect.py` stub |

`GH_TOKEN` in release.yml is the workflow's own `github.token`, given only to the `gh` steps; no
secret to create.

## Metrics

`python3 ops/metrics/collect.py --dry-run` prints what it would fetch, offline. Without
`--dry-run` it makes read-only GETs and appends one line to `ops/metrics/data/github.jsonl`
(git-ignored here; tracked in the ops repo). Built: GitHub stars/forks/watchers (anonymous; "not
public yet" while private), traffic views/clones/referrers (`GH_TRAFFIC_TOKEN`; GitHub keeps 14
days, so weekly storage is the point), and the distance to Homebrew's notability gate (75 stars,
225 when the author submits). Stubs that print "not configured" until their variables exist, and
"not built yet" after: Search Console, Bing Webmaster, Cloudflare analytics (free-plan referrer
filtering is unverified). Per-page download attribution (`install.sh?s=<page>`) would need a
`run_worker_first` Worker; not built.

## Never

From PLAN, for every bot and script here (one clause updated: the README no longer says "clone"):

- Reply to anyone who did not @mention the bot or reply to its post (X bans keyword-search
  replies; Reddit's spam example is literally "a bot that continuously promotes products").
- Post on HN, Reddit, Product Hunt, Lobsters, Lemmy, LinkedIn, fosstodon, Indie Hackers.
- Create pages per keyword variant, fabricate ratings, or use Google's Indexing API (job
  postings and livestreams only).
- Star, follow, or post into other people's repos in bulk.
- Call the app a "clone" on AlternativeTo (it rejects clones; the README used to say it).

And for this repo's code:

- **No script performs an outward action without an explicit flag.** `post.py` posts only with
  `--live`; `bump.sh` pushes only with `--push`; `prepare.py` never opens a PR; `collect.py` only
  reads; release.yml deploys, bumps, publishes and announces only when its input is ticked.
- No retries, backoff loops or schedules added to the posters.
- Never strip quarantine in the cask, and never propose paid options (Developer ID, X API, paid listings).
