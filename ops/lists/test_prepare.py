"""Tests for prepare.py. Run: python3 -m unittest discover -s ops/lists -p 'test_*.py'

The network is patched to raise in every test: preparing a PR must never need to send anything.
"""
import http.client
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prepare  # noqa: E402

LIST_MD = """# Awesome

## Editors

### Markdown Tools

* [Archimedes](https://a.example) - A.
* [MacDown](https://m.example) - M.
* [Marked 2](https://k.example) - K.

### Note-taking

* [Bear](https://b.example) - B.
"""
APPS_JSON = json.dumps({"applications": [{"title": "A", "repo_url": "https://github.com/x/a"}]}, indent=4)
TARGET = {
    "repo": "someone/awesome", "branch": "master", "pr_title": "Add", "pr_body": "Body.",
    "edits": [
        {"file": "README.md", "section": "### Markdown Tools", "placement": "alphabetical",
         "entry": "* [Markdown Editor](https://markdown.chri5tian.com/) - Native editor."},
        {"file": "applications.json", "json_append": {"title": "Markdown Editor",
                                                      "repo_url": "https://github.com/Chr15t1an/markdown-editor"}},
    ],
}
APP = {"repo_url": "https://github.com/Chr15t1an/markdown-editor"}


def no_network(*a, **k):
    raise AssertionError("network access attempted")


class PrepareTests(unittest.TestCase):
    def setUp(self):
        for p in (mock.patch("urllib.request.urlopen", no_network),
                  mock.patch.object(http.client.HTTPSConnection, "connect", no_network),
                  mock.patch.object(socket, "create_connection", no_network)):
            p.start()
            self.addCleanup(p.stop)
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.files = {"README.md": LIST_MD, "applications.json": APPS_JSON}

    def read(self, path):
        return self.files[path]

    def test_alphabetical_insert(self):
        new = prepare.insert_entry(LIST_MD, "### Markdown Tools", TARGET["edits"][0]["entry"], "alphabetical")
        lines = new.split("\n")
        i = lines.index(TARGET["edits"][0]["entry"])
        self.assertTrue(lines[i - 1].startswith("* [MacDown]"))
        self.assertTrue(lines[i + 1].startswith("* [Marked 2]"))
        self.assertIn("* [Bear]", new, "other sections untouched")

    def test_end_insert_with_block(self):
        new = prepare.insert_entry(LIST_MD, "### Markdown Tools", "**X**\ntext", "end", block=True)
        self.assertIn("* [Marked 2](https://k.example) - K.\n\n**X**\ntext\n\n### Note-taking", new)

    def test_heading_must_be_unique(self):
        with self.assertRaises(ValueError):
            prepare.insert_entry(LIST_MD, "### Missing", "* [X](y) - z.", "alphabetical")

    def test_json_append_keeps_format(self):
        new = prepare.append_json(APPS_JSON, {"title": "Markdown Editor"})
        self.assertEqual(json.loads(new)["applications"][-1], {"title": "Markdown Editor"})
        self.assertEqual(new, json.dumps(json.loads(new), indent=4))
        with self.assertRaises(ValueError):
            prepare.append_json(json.dumps({"applications": []}), {})   # not indent=4: refuse to reformat

    def test_prepare_writes_three_files_and_patch_applies(self):
        out = os.path.join(self.tmp, "out")
        notes, patched = prepare.prepare(TARGET, APP, out, self.read)
        self.assertTrue(patched)
        self.assertEqual(sorted(os.listdir(out)), ["entry.md", "patch.diff", "pr-body.md"])
        repo = os.path.join(self.tmp, "clone")
        os.makedirs(repo)
        for name, text in self.files.items():
            with open(os.path.join(repo, name), "w", encoding="utf-8") as f:
                f.write(text)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "apply", os.path.join(out, "patch.diff")], cwd=repo, check=True)
        with open(os.path.join(repo, "README.md"), encoding="utf-8") as f:
            self.assertIn("[Markdown Editor]", f.read())
        with open(os.path.join(repo, "applications.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["applications"][-1]["title"], "Markdown Editor")

    def test_already_listed_gets_no_patch(self):
        self.files["README.md"] = LIST_MD + "\n* [Markdown Editor](https://github.com/Chr15t1an/markdown-editor) - x.\n"
        self.files["applications.json"] = json.dumps(
            {"applications": [{"repo_url": "https://github.com/Chr15t1an/markdown-editor"}]}, indent=4)
        notes, patched = prepare.prepare(TARGET, APP, os.path.join(self.tmp, "out"), self.read)
        self.assertFalse(patched)
        self.assertEqual(len(notes), 2)

    def test_offline_writes_entries_without_patch(self):
        out = os.path.join(self.tmp, "out")
        notes, patched = prepare.prepare(TARGET, APP, out, None)
        self.assertFalse(patched)
        self.assertEqual(sorted(os.listdir(out)), ["entry.md", "pr-body.md"])

    def test_real_lists_json_offline_covers_five_lists(self):
        buf = io.StringIO()
        code = prepare.main(["--offline", "--out", os.path.join(self.tmp, "out")], out=buf)
        self.assertEqual(code, 0)
        self.assertEqual(len(os.listdir(os.path.join(self.tmp, "out"))), 5)
        with open(os.path.join(os.path.dirname(prepare.__file__), "lists.json"), encoding="utf-8") as f:
            config = json.load(f)
        repos = {t["repo"] for t in config["targets"]}
        self.assertEqual(repos, {"jaywcjlove/awesome-swift-macos-apps", "jaywcjlove/awesome-mac",
                                 "serhii-londar/open-source-mac-os-apps", "iCHAIT/awesome-macOS",
                                 "mundimark/awesome-markdown-editors"})
        for t in config["targets"]:
            for e in t["edits"]:
                if "entry" in e:
                    self.assertNotIn("clone", e["entry"].lower())
                    desc = e["entry"].split(" - ", 1)[-1].split(" [![")[0].rstrip()
                    self.assertTrue(desc.endswith((".", "。")), f"{t['repo']} {e['file']}: description ends with a full stop")

    def test_no_script_path_opens_a_pr(self):
        with open(prepare.__file__, encoding="utf-8") as f:
            src = f.read()
        for word in ("/pulls", "/forks", "git push", "gh pr create"):
            self.assertNotIn(word, src.split('"""', 2)[2], f"prepare.py must not contain {word!r}")


if __name__ == "__main__":
    unittest.main()
