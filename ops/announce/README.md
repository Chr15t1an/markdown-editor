# Release-note posters

`post.py` posts one note per release to Bluesky and DEV (Mastodon is built but off), taken from
the version's `CHANGELOG.md` section. Dry run is the default and sends nothing:

```sh
python3 ops/announce/post.py --version 0.3.2                    # print every request, redacted
python3 ops/announce/post.py --version 0.3.2 --live             # post to Bluesky and DEV (platforms without secrets skip)
python3 -m unittest discover -s ops/announce -p 'test_*.py'     # tests; the network is patched to raise
```

The release workflow runs `post.py --only bluesky,dev --live` only when its `announce` input is
ticked, in the same run as a deploy, after the live site is checked. These posts exist to show the
project is alive; their reach is close to zero, so keep them to one per release.

## What gets posted

| Platform | Post | Disclosure |
|---|---|---|
| Bluesky | "Markdown Editor X.Y.Z: <first line of the section>", the site link (a link facet), "Automated post" — at most 300 characters | the account's `bot` self-label, plus "Automated post" in every post |
| DEV | an article titled "Markdown Editor X.Y.Z: <first line>", the section, the install line; title at most 128 characters; no `canonical_url` (Forem requires it to be unique across all articles, so a fixed site URL would reject every later release); published with `--live` | tag `#abotwrotethis`, `ai_disclosure_level: "fully_autonomous"` (best effort: Forem drops the field when its AI-disclosure setting is off, and the script then prints a warning), a closing line saying it was generated from a changelog that may be AI-written |
| Mastodon (off) | "Markdown Editor X.Y.Z", the section, the site, "Posted automatically from the project changelog." — at most 500 characters; `Idempotency-Key: X.Y.Z-mastodon` | the account's bot flag |

Before each live post the script reads the account's own recent posts (Bluesky `com.atproto.repo.listRecords` on the PDS — no AppView indexing lag,
Mastodon `accounts/:id/statuses`, DEV `articles/me/all`) and skips with "already posted" if one
already names "Markdown Editor X.Y.Z". Mastodon's idempotency key is a second guard that the
server keeps for one hour only.

**Why Mastodon is off:** CHANGELOG sections are drafted from commits and may be AI-written, and
mastodon.social does not allow solely AI-generated posts. Turn it on only if each section is
reviewed by a person before the release, or with an instance whose rules allow automated posts:
`post.py` never posts to Mastodon unless `--only` names it, so add `mastodon` to the workflow's
`--only` list and pass `MASTODON_INSTANCE` and `MASTODON_TOKEN`.

## Account setup (Christian, once)

Platforms require a person to create accounts; after that everything is API.

1. **Bluesky.** Create the account (for example `markdowneditor.bsky.social`). Settings › Privacy
   and security › App passwords › add one. Secrets: `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`.
   Mark it as a bot once: Bluesky asks bot accounts to carry a `bot` self-label on their profile
   (`app.bsky.actor.profile` `labels: {$type: "com.atproto.label.defs#selfLabels", values: [{val: "bot"}]}`,
   keeping the profile's other fields). Optional Actions variable `BLUESKY_PDS` if the account is
   not on `https://bsky.social`.
2. **DEV.** Create the account, then https://dev.to/settings/extensions › DEV API Keys › generate.
   Secret: `DEV_API_KEY`.
3. **Mastodon (only if enabling it).** Create the account, tick "This is an automated account"
   (Preferences › Profile), then Preferences › Development › New application with the
   `write:statuses`, `read:accounts` and `read:statuses` scopes. Secrets: `MASTODON_INSTANCE` (e.g.
   `https://mastodon.social`), `MASTODON_TOKEN`.

## Rules

- **Never reply** to anyone, and never post anywhere except one release note per release. The
  bot does not read mentions and must not be extended to answer them.
- No other platforms: not Hacker News, Reddit, Product Hunt, Lobsters, Lemmy, LinkedIn,
  fosstodon or Indie Hackers (they ban automated or AI-written posting).
- No retries or loops: a failed post exits 1 and the run says why.
