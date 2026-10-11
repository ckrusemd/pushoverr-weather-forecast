#!/usr/bin/env python3
"""Configure free cron-job.org dispatch jobs. Never print or persist credentials."""
import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.request
import warnings

REPOSITORY = "ckrusemd/pushoverr-weather-forecast"
API = "https://api.cron-job.org"


def job_spec(kind, token="<GITHUB_SCHEDULER_TOKEN>"):
    workflow = "daily-pushover.yml" if kind == "weather" else "publish-weather.yml"
    inputs = {"scheduled_delivery": True, "dispatch_id": f"cronjob-{kind}-%cjo:uuid4%"}
    if kind == "weather":
        inputs.update(mode="reconcile", slot="morning")
    return {
        "title": f"{REPOSITORY}: {kind}",
        "url": f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/{workflow}/dispatches",
        # Enable in the console only after its Test Run and the Actions gates pass.
        "enabled": False,
        "saveResponses": True,
        "requestMethod": 1,  # POST in cron-job.org's API.
        "requestTimeout": 20,
        "redirectSuccess": False,
        "auth": {"enable": False},
        "schedule": {
            "timezone": "Europe/Copenhagen", "expiresAt": 0,
            "hours": [5, 15] if kind == "weather" else [5],
            "minutes": [0, 10, 30],
            "mdays": [-1], "months": [-1], "wdays": [-1],
        },
        "notification": {
            "onFailure": True, "onFailureCount": 1,
            "onSuccess": True, "onDisable": True,
            "mode": 2, "selectedChannels": [0],  # Account email only.
        },
        "extendedData": {
            "headers": {
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2026-03-10",
            },
            "body": json.dumps({"ref": "master", "inputs": inputs}),
        },
    }


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the provider credential to another host.
        return None


class Provider:
    def __init__(self, key):
        self.key = key
        self.opener = urllib.request.build_opener(NoRedirects())

    def request(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            API + path, data=data, method=method,
            headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=20) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise RuntimeError("Provider response exceeds size limit.")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise RuntimeError("Invalid provider response.")
            return result
        except urllib.error.HTTPError as error:
            # Provider error bodies/headers may contain credentials; never echo.
            raise RuntimeError(f"Provider HTTP {error.code}; no automatic retry. Check the console and retry later.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise RuntimeError("Provider transport failed; check the console before retrying.") from None
        except (ValueError, UnicodeError):
            raise RuntimeError("Invalid provider response.") from None


def managed_jobs(provider):
    result = provider.request("GET", "/jobs")
    if result.get("someFailed") or not isinstance(result.get("jobs"), list):
        raise RuntimeError("Could not retrieve the complete job list; refusing changes.")
    matches = {}
    for kind in ("weather", "pages"):
        expected = job_spec(kind)
        found = [item for item in result["jobs"] if isinstance(item, dict) and item.get("title") == expected["title"]]
        if len(found) > 1:
            raise RuntimeError(f"Duplicate {kind} jobs; resolve in the console first.")
        if found:
            job = found[0]
            if job.get("url") != expected["url"] or type(job.get("jobId")) is not int or job["jobId"] <= 0:
                raise RuntimeError(f"Unexpected {kind} job identity; refusing changes.")
            matches[kind] = job
    return matches


def configure(provider, kind, token):
    # One job per invocation respects the provider's job-creation rate limit
    # without any sleep or polling. Reruns update the same job, not duplicates.
    matches = managed_jobs(provider)
    spec = job_spec(kind, token)
    if kind in matches:
        job_id = matches[kind]["jobId"]
        provider.request("PATCH", f"/jobs/{job_id}", {"job": spec})
    else:
        result = provider.request("PUT", "/jobs", {"job": spec})
        job_id = result.get("jobId")
        if type(job_id) is not int or job_id <= 0:
            raise RuntimeError("Creation returned no job ID; check the console before retrying.")
    return {"kind": kind, "job_id": job_id, "enabled": False, "next_step": "Test Run in the console, inspect Actions, then enable."}


def credential(name, label):
    value = os.environ.get(name)
    if value is None:
        if not sys.stdin.isatty():
            raise RuntimeError(f"Set {name} securely or run from an interactive terminal.")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                value = getpass.getpass(f"{label} (hidden): ")
        except getpass.GetPassWarning:
            raise RuntimeError("Hidden terminal input is unavailable; refusing to echo a credential.") from None
    if not value or any(character.isspace() for character in value):
        raise RuntimeError(f"Invalid {name}; expected a nonempty token without whitespace.")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "configure", "status"))
    parser.add_argument("kind", nargs="?", choices=("weather", "pages"))
    args = parser.parse_args()
    if (args.command == "configure") != (args.kind is not None):
        parser.error("Only configure requires a job kind: weather or pages.")
    try:
        if args.command == "plan":
            result = [job_spec(kind) for kind in ("weather", "pages")]
        else:
            provider = Provider(credential("CRONJOB_API_KEY", "cron-job.org API key"))
            if args.command == "configure":
                result = configure(provider, args.kind, credential("GITHUB_SCHEDULER_TOKEN", "Dedicated repository-restricted GitHub token"))
            else:
                # Allowlist metadata; never output account headers or request bodies.
                result = {
                    kind: {key: job.get(key) for key in ("jobId", "enabled", "lastStatus", "lastExecution", "nextExecution")}
                    for kind, job in managed_jobs(provider).items()
                }
        print(json.dumps(result, indent=2))
        return 0
    except (RuntimeError, KeyboardInterrupt, EOFError) as error:
        message = str(error) if isinstance(error, RuntimeError) else "Setup cancelled."
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
