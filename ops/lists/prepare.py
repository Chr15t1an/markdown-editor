#!/usr/bin/env python3
"""Prepare (never open) one curated-list pull request per target in lists.json.

    python3 ops/lists/prepare.py                       fetch each list's current file (read-only GET) and write
                                                       out/<owner>__<repo>/{entry.md, pr-body.md, patch.diff}
    python3 ops/lists/prepare.py --offline             entries and PR bodies only, no fetch, no patch.diff
    python3 ops/lists/prepare.py --source-dir DIR      read the files from DIR/<owner>__<repo>/<file> instead of fetching
    python3 ops/lists/prepare.py --only jaywcjlove/awesome-mac

The script sends nothing anywhere and never forks, pushes or opens a PR. Opening the PRs is a
person's (or a supervised agent's) step with the `gh` commands in ops/lists/README.md, once.

patch.diff applies with `git apply` (or `patch -p1`) at the root of a fresh clone of the list.
If the app is already listed in a file, that file gets no patch and the run says so.
"""
import argparse
import difflib
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ITEM = re.compile(r"^[-*] \[([^\]]+)\]")


def slug(repo):
    return repo.replace("/", "__")


def fetch(repo, branch, path):
    url = f"https://raw.githubusercontent.com/{repo}/{branch}/{path}"
    req = urllib.request.Request(url, headers={"User-Agent": "markdown-editor-lists-prep"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def section_bounds(lines, heading):
    """(start, end): start = index of the heading line, end = index of the next heading of the
    same or a higher level (or len(lines)). The heading must match exactly one line."""
    level = len(heading) - len(heading.lstrip("#"))
    hits = [i for i, l in enumerate(lines) if l == heading or l.startswith(heading + " ")]
    if len(hits) != 1:
        raise ValueError(f"heading {heading!r} matched {len(hits)} lines")
    start = hits[0]
    for j in range(start + 1, len(lines)):
        m = re.match(r"^(#+) ", lines[j])
        if m and len(m.group(1)) <= level:
            return start, j
    return start, len(lines)


def insert_entry(text, section, entry, placement, block=False):
    lines = text.split("\n")
    start, end = section_bounds(lines, section)
    entry_lines = entry.split("\n")
    if placement == "alphabetical":
        name = ITEM.match(entry_lines[0]).group(1).lower()
        items = [i for i in range(start + 1, end) if ITEM.match(lines[i])]
        if not items:
            raise ValueError(f"no list items under {section!r}")
        at = next((i for i in items if ITEM.match(lines[i]).group(1).lower() > name), items[-1] + 1)
        lines[at:at] = entry_lines
    elif placement == "end":
        last = max(i for i in range(start, end) if lines[i].strip())
        lines[last + 1:last + 1] = ([""] if block else []) + entry_lines
    else:
        raise ValueError(f"unknown placement {placement!r}")
    return "\n".join(lines)


def append_json(text, obj):
    """Append obj to the "applications" array, keeping the file's own formatting (4-space indent,
    ASCII escapes, no trailing newline — checked by round-tripping before editing)."""
    data = json.loads(text)
    trailing = text[len(text.rstrip("\n")):]
    if json.dumps(data, indent=4, ensure_ascii=True) != text.rstrip("\n"):
        raise ValueError("applications.json formatting differs from json.dumps(indent=4); edit by hand")
    data["applications"].append(obj)
    return json.dumps(data, indent=4, ensure_ascii=True) + trailing


def entry_text(edit):
    return json.dumps(edit["json_append"], indent=4, ensure_ascii=False) if "json_append" in edit else edit["entry"]


def prepare(target, app, out_dir, read=None):
    """Write the target's files; `read(file)` returns the list's current file, or None for offline."""
    os.makedirs(out_dir, exist_ok=True)
    notes, diffs = [], []
    entries = []
    for edit in target["edits"]:
        entries.append(f"### {edit['file']}\n\n{entry_text(edit)}\n")
        if read is None:
            continue
        old = read(edit["file"])
        if app["repo_url"].lower() in old.lower():
            notes.append(f"{edit['file']}: already lists {app['repo_url']}; no change")
            continue
        if "json_append" in edit:
            new = append_json(old, edit["json_append"])
        else:
            new = insert_entry(old, edit["section"], edit["entry"], edit["placement"], edit.get("block", False))
        for line in difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True),
                                         f"a/{edit['file']}", f"b/{edit['file']}"):
            diffs.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    with open(os.path.join(out_dir, "entry.md"), "w", encoding="utf-8") as f:
        f.write(f"# {target['repo']}\n\n" + "\n".join(entries))
    with open(os.path.join(out_dir, "pr-body.md"), "w", encoding="utf-8") as f:
        f.write(target["pr_body"] + "\n")
    patch = os.path.join(out_dir, "patch.diff")
    if read is not None and diffs:
        with open(patch, "w", encoding="utf-8") as f:
            f.writelines(diffs)
    elif os.path.exists(patch):
        os.remove(patch)
    return notes, bool(diffs)


def main(argv=None, out=None):
    out = out or sys.stdout
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--lists", default=os.path.join(HERE, "lists.json"))
    p.add_argument("--out", default=os.path.join(HERE, "out"))
    p.add_argument("--offline", action="store_true", help="no fetch, no patch.diff")
    p.add_argument("--source-dir", help="read list files from DIR/<owner>__<repo>/<file>")
    p.add_argument("--only", help="comma list of owner/repo")
    a = p.parse_args(argv)

    with open(a.lists, encoding="utf-8") as f:
        config = json.load(f)
    targets = config["targets"]
    if a.only:
        wanted = {x.strip() for x in a.only.split(",")}
        targets = [t for t in targets if t["repo"] in wanted]
        if not targets:
            p.error(f"no target named {a.only}")

    failed = False
    for t in targets:
        folder = os.path.join(a.out, slug(t["repo"]))
        if a.offline:
            read = None
        elif a.source_dir:
            read = lambda path, t=t: open(os.path.join(a.source_dir, slug(t["repo"]), path), encoding="utf-8").read()
        else:
            read = lambda path, t=t: fetch(t["repo"], t["branch"], path)
        try:
            notes, patched = prepare(t, config["app"], folder, read)
        except Exception as e:   # one list failing must not hide the others
            print(f"{t['repo']}: FAILED — {e}", file=out)
            failed = True
            continue
        status = "patch.diff written" if patched else ("no patch (offline)" if read is None else "no patch")
        print(f"{t['repo']}: {folder} — entry.md, pr-body.md, {status}", file=out)
        for n in notes:
            print(f"  {n}", file=out)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
