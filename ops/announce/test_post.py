"""Tests for post.py. Run: python3 -m unittest discover -s ops/announce -p 'test_*.py'

Every test runs with the network patched to raise, so "the dry run sends nothing" is an assertion.
"""
import http.client
import io
import os
import socket
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import post  # noqa: E402

CHANGELOG = """# Changelog

## 0.3.20 — 2026-12-01

Later release.

## 0.3.2 — 2026-10-10

New app icon — and a restyled download page.

- First bullet.
- Second bullet.

## 0.3.1 — 2026-10-10

Faster tables.
"""
SECRETS = {"BLUESKY_HANDLE": "bot.example", "BLUESKY_APP_PASSWORD": "pw-sekrit-1",
           "MASTODON_INSTANCE": "https://mastodon.example", "MASTODON_TOKEN": "tok-sekrit-2",
           "DEV_API_KEY": "key-sekrit-3"}


def no_network(*args, **kwargs):
    raise AssertionError("network access attempted")


class NoNetwork(unittest.TestCase):
    def setUp(self):
        patches = [mock.patch("urllib.request.urlopen", no_network),
                   mock.patch.object(http.client.HTTPSConnection, "connect", no_network),
                   mock.patch.object(http.client.HTTPConnection, "connect", no_network),
                   mock.patch.object(socket, "create_connection", no_network)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".build", "announce-test")
        os.makedirs(self.dir, exist_ok=True)
        self.changelog = os.path.join(self.dir, "CHANGELOG.md")
        with open(self.changelog, "w", encoding="utf-8") as f:
            f.write(CHANGELOG)

    def run_main(self, args, env, send=None):
        out = io.StringIO()
        code = post.main(["--changelog", self.changelog] + args, env=env, send=send, out=out)
        return code, out.getvalue()


class TextTests(NoNetwork):
    def test_section_with_em_dash_heading(self):
        s = post.changelog_section(CHANGELOG, "0.3.2")
        self.assertTrue(s.startswith("New app icon"))
        self.assertTrue(s.endswith("- Second bullet."))
        self.assertNotIn("Faster tables", s)

    def test_section_is_exact_version(self):
        self.assertEqual(post.changelog_section(CHANGELOG, "0.3.20"), "Later release.")
        with self.assertRaises(ValueError):
            post.changelog_section(CHANGELOG, "0.3")
        with self.assertRaises(ValueError):
            post.changelog_section(CHANGELOG, "9.9.9")

    def test_real_changelog_has_current_version(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
        with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(post.changelog_section(text, "0.3.2"))

    def test_facet_uses_utf8_byte_offsets(self):
        text = post.bluesky_text("0.3.2", post.changelog_section(CHANGELOG, "0.3.2"))
        self.assertIn("—", text)   # the em dash before the link is 3 bytes in UTF-8
        facet = post.link_facet(text, post.SITE)
        raw = text.encode("utf-8")
        self.assertEqual(raw[facet["index"]["byteStart"]:facet["index"]["byteEnd"]].decode("utf-8"), post.SITE)
        self.assertNotEqual(facet["index"]["byteStart"], text.find(post.SITE), "byte offset differs from char offset")

    def test_length_limits(self):
        long = "Word " * 400
        self.assertLessEqual(len(post.bluesky_text("0.3.2", long)), post.BLUESKY_MAX)
        self.assertTrue(post.bluesky_text("0.3.2", long).endswith("Automated post"))
        self.assertLessEqual(len(post.mastodon_text("0.3.2", long)), post.MASTODON_MAX)
        self.assertLessEqual(len(post.bluesky_text("0.3.2", "Short.").encode("utf-8")), 3000)

    def test_already_posted_matches_exact_version(self):
        self.assertTrue(post.already_posted(["Markdown Editor 0.3.2: New icon"], "0.3.2"))
        self.assertTrue(post.already_posted(["<p>Markdown Editor 0.3.2</p>"], "0.3.2"))
        self.assertFalse(post.already_posted(["Markdown Editor 0.3.20: later"], "0.3.2"))
        self.assertFalse(post.already_posted(["Markdown Editor 0.3.2.1"], "0.3.2"))
        self.assertFalse(post.already_posted([], "0.3.2"))

    def test_dev_article_disclosure(self):
        art = post.dev_article("0.3.2", "Summary.\n\n- x", published=True)["article"]
        self.assertIn("abotwrotethis", art["tags"])
        self.assertLessEqual(len(art["tags"]), 4)
        self.assertEqual(art["ai_disclosure_level"], "fully_autonomous")
        self.assertNotIn("canonical_url", art)   # Forem: unique across published articles
        self.assertNotIn("human-written", art["body_markdown"])

    def test_dev_title_fits_forem_limit(self):
        art = post.dev_article("0.3.2", "word " * 60, published=True)["article"]
        self.assertLessEqual(len(art["title"]), post.DEV_TITLE_MAX)
        self.assertTrue(art["title"].startswith("Markdown Editor 0.3.2: "))


class FacetTests(unittest.TestCase):
    def test_facet_covers_the_trailing_site_link(self):
        text = post.bluesky_text("0.3.2", "Fixed https://markdown.chri5tian.com/install.sh — café ✓")
        facet = post.link_facet(text, post.SITE)["index"]
        raw = text.encode("utf-8")
        self.assertEqual(raw[facet["byteStart"]:facet["byteEnd"]].decode("utf-8"), post.SITE)
        self.assertTrue(raw[facet["byteEnd"]:].decode("utf-8").startswith("\nAutomated post"))


class DryRunTests(NoNetwork):
    def test_dry_run_prints_three_platforms_and_sends_nothing(self):
        code, out = self.run_main(["--version", "0.3.2", "--only", "bluesky,mastodon,dev"], env=SECRETS)
        self.assertEqual(code, 0)
        self.assertIn("DRY RUN", out)
        for host in ("bsky.social/xrpc/com.atproto.repo.createRecord", "mastodon.example/api/v1/statuses",
                     "dev.to/api/articles"):
            self.assertIn(host, out)
        for secret in ("pw-sekrit-1", "tok-sekrit-2", "key-sekrit-3"):
            self.assertNotIn(secret, out, "secrets are redacted")
        self.assertIn("<redacted>", out)
        self.assertIn("Idempotency-Key: 0.3.2-mastodon", out)

    def test_dry_run_without_secrets_says_what_would_skip(self):
        code, out = self.run_main(["--version", "0.3.2", "--only", "bluesky,mastodon,dev"], env={})
        self.assertEqual(code, 0)
        self.assertEqual(out.count("with --live this would be skipped"), 3)

    def test_live_without_secrets_skips_everything(self):
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "bluesky,mastodon,dev"], env={})
        self.assertEqual(code, 0)
        self.assertEqual(out.count("skipped —"), 3)

    def test_empty_secret_counts_as_unset(self):
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "dev"], env={"DEV_API_KEY": ""})
        self.assertIn("skipped — DEV_API_KEY not set", out)

    def test_mastodon_is_off_unless_named(self):
        code, out = self.run_main(["--version", "0.3.2"], env=SECRETS)
        self.assertEqual(code, 0)
        self.assertNotIn("== mastodon", out)
        self.assertNotIn("mastodon.example", out)
        self.assertIn("== bluesky", out)
        self.assertIn("== dev", out)

    def test_missing_section_fails(self):
        code, _ = self.run_main(["--version", "9.9.9"], env={})
        self.assertEqual(code, 1)


class LiveWithStubTests(NoNetwork):
    """--live with an injected send: proves the request order and the already-posted guard."""

    def stub(self, posted_before):
        calls = []

        def send(req):
            calls.append((req.method, req.url))
            if "createSession" in req.url:
                return {"accessJwt": "jwt", "did": "did:plc:x"}
            if "com.atproto.repo.listRecords" in req.url:
                text = "Markdown Editor 0.3.2: New app icon" if posted_before else "Markdown Editor 0.3.1: old"
                return {"records": [{"uri": "at://did:plc:x/app.bsky.feed.post/1", "value": {"text": text}}]}
            if "verify_credentials" in req.url:
                return {"id": "42"}
            if "/accounts/42/statuses" in req.url:
                return [{"content": "<p>Markdown Editor 0.3.2</p>" if posted_before else "<p>hi</p>"}]
            if req.url.startswith("https://dev.to/api/articles/me"):
                return [{"title": "Markdown Editor 0.3.2: x" if posted_before else "other"}]
            if req.url == "https://dev.to/api/articles":
                return {"id": 1, "ai_disclosure_level": "fully_autonomous"}
            return {}
        return send, calls

    def test_posts_when_not_posted_before(self):
        send, calls = self.stub(posted_before=False)
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "bluesky,mastodon,dev"], env=SECRETS, send=send)
        self.assertEqual(code, 0)
        posts = [c for c in calls if c[0] == "POST" and "createSession" not in c[1]]
        self.assertEqual([u for _, u in posts], ["https://bsky.social/xrpc/com.atproto.repo.createRecord",
                                                 "https://mastodon.example/api/v1/statuses",
                                                 "https://dev.to/api/articles"])
        self.assertEqual(out.count("posted"), 3)

    def test_skips_when_already_posted(self):
        send, calls = self.stub(posted_before=True)
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "bluesky,mastodon,dev"], env=SECRETS, send=send)
        self.assertEqual(code, 0)
        self.assertEqual(out.count("already posted"), 3)
        self.assertFalse([c for c in calls if c[0] == "POST" and "createSession" not in c[1]])

    def test_dev_warns_when_disclosure_level_is_dropped(self):
        base = self.stub(False)[0]

        def send(req):
            if req.url == "https://dev.to/api/articles":
                return {"id": 1}
            return base(req)
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "dev"], env=SECRETS, send=send)
        self.assertEqual(code, 0)
        self.assertIn("WARNING: DEV did not record ai_disclosure_level", out)

    def test_one_failure_does_not_stop_the_others(self):
        def send(req):
            if "bsky" in req.url:
                raise RuntimeError("HTTP 401")
            return self.stub(False)[0](req)
        code, out = self.run_main(["--version", "0.3.2", "--live", "--only", "bluesky,dev"], env=SECRETS, send=send)
        self.assertEqual(code, 1)
        self.assertIn("FAILED — HTTP 401", out)
        self.assertIn("posted", out.split("== dev")[1])


if __name__ == "__main__":
    unittest.main()
