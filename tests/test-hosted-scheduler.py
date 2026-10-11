"""Offline provider provisioning and real-Git Pages gate regression tests."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
from zoneinfo import ZoneInfo
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scheduler", ROOT / "scripts/configure-hosted-scheduler.py")
scheduler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheduler)


class FakeProvider:
    def __init__(self, jobs=None, incomplete=False):
        self.jobs = [] if jobs is None else jobs
        self.incomplete = incomplete
        self.calls = []

    def request(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        if method == "GET":
            return {"jobs": self.jobs, "someFailed": self.incomplete}
        if method == "PUT":
            self.jobs.append({**payload["job"], "jobId": 123})
            return {"jobId": 123}
        if method == "PATCH":
            self.jobs[0].update(payload["job"])
            return {}
        raise AssertionError("Unexpected request")


class ProvisionTests(unittest.TestCase):
    def test_specs(self):
        for kind, hours in (("weather", [5, 15]), ("pages", [5])):
            job = scheduler.job_spec(kind, "test-private-token")
            self.assertFalse(job["enabled"])
            self.assertEqual(job["requestMethod"], 1)
            self.assertEqual(job["schedule"]["timezone"], "Europe/Copenhagen")
            self.assertEqual(job["schedule"]["hours"], hours)
            self.assertEqual(job["schedule"]["minutes"], [0, 10, 30])
            self.assertEqual(job["schedule"]["expiresAt"], 0)
            self.assertEqual(job["notification"]["selectedChannels"], [0])
            for name in ("onFailure", "onSuccess", "onDisable"):
                self.assertTrue(job["notification"][name])
            body = json.loads(job["extendedData"]["body"])
            self.assertEqual(body["ref"], "master")
            self.assertIs(body["inputs"]["scheduled_delivery"], True)
            self.assertIn("%cjo:uuid4%", body["inputs"]["dispatch_id"])
            self.assertNotIn("test-private-token", json.dumps(body))
            if kind == "weather":
                self.assertEqual(body["inputs"]["mode"], "reconcile")

    def test_dst_clock(self):
        zone = ZoneInfo("Europe/Copenhagen")
        for day, expected_hour in (("2026-01-22", 4), ("2026-07-22", 3),
                                   ("2026-03-29", 3), ("2026-10-25", 4)):
            morning = datetime.fromisoformat(f"{day}T05:00:00").replace(tzinfo=zone)
            self.assertEqual(morning.astimezone(timezone.utc).hour, expected_hour)

    def test_create_and_update_do_not_duplicate_or_print_secret(self):
        provider = FakeProvider()
        first = scheduler.configure(provider, "weather", "test-private-token")
        second = scheduler.configure(provider, "weather", "rotated-private-token")
        self.assertEqual(first["job_id"], second["job_id"])
        self.assertEqual([call[0] for call in provider.calls], ["GET", "PUT", "GET", "PATCH"])
        self.assertNotIn("private-token", json.dumps([first, second]))
        self.assertEqual(len(provider.jobs), 1)
        self.assertFalse(provider.jobs[0]["enabled"])

    def test_fail_closed_before_mutation(self):
        expected = {**scheduler.job_spec("weather"), "jobId": 1}
        for provider in (FakeProvider([expected, expected]), FakeProvider(incomplete=True),
                         FakeProvider([{**expected, "url": "https://example.invalid"}]),
                         FakeProvider([{**expected, "jobId": True}])):
            with self.assertRaises(RuntimeError):
                scheduler.configure(provider, "weather", "token")
            self.assertEqual([call[0] for call in provider.calls], ["GET"])

    def test_plan_never_reads_real_credentials(self):
        stdout = io.StringIO()
        with patch.dict(os.environ, {"CRONJOB_API_KEY": "private-provider-key",
                                     "GITHUB_SCHEDULER_TOKEN": "private-github-key"}), \
                patch.object(scheduler.sys, "argv", ["scheduler", "plan"]), \
                patch.object(scheduler, "Provider", side_effect=AssertionError("Network")), \
                contextlib.redirect_stdout(stdout):
            self.assertEqual(scheduler.main(), 0)
        self.assertNotIn("private-", stdout.getvalue())
        self.assertEqual(len(json.loads(stdout.getvalue())), 2)

    def test_provider_errors_are_redacted(self):
        provider = scheduler.Provider("private-provider-key")
        error = urllib.error.HTTPError("https://example.invalid/private-provider-key", 401,
                                       "private-github-key", {}, None)
        with patch.object(provider.opener, "open", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "HTTP 401") as result:
                provider.request("PUT", "/jobs", {"job": scheduler.job_spec("weather", "private-github-key")})
        self.assertNotIn("private-", str(result.exception))
        self.assertIsNone(scheduler.NoRedirects().redirect_request(None, None, 302, "", {}, "https://other.invalid"))

    def test_credentials_require_hidden_input_and_valid_tokens(self):
        with patch.dict(os.environ, {"GITHUB_SCHEDULER_TOKEN": "private value"}):
            with self.assertRaises(RuntimeError) as result:
                scheduler.credential("GITHUB_SCHEDULER_TOKEN", "Token")
            self.assertNotIn("private value", str(result.exception))
        with patch.dict(os.environ, {}, clear=True), patch.object(scheduler.sys.stdin, "isatty", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "interactive terminal"):
                scheduler.credential("GITHUB_SCHEDULER_TOKEN", "Token")
        with patch.dict(os.environ, {}, clear=True), patch.object(scheduler.sys.stdin, "isatty", return_value=True), \
                patch.object(scheduler.getpass, "getpass", side_effect=scheduler.getpass.GetPassWarning("echo")):
            with self.assertRaisesRegex(RuntimeError, "refusing to echo"):
                scheduler.credential("GITHUB_SCHEDULER_TOKEN", "Token")


class PagesGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.remote = self.root / "remote.git"
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        for key in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            self.env.pop(key, None)
        self.git("init", "--bare", str(self.remote), cwd=self.root)
        self.git("init", str(self.checkout), cwd=self.root)
        self.git("remote", "add", "origin", str(self.remote))

    def git(self, *args, data=None, cwd=None):
        return subprocess.run(["git", *args], input=data, cwd=cwd or self.checkout,
                              env=self.env, capture_output=True, text=True, check=True).stdout.strip()

    def state(self, date, missing_file=False):
        blob = self.git("hash-object", "-w", "--stdin", data=date + "\n", cwd=self.remote)
        filename = "unrelated" if missing_file else "last_deployment_date"
        tree = self.git("mktree", data=f"100644 blob {blob}\t{filename}\n", cwd=self.remote)
        commit = self.git("commit-tree", tree, "-m", "Fixture state", cwd=self.remote)
        self.git("update-ref", "refs/heads/weather-pages-state", commit, cwd=self.remote)

    def gate(self, event="workflow_dispatch", scheduled="true", date="2026-10-11", minute=300,
             remote="origin", fails=False):
        result = subprocess.run(["bash", str(ROOT / "scripts/pages-gate.sh"), event, scheduled,
                                 date, str(minute), remote], cwd=self.checkout, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode != 0, fails, result.stdout + result.stderr)
        return json.loads(result.stderr if fails else result.stdout)

    def test_boundaries_and_dst(self):
        for date in ("2026-01-22", "2026-07-22", "2026-03-29", "2026-10-25"):
            for event, scheduled in (("schedule", "false"), ("workflow_dispatch", "true")):
                for minute in (299, 300, 899, 900, 1439):
                    result = self.gate(event, scheduled, date, minute)
                    self.assertEqual(result["publish"], minute >= 300)
                    self.assertEqual(result["minute"], minute)

    def test_duplicate_and_delayed_recovery(self):
        self.state("2026-10-11")
        self.assertFalse(self.gate(minute=310)["publish"])
        self.assertFalse(self.gate(minute=330)["publish"])
        self.assertTrue(self.gate(date="2026-10-12", minute=1439)["publish"])

    def test_manual_and_push_ignore_scheduled_state(self):
        for event in ("workflow_dispatch", "push"):
            result = self.gate(event, "false", minute=0, remote="unreachable")
            self.assertTrue(result["publish"])
            self.assertEqual(result["reason"], "manual_dispatch")

    def test_invalid_state_and_unreachable_remote_fail_closed(self):
        for date in ("invalid", "2026-02-30", "0000-01-01", "2026-10-11\n2026-10-12"):
            self.state(date)
            self.assertEqual(self.gate(fails=True)["reason"], "invalid_deployment_date")
        self.state("2026-10-11", missing_file=True)
        self.assertEqual(self.gate(fails=True)["reason"], "remote_state_missing")
        self.assertEqual(self.gate(remote="unreachable", fails=True)["reason"], "remote_lookup_failed")

    def test_invalid_arguments_and_step_outputs(self):
        for args in ({"scheduled": "invalid"}, {"date": "2026-02-30"}, {"minute": 1440}):
            self.assertEqual(self.gate(fails=True, **args)["reason"], "invalid_gate_input")
        output, summary = self.root / "output", self.root / "summary"
        self.env.update(GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
        self.gate(minute=299)
        self.assertEqual(output.read_text(), "publish=false\n")
        self.assertIn('"reason":"before_morning"', summary.read_text())


if __name__ == "__main__":
    unittest.main()
