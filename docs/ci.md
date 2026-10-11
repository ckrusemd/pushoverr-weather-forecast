# Weather CI and publishing

`validate.yml` runs on pull requests targeting `master` and pushes to `master`.
It has only `contents: read` permission, checks out without persisted Git
credentials, and cancels superseded runs for the same PR or event/ref. Its
concurrency group is separate from production Pages publishing and notification
reconciliation. Validation never deploys or sends notifications.

The validation job runs `bash scripts/run-tests.sh`, then `quarto render` for the
complete site declared in `_quarto.yml`. The runner checks every `scripts/*.sh`
and `tests/test-*.sh` with `bash -n`, runs every `tests/test-*.R` with
`Rscript --vanilla`, and executes shell helper tests in `tests/test-*.sh`.
It fails on the first error or if there are no R tests. Test files remain owned
by the agents responsible for their respective features; adding a matching file
automatically includes it in CI. Operational scripts such as
`scripts/send-pushover.R` are not executed by the runner.

## Fixture and production separation

Validation explicitly sets `WEATHER_FIXTURE_PATH` to
`tests/fixtures/weather.json` and leaves `OPENWEATHERMAP_APIKEY`,
`PUSHOVER_APPKEY`, and `PUSHOVER_USERKEY` empty. The test runner also removes
these credentials before starting tests. Tests and rendering must use fixtures
or injected transports; they must not contact weather or notification APIs.
Installing CI tools and R dependencies can require network access.

The dashboard preparation PR supplies the fixture and the
`Rscript scripts/prepare-dashboard.R` Quarto pre-render hook. Validation checks
that those files exist before rendering; it does not skip rendering while the
dependency is missing. This draft PR can therefore fail fixture rendering until
the coordinator rebases it onto that PR. The coordinator verifies the integrated
fixture render before marking the PR ready.

To run the tests locally from any directory:

```bash
R_LIBS_USER=/home/ckrusemd/R/library bash /path/to/repo/scripts/run-tests.sh
```

After integrating the dashboard preparation changes, render locally without
credentials:

```bash
env -u OPENWEATHERMAP_APIKEY -u PUSHOVER_APPKEY -u PUSHOVER_USERKEY \
  TZ=Europe/Copenhagen R_LIBS_USER=/home/ckrusemd/R/library \
  WEATHER_FIXTURE_PATH="$PWD/tests/fixtures/weather.json" quarto render
```

`publish-weather.yml` retains push-to-`master`, scheduled watchdog, and manual
dispatch publishing. PRs use only the validation workflow. Production runs the
same offline tests before exposing the weather API key to rendering, and clears
`WEATHER_FIXTURE_PATH` for the production render. No Pushover key is supplied to
publishing. Production rendering uses the dashboard preparation hook to obtain
live weather. Do not manually dispatch production publishing to test a draft.

## Dependencies and timings

Both site jobs explicitly install `httr`, `jsonlite`, `suncalc`, `ggplot2`,
`knitr`, and `rmarkdown`, plus their required dependencies (`dependencies: NA`).
Using `packages` instead of automatic `deps::.` discovery avoids the large
dependency set in preserved, archived Rmd files. Suggested packages are not
installed. Quarto setup supplies Pandoc, so the dependency action does not
install either tool again. Quarto is pinned to 1.10.19 in both workflows to match
the coordinator's local render tool. Existing action commit pins and R 4.6.1
are retained; the package cache uses `weather-dashboard-2`. No repository lockfile or renv
migration is introduced.

Validation and production build each have a 20-minute ceiling. The production
schedule gate, Pages deploy, and deployment-date recorder each have a 5-minute
ceiling. These are failure limits, not measured performance claims. Compare
cold and warm dependency setup, test, pre-render preparation, and render step
durations in the Actions run view after integration. No runner waits for a
future delivery time.

Scheduled publishing checks the date and hour in `Europe/Copenhagen` and becomes
eligible at 05:00 local time. Successful deployment records that timezone's date
in the existing `weather-pages-state` branch and `last_deployment_date` file.
An unchanged staged date produces no commit or push. Only a confirmed absent
remote branch initializes state; remote lookup, fetch, missing-file, and invalid
date errors fail rather than silently resetting history. Recording uses a
normal push, so an external concurrent update cannot be overwritten by force.
The production `weather-pages` mutex remains independent from validation.
Notification slot timing, legacy notification state, and dispatch modes are
handled by the separate notification workflow.
