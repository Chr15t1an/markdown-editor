#!/usr/bin/env python3
"""Post one release note per platform from the version's CHANGELOG.md section.

    python3 ops/announce/post.py --version X.Y.Z                 dry run: print every request, send nothing
    python3 ops/announce/post.py --version X.Y.Z --live          post (each platform skips itself without its secrets)
    python3 ops/announce/post.py --version X.Y.Z --only bluesky,mastodon,dev --live

--only defaults to bluesky,dev: Mastodon is never posted to unless it is named explicitly.

Dry run is the default and opens no socket. --live is the only way anything is sent. Before each
live post the script reads the account's own recent posts and skips with "already posted" when one
already names "Markdown Editor X.Y.Z", so a re-run (or the next day) does not post twice.

Platforms and their environment variables (ops/announce/README.md has the account setup):
  bluesky   BLUESKY_HANDLE, BLUESKY_APP_PASSWORD, optional BLUESKY_PDS (default https://bsky.social)
  mastodon  MASTODON_INSTANCE (https://…), MASTODON_TOKEN — built but OFF by default (only when
            named in --only) and left out of the release workflow: mastodon.social forbids solely AI-generated posts, and CHANGELOG sections may
            be AI-written. Enable only with human-reviewed sections or another instance.
  dev       DEV_API_KEY — the article is published (with --live), tagged #abotwrotethis, with
            ai_disclosure_level "fully_autonomous".

Standard library only. No retries, no backoff: a failed post exits 1 and says why.
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SITE = "https://markdown.chri5tian.com/"
INSTALL = "curl -fsSL https://markdown.chri5tian.com/install.sh | bash"
PLATFORMS = ("bluesky", "mastodon", "dev")
DEFAULT_PLATFORMS = ("bluesky", "dev")   # Mastodon is off unless named in --only (see the docstring)
SECRETS = {
    "bluesky": ("BLUESKY_HANDLE", "BLUESKY_APP_PASSWORD"),
    "mastodon": ("MASTODON_INSTANCE", "MASTODON_TOKEN"),
    "dev": ("DEV_API_KEY",),
}
SECRET_HEADERS = {"authorization", "api-key"}
BLUESKY_MAX = 300   # graphemes; len() counts code points, which is >= graphemes, so it is safe
MASTODON_MAX = 500
DEV_TAGS = ["macos", "markdown", "opensource", "abotwrotethis"]   # DEV allows 4
DEV_TITLE_MAX = 128   # Forem rejects longer titles (422)
DEV_ACCEPT = "application/vnd.forem.api-v1+json"   # historical Forem v1 Accept value (unverified in the current spec)


# ------------------------------------------------------------------ text

def changelog_section(text, version):
    """The lines under `## <version>` (heading may continue: `## 0.3.2 — 2026-10-10`), up to the
    next `## `, trimmed. Raises ValueError when the section is missing or empty."""
    lines, inside = [], False
    head = re.compile(r"^## " + re.escape(version) + r"(\s|$)")
    for line in text.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = bool(head.match(line))
            continue
        if inside:
            lines.append(line)
    section = "\n".join(lines).strip()
    if not section:
        raise ValueError(f'no "## {version}" section in the changelog')
    return section


def summary(section):
    return next(line.strip() for line in section.splitlines() if line.strip())


def marker(version):
    return f"Markdown Editor {version}"


def already_posted(texts, version):
    pattern = re.compile(re.escape(marker(version)) + r"(?![\d.]*\d)")
    return any(pattern.search(t or "") for t in texts)


def fit(text, limit):
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def bluesky_text(version, section):
    tail = f"\n{SITE}\nAutomated post"
    head = f"{marker(version)}: "
    return head + fit(summary(section), BLUESKY_MAX - len(head) - len(tail)) + tail


def link_facet(text, url):
    """A Bluesky link facet over the last occurrence of url (the trailing site link, even when the
    summary itself contains a URL starting with it), in UTF-8 byte offsets."""
    raw = text.encode("utf-8")
    start = raw.rfind(url.encode("utf-8"))
    if start < 0:
        raise ValueError("url not in text")
    return {"index": {"byteStart": start, "byteEnd": start + len(url.encode("utf-8"))},
            "features": [{"$type": "app.bsky.richtext.facet#link", "uri": url}]}


def mastodon_text(version, section):
    head = f"{marker(version)}\n\n"
    tail = f"\n\n{SITE}\n\nPosted automatically from the project changelog."
    return head + fit(section, MASTODON_MAX - len(head) - len(tail)) + tail


def dev_article(version, section, published):
    body = (f"{section}\n\n"
            f"Install on a Mac (Apple Silicon, macOS 15+):\n\n```sh\n{INSTALL}\n```\n\n"
            f"Or download it from {SITE}\n\n"
            "*This post was generated automatically from the project's changelog, which may be AI-written.*\n")
    # No canonical_url: Forem requires it to be unique among all published articles, so a fixed
    # site URL would make every release after the first fail with HTTP 422.
    return {"article": {
        "title": fit(f"{marker(version)}: {summary(section)}", DEV_TITLE_MAX),
        "body_markdown": body,
        "published": published,
        "tags": DEV_TAGS,
        "ai_disclosure_level": "fully_autonomous",
    }}


# ------------------------------------------------------------------ requests

class Request:
    def __init__(self, method, url, headers=None, json_body=None, form=None):
        self.method, self.url = method, url
        self.headers = dict(headers or {})
        self.json_body, self.form = json_body, form

    def data(self):
        if self.json_body is not None:
            return json.dumps(self.json_body).encode("utf-8"), "application/json"
        if self.form is not None:
            return urllib.parse.urlencode(self.form).encode("utf-8"), "application/x-www-form-urlencoded"
        return None, None

    def describe(self, secrets):
        lines = [f"{self.method} {self.url}"]
        for k, v in self.headers.items():
            lines.append(f"  {k}: {'<redacted>' if k.lower() in SECRET_HEADERS else v}")
        body = self.json_body if self.json_body is not None else self.form
        if body is not None:
            text = json.dumps(body, indent=2, ensure_ascii=False)
            for s in secrets:
                if s:
                    text = text.replace(s, "<redacted>")
            lines.append("  " + text.replace("\n", "\n  "))
        return "\n".join(lines)


def urllib_send(req):
    """The only function that touches the network; called only with --live."""
    data, ctype = req.data()
    r = urllib.request.Request(req.url, data=data, method=req.method,
                               headers={**req.headers, **({"Content-Type": ctype} if ctype else {}),
                                        "User-Agent": "markdown-editor-release-bot"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{req.method} {req.url} -> HTTP {e.code}: {e.read()[:300]!r}") from None
    return json.loads(raw) if raw else {}


# ------------------------------------------------------------------ platforms
# Each returns the request sequence. `send` is None for a dry run (placeholders stand in for values
# that only a live response provides), else it is called step by step.

def run_bluesky(env, version, section, send):
    pds = (env.get("BLUESKY_PDS") or "https://bsky.social").rstrip("/")
    login = Request("POST", f"{pds}/xrpc/com.atproto.server.createSession",
                    json_body={"identifier": env.get("BLUESKY_HANDLE", "<BLUESKY_HANDLE>"),
                               "password": env.get("BLUESKY_APP_PASSWORD", "<BLUESKY_APP_PASSWORD>")})
    session = send(login) if send else {"accessJwt": "<accessJwt>", "did": "<did>"}
    auth = {"Authorization": f"Bearer {session['accessJwt']}"}
    # The account's own repo on its PDS, newest first: unlike the AppView's getAuthorFeed it has no
    # indexing lag, so a re-run right after a timed-out createRecord still sees the post.
    recent_req = Request("GET", f"{pds}/xrpc/com.atproto.repo.listRecords?"
                         + urllib.parse.urlencode({"repo": session["did"], "collection": "app.bsky.feed.post",
                                                   "limit": 30}), auth)
    steps = [login, recent_req]
    if send:
        recent = send(recent_req)
        texts = [r.get("value", {}).get("text", "") for r in recent.get("records", [])]
        if already_posted(texts, version):
            return steps, "already posted"
    text = bluesky_text(version, section)
    record = {"$type": "app.bsky.feed.post", "text": text,
              "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
              "facets": [link_facet(text, SITE)], "langs": ["en"]}
    post = Request("POST", f"{pds}/xrpc/com.atproto.repo.createRecord", auth,
                   json_body={"repo": session["did"], "collection": "app.bsky.feed.post", "record": record})
    steps.append(post)
    if send:
        send(post)
    return steps, "posted"


def run_mastodon(env, version, section, send):
    base = (env.get("MASTODON_INSTANCE") or "<MASTODON_INSTANCE>").rstrip("/")
    auth = {"Authorization": f"Bearer {env.get('MASTODON_TOKEN', '<MASTODON_TOKEN>')}"}
    me_req = Request("GET", f"{base}/api/v1/accounts/verify_credentials", auth)
    me = send(me_req) if send else {"id": "<account id>"}
    recent_req = Request("GET", f"{base}/api/v1/accounts/{me['id']}/statuses?limit=40&exclude_replies=true", auth)
    steps = [me_req, recent_req]
    if send:
        recent = send(recent_req)
        if already_posted([s.get("content", "") for s in recent], version):
            return steps, "already posted"
    post = Request("POST", f"{base}/api/v1/statuses",
                   {**auth, "Idempotency-Key": f"{version}-mastodon"},   # second guard; kept 1 h by the server
                   form={"status": mastodon_text(version, section), "visibility": "public", "language": "en"})
    steps.append(post)
    if send:
        send(post)
    return steps, "posted"


def run_dev(env, version, section, send, published):
    auth = {"api-key": env.get("DEV_API_KEY", "<DEV_API_KEY>"), "Accept": DEV_ACCEPT}
    mine_req = Request("GET", "https://dev.to/api/articles/me/all?per_page=30", auth)
    steps = [mine_req]
    if send:
        mine = send(mine_req)
        if already_posted([a.get("title", "") for a in mine], version):
            return steps, "already posted"
    post = Request("POST", "https://dev.to/api/articles", auth, json_body=dev_article(version, section, published))
    steps.append(post)
    if send:
        created = send(post)
        # Forem accepts ai_disclosure_level only while its enable_ai_disclosure setting is on, and
        # silently drops it otherwise; the tag and the closing line still disclose. Say so.
        if isinstance(created, dict) and created.get("ai_disclosure_level") != "fully_autonomous":
            return steps, ("posted — WARNING: DEV did not record ai_disclosure_level=fully_autonomous; "
                           "the #abotwrotethis tag and the closing line are the disclosure")
    return steps, "posted"


# ------------------------------------------------------------------ main

def main(argv=None, env=None, send=None, out=None):
    out = out or sys.stdout
    env = dict(os.environ if env is None else env)
    env = {k: v for k, v in env.items() if v}   # an empty secret counts as unset
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--version", required=True)
    p.add_argument("--changelog", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "CHANGELOG.md"))
    p.add_argument("--live", action="store_true", help="actually post (default: dry run, nothing sent)")
    p.add_argument("--only", default=",".join(DEFAULT_PLATFORMS),
                   help=f"comma list of {','.join(PLATFORMS)} (default {','.join(DEFAULT_PLATFORMS)})")
    a = p.parse_args(argv)

    chosen = [x.strip() for x in a.only.split(",") if x.strip()]
    unknown = [x for x in chosen if x not in PLATFORMS]
    if unknown:
        p.error(f"unknown platform(s): {', '.join(unknown)}")
    try:
        with open(a.changelog, encoding="utf-8") as f:
            section = changelog_section(f.read(), a.version)
    except (OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    secrets = [env.get(v) for names in SECRETS.values() for v in names]
    failed = False
    print(f"{'LIVE' if a.live else 'DRY RUN (nothing is sent; pass --live to post)'}: {marker(a.version)}", file=out)
    for name in chosen:
        missing = [v for v in SECRETS[name] if v not in env]
        print(f"\n== {name}", file=out)
        if a.live and missing:
            print(f"skipped — {', '.join(missing)} not set", file=out)
            continue
        live_send = (send or urllib_send) if a.live else None
        try:
            if name == "bluesky":
                steps, result = run_bluesky(env, a.version, section, live_send)
            elif name == "mastodon":
                steps, result = run_mastodon(env, a.version, section, live_send)
            else:
                steps, result = run_dev(env, a.version, section, live_send, published=a.live)
        except Exception as e:   # one platform failing must not hide the others
            print(f"FAILED — {e}", file=out)
            failed = True
            continue
        if a.live:
            print(result, file=out)
        else:
            for step in steps:
                print(step.describe(secrets), file=out)
            if missing:
                print(f"(with --live this would be skipped — {', '.join(missing)} not set)", file=out)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
