# Releasing a new version

The download site at **https://markdown.chri5tian.com** serves one page and the zip beside it, as a
Cloudflare Workers static-assets project (`markdown-editor-site`) on the personal Cloudflare account.
`scripts/package-release.sh` builds the app, zips it and renders the page, so the version, size and
SHA-256 on the page always describe the zip deployed with it.

Every command runs from the repo root unless it says otherwise, and works in bash or zsh.

## 1. Bump the version

```sh
VERSION=0.2.0   # what users see (CFBundleShortVersionString)
BUILD=2         # always goes up by one (CFBundleVersion)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
plutil -lint Resources/Info.plist
```

PlistBuddy writes the keys back in sorted order, so the first bump also moves
`NSDocumentsFolderUsageDescription` two lines down in the diff. That is harmless.

## 2. Build, zip and render the site

```sh
scripts/package-release.sh
```

It prints the version, the zip path and its SHA-256, and leaves:

- `build/dist/Markdown-Editor-<version>.zip` and `.zip.sha256`, plus `build/dist/Markdown-Editor.zip`
  (the same bytes, at the stable "latest" URL);
- `build/site/`, the whole deployable site.

The zip is made with `ditto -c -k --norsrc --keepParent` and pinned mtimes. `--norsrc` matters: the
default ditto zip carries `._` files that Terminal `unzip` drops inside the bundle, which breaks the
signature.

Builds are not bit-for-bit reproducible: two runs on the same sources can give different zip SHAs
(the binary's LC_UUID can change). That is fine. Each release publishes the SHA-256 of the exact zip
it ships, and the page is rendered from that same zip, so always deploy the `build/site/` from the
run you checked. The release is always signed ad-hoc, whatever is in the builder's keychain; the
script refuses to zip anything else.

## 3. Check it

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
grep -c "$(shasum -a 256 build/site/Markdown-Editor.zip | cut -d ' ' -f 1)" build/site/index.html
grep -c '{{' build/site/index.html || true   # expect 0

# wrangler accepts the config and sees the files (no login needed)
(cd site && npx wrangler deploy --dry-run)

rm -rf "$CHECK"
```

To look at the page before deploying: `python3 -m http.server 8765 --directory build/site`, then open
http://127.0.0.1:8765 and check it in light and dark mode and at phone width.

## 4. Commit

Commit the version bump (and anything else that changed) on a branch and merge it to `main` as
usual. `build/` is ignored; nothing it holds is committed.

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
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
curl -sI https://markdown.chri5tian.com/ | head -1
curl -sI https://markdown.chri5tian.com/Markdown-Editor.zip
curl -sI https://markdown.chri5tian.com/Markdown-Editor.zip | grep -i content-disposition   # from site/_headers
stat -f %z build/dist/Markdown-Editor.zip     # compare with Content-Length, if it is sent
curl -s https://markdown.chri5tian.com/Markdown-Editor.zip | shasum -a 256
curl -s https://markdown.chri5tian.com/ | grep -o "v$V"
```

Expect 200 on both, `content-disposition: attachment` on the zip (proves `site/_headers` is live), and the downloaded SHA-256 equal to the one the script printed. Whether Workers
static assets send `Content-Length` is not documented; if the header is missing, the SHA check is the
one that counts.

Then do one real download in Safari: open the zip, move the app to Applications, double-click, and
take the Open Anyway path in System Settings. If the wording macOS shows has changed, update the
"First launch" box in `site/index.template.html` and the Install section of the README.

## Notes

- **macOS 15 is untested.** The "macOS 15 or later" claim rests on static evidence: the binary says
  `minos 15.0`, the sources compile against the macOS 15.4 SDK, and there are no availability guards.
  Nobody has launched it on a macOS 15 machine yet.
- **Rollback:** `cd site && npx wrangler delete markdown-editor-site` removes the Worker and its
  custom domain. To put an older version back, check out its tag or commit and repeat steps 2 to 5.
- **Screenshot:** `site/screenshot.png` (1100×750, 1x) is the page image and the `og:image`. If the UI
  changes, replace it with a shot of a sample notes folder (never real notes) at the same size.
  Capturing the app window with `screencapture -l <window id>` needs the Screen Recording permission
  for the terminal that runs it.
