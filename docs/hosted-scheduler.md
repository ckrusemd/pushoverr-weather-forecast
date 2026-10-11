# Free hosted scheduling

Use [cron-job.org](https://cron-job.org/en/faq/) to submit GitHub workflow
dispatches independently of the local computer. The service is free; no paid
plan, credit card, server, or always-on laptop is required. GitHub native cron
remains a recovery watchdog, not the punctuality mechanism. Both services can
be delayed; there is no exact runner-start SLA.

## Schedule and dispatch contract

All provider schedules use **Europe/Copenhagen**, not a fixed UTC offset,
so CET/CEST transitions preserve the local times. The daily schedule never expires.

- Weather (`daily-pushover.yml`): 05:00 and 15:00, with separate recovery
  invocations at 05:10, 05:30, 15:10 and 15:30.
- Pages (`publish-weather.yml`): 05:00, with recovery at 05:10 and 05:30.

Each invocation sends one immediate HTTPS POST to
`https://api.github.com/repos/ckrusemd/pushoverr-weather-forecast/actions/workflows/WORKFLOW/dispatches`.
The body selects `ref: master`, `scheduled_delivery: true`, and a unique
`dispatch_id`. Weather also selects `mode: reconcile` and `slot: morning`;
that slot parameter is ignored by reconcile, which catches up **all due,
unaccepted slots**, including afternoon. No invocation waits or polls for a
future wall-clock time. Recovery calls are separate scheduled invocations.

External scheduled calls use the same cheap gates as native cron. Before
05:00, or once today's applicable state is complete, no R job starts. Weather
records accepted slots on `weather-notification-state`; Pages uses
`weather-pages-state:last_deployment_date`. Concurrency groups remain separate.
Bad or inaccessible state fails closed, not as empty history.

The boolean input defaults to false to preserve ordinary manual runs and
push-triggered publishing. External weather calls must use reconcile; force,
dry-run and legacy scheduled modes are rejected with the boolean enabled.
Ordinary manual force/dry-run remain available with it disabled.

## Secure setup

1. Create and verify your account at [cron-job.org's console](https://console.cron-job.org/).
2. In GitHub's [fine-grained token settings](https://github.com/settings/personal-access-tokens/new),
   select only `ckrusemd/pushoverr-weather-forecast`, grant **Actions: read and write**,
   and choose an expiry one year away (or the maximum your account policy permits).
   Metadata read access is automatic. No Contents write or weather/Pushover
   credentials are needed by the provider. Record the expiry and a renewal
   date 30 days beforehand in your operator checklist.
3. Obtain a cron-job.org API key from the console's Settings. This is a separate
   credential for configuring jobs, not the GitHub dispatch token.
4. Review the secret-free configuration:

   ```bash
   python3 scripts/configure-hosted-scheduler.py plan
   ```

5. From an interactive terminal in the repository, configure each job:

   ```bash
   python3 scripts/configure-hosted-scheduler.py configure weather
   python3 scripts/configure-hosted-scheduler.py configure pages
   ```

   Hidden-input prompts request the API key and dedicated GitHub token. Jobs are
   created **disabled**; reruns update matching jobs rather than duplicating them.
   Configure one job per command. On a rate-limit error, retry later, not in a
   polling loop. Reconfiguration, including rotation, disables that job for testing.
   Only these two named jobs are managed. Duplicate titles, unexpected URLs,
   and incomplete listings stop changes; unrelated jobs are untouched.

   The GitHub token is sent only in the provider job's Authorization header.
   Never put tokens in URLs, Git, shell command arguments/history, or chat.
   The script neither prints nor saves credentials locally. Automated callers
   can supply `CRONJOB_API_KEY` and `GITHUB_SCHEDULER_TOKEN` through an existing
   secure environment; there is no broad `gh auth token` fallback.
6. Deploy the workflow changes to `master` **before** testing or enabling jobs.
   Use Test Run on each disabled provider job. Verify the successful dispatch
   response and matching Actions run. The configured API version `2026-03-10`
   returns HTTP 200 and run URLs on successful dispatch. Invalid inputs or
   permissions are not passing tests.
7. Confirm early/duplicate scheduled runs skip expensive jobs, then enable both
   hosted jobs. Failure alerts fire after the first failed HTTP request, on
   subsequent recovery, and on automatic disabling. Alerts go only to the
   account's built-in email channel; response history is saved.
8. Keep `17 * * * *` in both workflows as the native recovery watchdog.
   The redundant dual-UTC target schedules were removed only after hosted
   dispatches passed and both daily hosted jobs were enabled.

Settings follow the [cron-job.org API](https://docs.cron-job.org/rest-api.html).
GitHub dispatch requires [Actions write permission](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event).

## Operation and credential renewal

### Active deployment checklist

- Hosted weather job: `8625739`; hosted Pages job: `8625746`.
- Both daily schedules activated on 11 October 2026 after an actual provider
  execution test at 21:03 Europe/Copenhagen. Both dispatches returned HTTP 200;
  provider request initiation was about eight seconds after the target minute.
- [Weather test](https://github.com/ckrusemd/pushoverr-weather-forecast/actions/runs/38166378570)
  and [Pages test](https://github.com/ckrusemd/pushoverr-weather-forecast/actions/runs/38166378774)
  succeeded. Both gates ran for five seconds and skipped already-completed work;
  no duplicate Pushover delivery or scheduled Pages rebuild was performed.
- GitHub reported token expiry as `2027-10-10 22:00:00 UTC`, which is
  **11 October 2027 at 00:00 Europe/Copenhagen**. Renew by **11 September 2027**.
  These are operational dates, not credentials; update them on rotation.

### Status

```bash
python3 scripts/configure-hosted-scheduler.py status
gh run list --repo ckrusemd/pushoverr-weather-forecast --workflow daily-pushover.yml --limit 10
gh run list --repo ckrusemd/pushoverr-weather-forecast --workflow publish-weather.yml --limit 10
```

Status prompts only for the provider API key and allowlists job metadata;
it never prints stored tokens, headers, or bodies. Compare provider planned/
actual request times, GitHub queued/job start times, and Pushover acceptance
timestamps **separately**. Successful dispatch is not proof of workflow success
or phone receipt. Provider emails monitor HTTP dispatch failures, not delivery.
Inspect failed Actions runs and follow [notification recovery](notification-state.md)
for accepted journals.

Observe the first morning and afternoon runs with the computer offline. Normal
early/duplicate runner execution should finish in under a minute after acquiring
a runner; queueing or network outages can exceed that target. Offline tests
cover both DST transitions, boundaries, duplicates, partial/delayed recovery,
invalid state, and unchanged manual behavior.

Renew the GitHub token before expiry, preferably outside delivery windows.
Reconfigure both jobs with the replacement, test and enable them, then revoke
the old token. Update the recorded expiry/renewal dates. Keep email alerts on:
expired/revoked credentials produce dispatch failures, not silent success.
An expired provider API key affects setup/status; an expired GitHub token affects
dispatches. The hourly GitHub watchdog continues independently.

Weather and Pages only: electricity workflows and local systemd timers remain
untouched and are not required for hosted weather delivery.
