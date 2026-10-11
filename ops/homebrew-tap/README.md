# Homebrew tap (personal)

The cask that lets people run `brew install --cask chr15t1an/tap/markdown-editor`. It lives here
as a template until the tap repo exists; nothing in this folder is published by itself.

An official Homebrew cask is out of reach at $0: Homebrew requires notarized apps, and this one is
signed ad-hoc. A personal tap has no such rule, but Homebrew quarantines cask downloads, so tap users
still see the Open Anyway step once (the cask's `caveats` say so and point to the curl installer).
The cask does not strip quarantine: that is the bypass Homebrew is removing.

## Files

- `Casks/markdown-editor.rb` — the cask. `version`/`sha256` are the release that is live on the site
  (0.3.2 at the time of writing, 2026-10-10; checked against the live zip — the site serves only the current versioned zip, so the cask must track it). `livecheck` reads the site's
  `version.json`, because GitHub's `:github_latest` cannot see a private repo.
- `bump.sh X.Y.Z SHA256 [tap-checkout [--push]]` — rewrites `version` and `sha256`, prints the diff.
  It commits and pushes **only** with `--push` (the release workflow's `bump_tap` input passes it,
  after the live site is verified to serve that exact zip).

## One-time setup (Christian)

1. Create the public repo `Chr15t1an/homebrew-tap` (the `homebrew-` prefix is what makes
   `brew tap chr15t1an/tap` work).
2. Copy `Casks/` into it and push.
3. Create a fine-grained token with **Contents: read and write** on that one repo, and save it as
   the `TAP_TOKEN` Actions secret in `Chr15t1an/markdown-editor`.
4. Check it from any Mac: `brew tap chr15t1an/tap && brew info --cask chr15t1an/tap/markdown-editor`.
   Homebrew 6+ asks you to trust a third-party tap before using it.

After that, a release run with `deploy_site` and `bump_tap` ticked keeps the cask current.

## Checks

- `ruby -c Casks/markdown-editor.rb` — syntax.
- `brew style` / `brew audit --cask` — run them from a Mac where `brew` works, against the tap
  checkout (`brew audit --cask --tap chr15t1an/tap markdown-editor`). If you make a throwaway tap
  with `brew tap-new` to audit, `brew untap` it afterwards.
