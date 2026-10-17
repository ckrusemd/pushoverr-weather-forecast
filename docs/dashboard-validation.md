# Dashboard correctness and render measurements

The dashboard now selects Today by the Copenhagen render date and recommends
only remaining forecast hours on that date. At midnight it moves to the new
local date; it never substitutes tomorrow when today's daily row or remaining
hours are absent. Hourly charts use actual 24/48-hour windows from the render
instant. The daily and daylight outlooks use today's date through today + 6.
All pages show the observation date/time and the forecast selection date/time,
including CET/CEST and Europe/Copenhagen. Missing metrics and expired forecast
horizons have explicit unavailable messages.

These changes live in `R/dashboard.R` and the three dashboard pages.
`R/weather.R`, fetching, notification text, and the score formula are unchanged.
Preparation still fetches once, invalidates the old snapshot before a failure,
rejects stale live observations and stale snapshots, and requires explicit
fixture isolation. Publication checks include harmless sentinels for credential
files and the internal Herdr report directory.

## Reproduction and checks

Before the change, a fixture render clock of `2026-10-11 23:30:00` selected
`23:00` as Best outside. At `2026-10-12 00:30:00`, the first daily forecast
still displayed October 11 as Today. Both symptoms were reproduced with failing
assertions before implementation. The regression suite now checks these cases,
provider row order, missing daily/score/time values, UTC inputs, a Los Angeles
host timezone, both Copenhagen DST transition dates, and actual page consumers.

`tests/test-dashboard.R` renders all three pages once and then checks standalone
refreshes, midnight high/low values, missing precipitation and today's daily row,
expired forecast/daylight horizons, late-night heatmap behavior, publication
exclusions, and preparation failure without snapshot reuse. CI explicitly
requires Quarto for these tests. The extra complete-site render after the suite
and the duplicate full render inside the suite have been removed; standalone
build IDs verify refresh behavior.

Run validation with no production credentials:

```bash
env -u OPENWEATHERMAP_APIKEY -u PUSHOVER_APPKEY -u PUSHOVER_USERKEY \
  QUARTO_BIN="$(command -v quarto)" bash scripts/run-tests.sh
```

For a single deterministic full build:

```bash
env -u OPENWEATHERMAP_APIKEY -u PUSHOVER_APPKEY -u PUSHOVER_USERKEY \
  WEATHER_FIXTURE_PATH="$PWD/tests/fixtures/weather.json" \
  WEATHER_RENDER_NOW='2026-10-11 08:00:00' quarto render
```

## Before/after measurements

Measured locally with R 4.6.1, Quarto 1.10.19, ggplot2 4.0.3, knitr 1.52 and
rmarkdown 2.32, using the same offline fixture and a dedicated R library.
The baseline was commit `0fb2dbd`. No weather APIs were contacted. Full builds
were measured three times, sequentially, with caching/freezing disabled. Asset
sizes are uncompressed file bytes, not network transfer sizes.

| Measurement | Before | After |
| --- | ---: | ---: |
| Full fixture build, runs (seconds) | 16.757 / 14.384 / 12.737 | 13.963 / 14.324 / 14.336 |
| Full fixture build, median (seconds) | 14.384 | 14.324 |
| Dashboard validation + separate CI render (seconds) | 58.214 | 53.564 |
| Successful page executions in those CI render checks | 12 | 8 |
| Published site (bytes) | 1,461,228 | 1,451,125 |
| Four chart assets (bytes) | 243,163 | 230,913 |

The demonstrated runtime bottleneck was redundant full renders, each taking
roughly 13–14 seconds locally. Removing two of them permits additional standalone
correctness coverage while reducing this local validation sample by 4.65 seconds
(8%). This is one before/after validation sample, not a CI timing guarantee;
runner load and dependency caches vary. Individual full-build time is effectively
unchanged, and no full-build speedup is claimed.

Readable chart labels initially increased PNG chart assets to 315,509 bytes.
Using SVG reduced that intermediate total by 26.8%, and reduced chart bytes by
5.0% against the original dashboard. Total published size fell by 0.7% against
the original. SVG uses R's existing graphics device, adds no package dependency,
and remains sharp when enlarged. Quarto supports the
[`fig-format` option](https://quarto.org/docs/reference/cells/cells-knitr.html).
The largest shared asset remains the unchanged Bootstrap CSS (508,922 bytes);
this change does not remove navigation/search features to shrink it.

## Presentation and limitations

All three pages were checked in headless Chrome at 390px and 1280px widths:
no page-level horizontal overflow, broken charts, or JavaScript errors.
Wide charts and tables scroll within keyboard-focusable regions; dates remain
unwrapped. Charts have dark backgrounds, contrasting labels, explicit Copenhagen
axis times, and alternative text. Heatmap tiles show numeric values and units,
with colour normalized within each row rather than comparing incompatible units.
Screenshots and raw measurement/test logs are in the thread's review library.

Quarto and some R packages were initially unavailable. Existing user/system R
packages also contained binaries incompatible with R 4.6.1. Validation used
isolated tools and disabled user R startup files; those limitations were resolved
locally without modifying the user's R libraries. Browser checks emulate viewport
sizes, not physical-device touch interaction. Remote GitHub CI results still need
to pass before merging; no production render, deployment, or live notification
was performed.
