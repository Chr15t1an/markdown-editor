#!/usr/bin/env python3
"""Weekly metrics: GitHub stars and traffic, stored as one JSON line per run.

    python3 ops/metrics/collect.py --dry-run     print what would be fetched; no network, no file written
    python3 ops/metrics/collect.py               fetch (read-only GETs) and append to ops/metrics/data/github.jsonl

GitHub keeps traffic (views, clones, referrers) for 14 days only, so it has to be stored weekly.
- Repo stars / forks / watchers: anonymous GET; while the repo is private this is a 404 and the
  run says "not public yet".
- Traffic: needs GH_TRAFFIC_TOKEN (a token with push access to the repo; ops/README.md).
- Also prints the distance to Homebrew's notability gate (75 stars; 225 when the author submits
  the cask), so the gate stays visible even though the official cask is out of reach at $0.
- Search Console, Bing Webmaster and Cloudflare analytics are stubs that say "not configured"
  until their variables exist (setup in ops/README.md § Metrics); their collectors are not built yet.

Read-only: every request is a GET. Standard library only.
"""
import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

REPO = "Chr15t1an/markdown-editor"
API = "https://api.github.com"
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "github.jsonl")
GATES = (75, 225)
STUBS = {
    "Search Console": ("SEARCH_CONSOLE_CREDENTIALS", "SEARCH_CONSOLE_SITE"),
    "Bing Webmaster": ("BING_WEBMASTER_API_KEY",),
    "Cloudflare analytics": ("CLOUDFLARE_ANALYTICS_TOKEN", "CLOUDFLARE_ZONE_ID"),
}


class NotFound(Exception):
    pass


def http_get(url, token=None):
    """The only network call. Returns parsed JSON; raises NotFound on 404."""
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "markdown-editor-metrics",
               "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NotFound(url) from None
        raise


def collect(env, get, out, dry_run=False):
    """Returns the record to store (None when nothing was collected)."""
    token = env.get("GH_TRAFFIC_TOKEN") or None
    record = {"date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "repo": REPO}
    repo_url = f"{API}/repos/{REPO}"
    traffic = [("views", f"{repo_url}/traffic/views"), ("clones", f"{repo_url}/traffic/clones"),
               ("referrers", f"{repo_url}/traffic/popular/referrers")]

    if dry_run:
        print(f"would GET {repo_url} (anonymous)", file=out)
        for _, url in traffic:
            print(f"would GET {url} " + ("(GH_TRAFFIC_TOKEN)" if token else "— skipped, GH_TRAFFIC_TOKEN not set"), file=out)
        print(f"would append one line to {DATA}", file=out)
    else:
        try:
            repo = get(repo_url, None)
        except NotFound:
            print(f"GitHub: {REPO} not public yet (404) — stars, forks and traffic skipped", file=out)
            repo = None
        if repo is not None:
            record.update(stars=repo.get("stargazers_count"), forks=repo.get("forks_count"),
                          watchers=repo.get("subscribers_count"))
            stars = record["stars"] or 0
            print(f"GitHub: {stars} stars, {record['forks']} forks, {record['watchers']} watchers", file=out)
            print("Homebrew notability gate: " + ", ".join(
                f"{max(g - stars, 0)} stars to {g}" for g in GATES), file=out)
            if token:
                for key, url in traffic:
                    record[key] = get(url, token)
                print(f"GitHub traffic: {record['views'].get('count')} views, {record['clones'].get('count')} clones (14 days)", file=out)
            else:
                print("GitHub traffic: skipped — GH_TRAFFIC_TOKEN not set", file=out)

    for name, names in STUBS.items():
        missing = [n for n in names if not env.get(n)]
        if missing:
            print(f"{name}: not configured — set {', '.join(missing)} (ops/README.md § Metrics)", file=out)
        else:
            print(f"{name}: configured, but its collector is not built yet (ops/README.md § Metrics)", file=out)
    return None if dry_run or "stars" not in record else record


def main(argv=None, env=None, get=None, out=None, data_path=DATA):
    out = out or sys.stdout
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dry-run", action="store_true", help="print the requests; no network, no file")
    a = p.parse_args(argv)
    env = dict(os.environ if env is None else env)
    try:
        record = collect(env, get or http_get, out, dry_run=a.dry_run)
    except Exception as e:   # a read failed: say so, store nothing
        print(f"error: {e}", file=sys.stderr)
        return 1
    if record is not None:
        os.makedirs(os.path.dirname(data_path), exist_ok=True)
        with open(data_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, sort_keys=True) + "\n")
        print(f"appended to {data_path}", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
