"""Tests for collect.py. Run: python3 -m unittest discover -s ops/metrics -p 'test_*.py'

The network is patched to raise; the 404 and 200 branches use a stubbed `get`.
"""
import http.client
import io
import json
import os
import shutil
import socket
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect  # noqa: E402


def no_network(*a, **k):
    raise AssertionError("network access attempted")


class CollectTests(unittest.TestCase):
    def setUp(self):
        for p in (mock.patch("urllib.request.urlopen", no_network),
                  mock.patch.object(http.client.HTTPSConnection, "connect", no_network),
                  mock.patch.object(socket, "create_connection", no_network)):
            p.start()
            self.addCleanup(p.stop)
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.data = os.path.join(self.tmp, "data", "github.jsonl")

    def run_main(self, args, env, get=None):
        out = io.StringIO()
        code = collect.main(args, env=env, get=get, out=out, data_path=self.data)
        return code, out.getvalue()

    def test_dry_run_is_offline_and_writes_nothing(self):
        code, out = self.run_main(["--dry-run"], env={})
        self.assertEqual(code, 0)
        self.assertIn("would GET https://api.github.com/repos/Chr15t1an/markdown-editor", out)
        self.assertEqual(out.count("not configured"), 3)
        self.assertFalse(os.path.exists(self.data))

    def test_private_repo_404_skips_and_stores_nothing(self):
        def get(url, token):
            raise collect.NotFound(url)
        code, out = self.run_main([], env={}, get=get)
        self.assertEqual(code, 0)
        self.assertIn("not public yet (404)", out)
        self.assertFalse(os.path.exists(self.data))

    def test_public_repo_stores_stars_and_gate_distance(self):
        calls = []

        def get(url, token):
            calls.append((url, token))
            return {"stargazers_count": 80, "forks_count": 3, "subscribers_count": 2}
        code, out = self.run_main([], env={}, get=get)
        self.assertEqual(code, 0)
        self.assertIn("0 stars to 75, 145 stars to 225", out)
        self.assertIn("GH_TRAFFIC_TOKEN not set", out)
        self.assertEqual(len(calls), 1, "no traffic calls without a token")
        with open(self.data, encoding="utf-8") as f:
            rec = json.loads(f.read().strip())
        self.assertEqual((rec["stars"], rec["forks"], rec["watchers"]), (80, 3, 2))

    def test_traffic_with_token(self):
        def get(url, token):
            if url.endswith("/traffic/views") or url.endswith("/traffic/clones"):
                self.assertEqual(token, "t0k")
                return {"count": 5, "uniques": 2}
            if url.endswith("/referrers"):
                return [{"referrer": "github.com", "count": 1}]
            return {"stargazers_count": 1, "forks_count": 0, "subscribers_count": 1}
        code, out = self.run_main([], env={"GH_TRAFFIC_TOKEN": "t0k"}, get=get)
        self.assertEqual(code, 0)
        self.assertIn("5 views, 5 clones", out)
        with open(self.data, encoding="utf-8") as f:
            rec = json.loads(f.read().strip())
        self.assertEqual(rec["referrers"][0]["referrer"], "github.com")

    def test_configured_stub_says_not_built(self):
        code, out = self.run_main(["--dry-run"], env={"BING_WEBMASTER_API_KEY": "k"})
        self.assertIn("Bing Webmaster: configured, but its collector is not built yet", out)

    def test_read_failure_exits_1(self):
        def get(url, token):
            raise RuntimeError("HTTP 500")
        code, _ = self.run_main([], env={}, get=get)
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(self.data))


if __name__ == "__main__":
    unittest.main()
