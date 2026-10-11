# Releasing a new version

The download site at **https://markdown.chri5tian.com** serves one page, the zip beside it and
`install.sh` (the `curl -fsSL https://markdown.chri5tian.com/install.sh | bash` installer), as a
Cloudflare Workers static-assets project (`markdown-editor-site`) on the personal Cloudflare account.
`scripts/package-release.sh` builds the app, zips it and renders the page and `install.sh`, so the
version, size and SHA-256 on the page and in the script always describe the zip deployed with them.

Every command runs from the repo root unless it says otherwise, and works in bash or zsh.

## 0. CI release (optional, switched off until set up)

`.github/workflows/release.yml` can do §3–§6 on a GitHub `macos-26` runner instead of this Mac. It
never runs by itself: it is started by hand (Actions › Release › Run workflow) and only on `main`.
One-time setup (secrets, the tap repo, accounts) and the order to switch things on are in
[`ops/README.md`](../ops/README.md). After §1 and §2 (bump, changelog, merge), a run:

1. checks the three version copies (`scripts/check-version.sh`) and takes the Release notes from
   the version's `CHANGELOG.md` section (`scripts/changelog-section.sh`); no section, no run;
2. refuses a version that is already live or already has a GitHub Release, so a re-run can never
   put new bytes behind a published versioned URL. It fails closed: the run stops unless the site
   answers a clean 404 for `Markdown-Editor-X.Y.Z.zip` (a manual release has no GitHub Release, and
   one made before this workflow has no `version.json`), `version.json` doesn't say X.Y.Z, and `gh`
   answers "release not found" (any other `gh` error stops it too);
3. runs the tests and fails on any failure not listed in `scripts/known-test-failures.txt`
   (`scripts/check-test-failures.sh`; the job summary shows the comparison);
4. builds and packages with `scripts/package-release.sh` (ad-hoc, as here) and tars `build/site/`;
5. creates a **draft** GitHub Release `vX.Y.Z` pinned to the commit it built (`--target`), holding
   the zip, its `.sha256` and `site-X.Y.Z.tgz`. The draft is the saved copy of the shipped bytes,
   the CI counterpart of §4's `~/Documents/markdown-editor-releases/` folder.

Everything after that is off unless its input is ticked, and each needs `deploy_site` in the same run:

| Input | Does | Needs |
|---|---|---|
| `deploy_site` | `npx wrangler deploy` from `site/` (§5), then `scripts/check-live-release.sh` polls the live `version.json`, `install.sh` `SHA256=` and the zip's SHA-256 for up to 5 minutes (§6) | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` secrets |
| `bump_tap` | `ops/homebrew-tap/bump.sh … --push` to `Chr15t1an/homebrew-tap` | `TAP_TOKEN` secret, the tap repo |
| `publish_release` | turns the draft into a published Release (only useful once the repo is public) | — |
| `announce` | `ops/announce/post.py --live` to Bluesky and DEV | their secrets (ops/announce/README.md) |
| `resume_draft` | after a failed deploy: re-packages the draft's saved zip with `RELEASE_ZIP` (no rebuild) and deploys that | an existing draft for the version |

The tap, publish and announce steps run only after the live check passes.

**If a step after a successful deploy fails** (the live check timing out, the tap push, publish or
announce), do not re-run the workflow: the guard refuses a version that is already live, with or
without `resume_draft`. Finish by hand from a checkout of the release commit, after confirming
`scripts/check-live-release.sh X.Y.Z <sha256>` passes (the SHA is in the job summary and the draft's
`.sha256` asset): `ops/homebrew-tap/bump.sh X.Y.Z <sha256> <tap-checkout> --push`,
`gh release edit vX.Y.Z --draft=false`, and `python3 ops/announce/post.py --version X.Y.Z --live`
(its duplicate check skips platforms that already have the post). A CI build is a
different set of bytes from any local dry run (builds are not reproducible, §3); the draft Release
is the identity of a CI release.

**Rollback** from a CI release: download the previous release's `site-X.Y.Z.tgz` from its GitHub
Release, unpack it, and deploy that folder as in the Notes' rollback step
(`cd site && npx wrangler deploy --assets <unpacked>/site`). Never rebuild an old commit.

**Cost:** the repo is private, so runs draw on the account's free Actions minutes (macOS minutes
count at a higher rate); with no payment method on file, usage stops at the quota instead of being
billed. Once the repo is public, standard runners are free.

## 1. Bump the version and write the changelog

On the branch that carries the release, set the new version (replace `X.Y.Z`; the build number goes
up by one by itself):

```sh
scripts/bump-version.sh X.Y.Z
git diff Resources/Info.plist Sources/MarkdownCore/MarkdownCore.swift Tests/MarkdownCoreTests/SmokeTests.swift
```

The version is written in three places: `Resources/Info.plist` (`CFBundleShortVersionString`, the
source of truth, and `CFBundleVersion`), `MarkdownCore.version` in
`Sources/MarkdownCore/MarkdownCore.swift`, and the test that asserts it,
`Tests/MarkdownCoreTests/SmokeTests.swift`. The script writes all three and then runs
`scripts/check-version.sh`, which prints each copy and exits 1 if they disagree. Run the check on
its own any time; the CI release workflow runs it first.

PlistBuddy writes the keys back in its own order, so a bump can also move
`NSDocumentsFolderUsageDescription` two lines down in the diff. That is harmless; move it back by
hand if you want the diff to be just the two version lines.

Then add a section for the version at the top of `CHANGELOG.md`, headed `## X.Y.Z — YYYY-MM-DD`,
whose first line is a one-sentence summary. The GitHub Release notes and the release-note posters
(`ops/announce/`) use that section verbatim; the CI workflow refuses to run without it.

## 2. Commit and merge

Commit the version bump (and anything else that changed) on that branch and squash-merge it to
`main` as usual. `build/` is ignored; nothing it holds is committed.

Then build the release in the **main checkout, on the merged `main` commit**, not in a worktree:
`site/wrangler.jsonc` deploys `../build/site`, the build of whichever checkout you deploy from. A
packaging run in the task worktree before the merge is fine as a dry run, but it is never the one
you deploy, because builds are not reproducible (see §3).

## 3. Build, zip and render the site

```sh
scripts/package-release.sh
```

It prints the version, the zip path and its SHA-256, and leaves:

- `build/dist/Markdown-Editor-<version>.zip` and `.zip.sha256`, plus `build/dist/Markdown-Editor.zip`
  (the same bytes, at the stable "latest" URL);
- `build/site/`, the whole deployable site: 14 files (`_headers`, `index.html`, `install.sh`, `version.json`,
  `style.css`, `screenshot.png`, `screenshot-dark.png`, `app-icon-512.png`, `favicon.svg`,
  `favicon-32.png`, `apple-touch-icon.png`, both zips and the `.sha256`). `index.html`, `install.sh` and
  `version.json` (the app's update feed, read by Check for Updates) are rendered from
  `site/index.template.html`, `site/install.template.sh` and `site/version.template.json`.

**Re-rendering a version that is already live** (for example, to ship a page or `install.sh` change
without a new version): do not rebuild, because a rebuild can change the bytes behind the versioned
URL (see below). Package the zip that is already published instead:

```sh
ls ~/Documents/markdown-editor-releases/   # one folder per published release, saved in §4
RELEASE_ZIP=~/Documents/markdown-editor-releases/X.Y.Z-0123456789ab/Markdown-Editor-X.Y.Z.zip \
  scripts/package-release.sh
```

(Replace `X.Y.Z-0123456789ab` with the live release's folder name, its version plus the first 12
hex digits of its SHA-256, and `X.Y.Z` with that version.) It copies that zip byte for byte (after
checking it holds an ad-hoc-signed `Markdown Editor.app` and nothing else, with no `._` / `__MACOSX`
entries), takes the version from the app inside it, and renders the site from it. It refuses a zip
whose SHA-256 differs from `EXPECTED_SHA256`, if you set it, or else from the `<zip>.sha256` file
beside it (the durable copies have one); with neither it warns. The printed SHA-256 must be the one
already live.

The zip is made with `ditto -c -k --norsrc --keepParent` and pinned mtimes. `--norsrc` matters: the
default ditto zip carries `._` files that Terminal `unzip` drops inside the bundle, which breaks the
signature.

Builds are not bit-for-bit reproducible: two runs on the same sources can give different zip SHAs
(the binary's LC_UUID can change). That is fine. Each release publishes the SHA-256 of the exact zip
it ships, and the page is rendered from that same zip, so always deploy the `build/site/` from the
run you checked. The release is always signed ad-hoc, whatever is in the builder's keychain; the
script refuses to zip anything else.

## 4. Check it

```sh
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
CHECK="$(mktemp -d)"

# the signature survives both ways of unzipping
ditto -x -k "build/dist/Markdown-Editor-$V.zip" "$CHECK/ditto"
unzip -q "build/dist/Markdown-Editor-$V.zip" -d "$CHECK/unzip"
codesign --verify --strict "$CHECK/ditto/Markdown Editor.app" && echo "ditto ok"
codesign --verify --strict "$CHECK/unzip/Markdown Editor.app" && echo "unzip ok"

# the binary targets macOS 15 (minos 15.0)
otool -l "$CHECK/ditto/Markdown Editor.app/Contents/MacOS/MarkdownEditor" | grep -A4 LC_BUILD_VERSION

# the checksum file matches, and the page carries the same SHA and no unrendered tokens
(cd build/dist && shasum -a 256 -c "Markdown-Editor-$V.zip.sha256")
SHA="$(shasum -a 256 build/site/Markdown-Editor.zip | cut -d ' ' -f 1)"
grep -c "$SHA" build/site/index.html                  # expect 2
grep -c "$SHA" build/site/install.sh                  # expect 1
grep -c '{{' build/site/index.html build/site/install.sh || true   # expect 0 and 0
/bin/bash -n build/site/install.sh && echo "install.sh parses"   # macOS's bash 3.2, what users run
python3 -m json.tool build/site/version.json           # the update feed: {"version": "$V", ...}

# wrangler accepts the config and sees the files (no login needed); expect "Read 14 files"
(cd site && npx wrangler deploy --dry-run)

rm -rf "$CHECK"
```

To look at the page before deploying: `python3 -m http.server 8765 --bind 127.0.0.1 --directory build/site`,
then open http://127.0.0.1:8765 and check it in light and dark mode and at phone width, and that
**Copy** copies the one-liner.

**Run the real one-liner against that local server** before deploying. Two settings in `install.sh`
point it at the local copy and keep it out of `/Applications`:

```sh
TEST_APPS="$(mktemp -d)/apps"
MARKDOWN_EDITOR_BASE_URL=http://127.0.0.1:8765 MARKDOWN_EDITOR_INSTALL_DIR="$TEST_APPS" \
  bash -c 'curl -fsSL http://127.0.0.1:8765/install.sh | bash'
xattr -lr "$TEST_APPS/Markdown Editor.app" | grep quarantine || echo "no quarantine"
codesign -dvvv "$TEST_APPS/Markdown Editor.app" 2>&1 | grep CDHash      # = the zip's app
```

Expect "SHA-256 matches", the app to open with no "Not Opened" dialog, and "Installed Markdown Editor
<version> to …". `MARKDOWN_EDITOR_BASE_URL` accepts only `https://…` or `http://127.0.0.1:<port>`.
Afterwards quit the app and unregister the test copy:
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TEST_APPS/Markdown Editor.app"`.
`_headers` cannot be checked locally (neither `http.server` nor `wrangler deploy --dry-run` reads
it); §6 checks it live.

**Save the shipped bytes** before deploying. This folder is what `RELEASE_ZIP` re-renders from and
what a rollback redeploys; `build/` is wiped by the next packaging run.

```sh
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
SHA="$(shasum -a 256 build/site/Markdown-Editor.zip | cut -d ' ' -f 1)"
SAVE=~/Documents/markdown-editor-releases/"$V-$(printf %.12s "$SHA")"
mkdir -p "$SAVE" && cp build/dist/Markdown-Editor-"$V".zip build/dist/Markdown-Editor-"$V".zip.sha256 \
  build/dist/Markdown-Editor.zip "$SAVE"/ && rm -rf "$SAVE/site" && ditto build/site "$SAVE/site" &&
  diff -r build/site "$SAVE/site" && echo "saved to $SAVE"
```

## 5. Deploy

```sh
cd site && npx wrangler deploy
```

Credentials: wrangler needs the Cloudflare account that owns `chri5tian.com`. Either run
`npx wrangler login` once and sign in to that account, or export an API token for that account made
from the "Edit Cloudflare Workers" template:

```sh
export CLOUDFLARE_API_TOKEN=<token for that account>
export CLOUDFLARE_ACCOUNT_ID=<that account's id>
npx wrangler whoami   # confirm the account before deploying
```

`whoami` must name the account that owns `chri5tian.com`; a token for any other account fails or
deploys to the wrong place. The first deploy also creates the
`markdown.chri5tian.com` DNS record and certificate, because `wrangler.jsonc` sets
`custom_domain: true`. In a non-interactive run wrangler **overrides** any existing DNS record for
that name, so before the first deploy check that `markdown.chri5tian.com` has no record you want to
keep: `dig +short markdown.chri5tian.com` should print nothing, or look in the Cloudflare DNS
dashboard.

## 6. Verify the live site

```sh
scripts/verify-live.sh      # PASS/FAIL per check below; exits non-zero on any failure
```

It runs every check in this section except the real install, against `build/dist`'s zip (or
`EXPECTED_SHA256=<sha>` if `build/` is gone), and also checks the icon, favicon and screenshot URLs.
The checks by hand:

```sh
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
curl -sI https://markdown.chri5tian.com/ | head -1
curl -sI https://markdown.chri5tian.com/Markdown-Editor.zip
curl -sI https://markdown.chri5tian.com/Markdown-Editor.zip | grep -i content-disposition   # from site/_headers
stat -f %z build/dist/Markdown-Editor.zip     # compare with Content-Length, if it is sent
curl -s https://markdown.chri5tian.com/Markdown-Editor.zip | shasum -a 256
curl -s https://markdown.chri5tian.com/ | grep -o "v$V"
curl -sI https://markdown.chri5tian.com/install.sh   # 200, text/plain, max-age=300, no content-disposition
curl -s https://markdown.chri5tian.com/install.sh | grep '^SHA256='
curl -s https://markdown.chri5tian.com/version.json    # the update feed: {"version":"$V",...}
```

Expect 200 on all three, `content-disposition: attachment` on the zip (proves `site/_headers` is live), and the downloaded SHA-256 equal to the one the script printed. Whether Workers
static assets send `Content-Length` is not documented; if the header is missing, the SHA check is the
one that counts. `install.sh` must come back as `content-type: text/plain; charset=utf-8` with
`cache-control: public, max-age=300` and no `content-disposition` (a browser shows it instead of
downloading it), and its `SHA256=` line must equal the zip's SHA-256.

Then run the real one-liner on this Mac:

```sh
curl -fsSL https://markdown.chri5tian.com/install.sh | bash
```

It should print "SHA-256 matches", install to `/Applications/Markdown Editor.app` and open it with no
"Not Opened" dialog: the app shows a window, `CoreServicesUIAgent` has none
(`osascript -e 'tell application "System Events" to tell process "CoreServicesUIAgent" to count windows'`
→ 0), and the installed app has no `com.apple.quarantine` xattr.

Then do one real download in Safari: open the zip, move the app to Applications, double-click, and
take the Open Anyway path in System Settings. If the wording macOS shows has changed, update the
"First launch" box in `site/index.template.html` and the Install section of the README.

## Notes

- **macOS 15 is untested.** The "macOS 15 or later" claim rests on static evidence: the binary says
  `minos 15.0`, the sources compile against the macOS 15.4 SDK, and there are no availability guards.
  Nobody has launched it on a macOS 15 machine yet.
- **Rollback:** redeploy the previous release's saved site (from §4), with the same credentials
  and `whoami` check as §5, then reinstall with that site's own `install.sh`:
  `cd site && npx wrangler deploy --assets ~/Documents/markdown-editor-releases/X.Y.Z-0123456789ab/site`,
  then `bash ~/Documents/markdown-editor-releases/X.Y.Z-0123456789ab/site/install.sh` (the folder
  name as in §3). Do not rebuild an old commit: there are no release tags, and a rebuild gives a
  different SHA from the one that was published. `cd site && npx wrangler delete markdown-editor-site` takes the whole site down
  (Worker and custom domain).
- **The previous versioned zip goes away.** Each deploy serves only the new
  `Markdown-Editor-<version>.zip` and `Markdown-Editor.zip`; the old versioned URL returns 404. An
  old `install.sh` still in a cache then stops with "the download failed. Nothing was installed."
- **Screenshot:** `site/screenshot.png` (light) and `site/screenshot-dark.png` (2200×1500, the real
  window at 2x) are the page image; the light one is also the `og:image`. If the UI changes, replace
  both with shots of a sample notes folder (never real notes) at the same size. Light and dark
  without touching the system setting: see the design-system skill's platform recipes.
- **Icons:** `site/favicon.svg`, `favicon-32.png`, `apple-touch-icon.png` and `app-icon-512.png` are
  built from `brand/` (see `brand/README.md`); rebuild them when the icon changes.
  Capturing the app window with `screencapture -l <window id>` needs the Screen Recording permission
  for the terminal that runs it.
