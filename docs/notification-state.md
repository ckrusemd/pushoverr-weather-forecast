# Notification state and recovery

The gate and sender use `Europe/Copenhagen` dates and minutes since midnight.
Morning becomes due at minute 300 (05:00), afternoon at minute 900 (15:00).
Scheduled checks, including external dispatches with `scheduled_delivery: true`,
skip the R job when no slots are due. External scheduled dispatches require
reconcile mode. See [free hosted scheduler setup](hosted-scheduler.md).
Manual reconcile, force and
dry-run dispatches still run; force and dry-run do not persist slot acceptance.
The workflow concurrency group remains `weather-pushover-reconciliation`.

## Forecast chart attachment

Morning and afternoon messages retain their text and add one 2×2 ggplot2 PNG:
temperature (top left), UV index (top right), hourly rain bars with a PoP line
(bottom left), and cloud cover with wind (bottom right). Paired quantities have
separately labelled axes in mm/percent and percent/m/s; they do not share units.
The horizon is 24 elapsed hours from the current forecast hour, including the
next calendar day. All labels use Europe/Copenhagen, with CET/CEST on axis ticks
when the window crosses a daylight-saving transition. Missing hours break lines;
missing values are not replaced by calm/dry forecasts.

The renderer reuses the already-fetched weather payload, so no weather API calls
are added. A catch-up run reuses one image for both due slots. No-work invocations
never render a chart. A rendering failure is logged and falls back to the text
forecast so graphics cannot block routine delivery. Dry runs render but do not
send or record acceptance. Temporary images are removed on success or failure.

The 1800×1500 PNG is uploaded directly in the same multipart Pushover request as
the text, with `image/png` content type. It is not published to Pages or sent as
a second notification. Both rendering and transport enforce the documented
[5 MiB attachment limit](https://pushover.net/api#attachments). The existing
acceptance, retry, journal, and durable deduplication rules apply unchanged.

To preview offline from the repository root (requires ggplot2 and jsonlite):

```bash
Rscript --vanilla -e 'source("R/weather.R"); source("R/notification-chart.R"); p <- jsonlite::fromJSON("tests/fixtures/weather.json", simplifyVector=FALSE); render_notification_chart(p, "/tmp/weather-preview.png", now=as_local_time(p$current$dt))'
```

## Accepted state

Schema 1 contains exactly `schema_version: 1` and a `deliveries` map, keyed by
valid Gregorian `YYYY-MM-DD` dates. Each date maps one or both morning/afternoon slots to
records with exactly these fields:

```json
{"accepted_at":"2026-09-22T03:00:00Z","request_id":"request-id","run_id":"run-id"}
```

`request_id` and `run_id` must be strings containing a character other than
ASCII space, tab, CR or LF. `accepted_at` is a valid date and timestamp with
seconds and `Z` or a numeric timezone offset. Existing `legacy` IDs remain valid.
Schema-1 empty `deliveries: []`, emitted by the old R writer, is accepted and
normalized to `{}`. Nonempty arrays, duplicate keys, unknown fields/slots,
invalid records, empty dated entries and malformed JSON fail validation. Both implementations have
parity tests in `tests/test-notification.R`.

Recognized legacy files contain unique `morning=DATE` and/or `afternoon=DATE`
assignments (empty values are allowed). They migrate to schema 1 with `legacy`
IDs. Empty files and unrelated text are errors, not empty state.

A missing local file or a positively confirmed absent remote state branch is
empty state. Authentication, network, fetch and parse failures stop the workflow
before sending. An existing remote branch must contain `notification-state.json`
or the older `delivery_state`; malformed current JSON cannot fall back to legacy.
Gate decisions and state failures appear as JSON in workflow logs and summaries.

## Persistence and recovery

The R writer first atomically replaces `STATE_PATH.accepted.json`, then atomically
replaces `STATE_PATH`. Temporary files reside beside their destinations. The
journal retains accepted records even if replacing the working state fails.
Reconciliation attempts persistence even after a partially successful send run.
Only HTTP 200 with numeric status 1 and a nonblank string request ID counts as
Pushover API acceptance. Acceptance does not establish device delivery.

Persistence fetches the latest state, validates it, merges missing accepted
records, prunes dates older than Copenhagen today minus 30 days, and pushes a
commit whose parent is that snapshot. Pruning happens after merging remote,
working-state and journal records, so stale history cannot resurrect expired
dates; the cutoff date and recent journal-only records remain. Existing remote
records win slot conflicts. A rejected push triggers another fetch and merge,
up to three attempts without clock waiting. The helper uses a private Git index
and does not change the checked-out branch. It retains legacy files on the state
branch while adding canonical JSON. Artifacts contain only state/journal files
that exist, never repository credentials or weather/Pushover keys.
For deterministic tests, the optional fifth argument to `persist` is the
Copenhagen date: `persist STATE_PATH REMOTE ATTEMPTS YYYY-MM-DD`.

After exhausted persistence retries, the workflow fails and archives
`notification-accepted-state-RUN_ID-RUN_ATTEMPT` for 30 days. Artifact recovery is
an operator task; subsequent scheduled runs cannot automatically see an
unpersisted artifact. To reduce duplicate sends, pause scheduling or use the
repository's operational controls before the next due reconciliation, download
the affected artifact, inspect its state and accepted journal, then run from a
trusted checkout with permission to push the state branch:

```bash
bash scripts/notification-state.sh validate /absolute/path/notification-state.json.accepted.json
bash scripts/notification-state.sh persist /absolute/path/notification-state.json
```

The persistence helper also works when only the `.accepted.json` file exists.
It merges with the current remote state and never sends notifications. If the
remote state is malformed, restore or repair it from a reviewed valid backup
before retrying; do not delete it to bypass validation. Resume normal scheduling
once recovery succeeds.

There is an unavoidable window between API acceptance and writing the local
journal (and between journaling and remote persistence). A runner crash or lost
API response in that window can lead to a repeated request. This provides
accepted-slot deduplication when state is durable, not an exactly-once guarantee.
