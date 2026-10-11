# Offline unit tests; QUARTO_BIN optionally enables full and standalone renders.
test_dashboard <- function() {
  source("R/weather.R", local = TRUE)
  source("R/dashboard.R", local = TRUE)
  expect <- function(ok, label) if (!isTRUE(ok)) stop(label, call. = FALSE)
  equal <- function(actual, expected, label) expect(identical(actual, expected), label)
  fails <- function(code, pattern, label) {
    error <- tryCatch({ force(code); NULL }, error = identity)
    expect(inherits(error, "error") && grepl(pattern, conditionMessage(error)), label)
  }
  saved_env <- Sys.getenv(c("WEATHER_FIXTURE_PATH", "WEATHER_RENDER_NOW", "OPENWEATHERMAP_APIKEY",
                           "QUARTO_PROJECT_DIR"), unset = NA_character_)
  on.exit({
    for (name in names(saved_env)) {
      if (is.na(saved_env[[name]])) Sys.unsetenv(name)
      else do.call(Sys.setenv, setNames(list(saved_env[[name]]), name))
    }
  }, add = TRUE)
  Sys.unsetenv(names(saved_env))
  original_dir <- getwd()
  root <- tempfile("weather-dashboard-tests-")
  dir.create(root)
  on.exit({ setwd(original_dir); unlink(root, recursive = TRUE) }, add = TRUE)
  path <- file.path(root, "snapshot.json")
  now <- as.POSIXct("2026-10-11 08:00:00", tz = weather_config$timezone)
  fixture_path <- file.path(original_dir, "tests", "fixtures", "weather.json")
  fixture <- jsonlite::fromJSON(fixture_path, simplifyVector = FALSE)
  calls <- 0L
  mock_fetch <- function() {
    calls <<- calls + 1L
    payload <- fixture
    payload$current$temp <- calls + 10
    payload$current$dt <- as.numeric(now)
    payload
  }
  first <- prepare_dashboard_snapshot(path, fixture_path = "", now = now, fetch = mock_fetch)
  equal(calls, 1L, "Preparation must fetch exactly once")
  first_read <- read_dashboard_snapshot(path, now = now)
  equal(first_read$payload$current$temp, 11L, "First preparation uses fetched data")
  second <- prepare_dashboard_snapshot(path, fixture_path = "", now = now + 1, fetch = mock_fetch)
  equal(calls, 2L, "Next build must fetch again")
  expect(first$build_id != second$build_id, "Every preparation needs a new build ID")
  equal(read_dashboard_snapshot(path, now = now + 1)$payload$current$temp, 12L,
        "Next build replaces the previous payload")
  fails(read_dashboard_snapshot(path, now = now + 3602), "stale", "Stale snapshots must fail")
  fails(read_dashboard_snapshot(path, now = now - 301), "future", "Future snapshots must fail")
  fails(prepare_dashboard_snapshot(path, fixture_path = "", now = now,
                                  fetch = function() stop("mock fetch failure")),
        "mock fetch failure", "Fetch failure must propagate")
  expect(!file.exists(path), "Failed preparation must remove the previous build")
  fails(read_dashboard_snapshot(path, now = now), "missing", "No fallback after fetch failure")
  stale_fetch <- function() {
    payload <- fixture
    payload$current$dt <- as.numeric(now) - 6 * 3600 - 1
    payload
  }
  fails(prepare_dashboard_snapshot(path, fixture_path = "", now = now, fetch = stale_fetch),
        "observation is stale", "Stale live observations must fail")
  Sys.setenv(WEATHER_RENDER_NOW = "2026-10-11 12:00:00")
  fails(prepare_dashboard_snapshot(path, fixture_path = "", now = now, fetch = mock_fetch),
        "requires WEATHER_FIXTURE_PATH", "Production cannot override its render clock")
  Sys.unsetenv("WEATHER_RENDER_NOW")

  prepared <- prepare_dashboard_snapshot(path, fixture_path = fixture_path, now = now,
                                         fetch = function() stop("Fixture mode fetched weather"))
  equal(prepared$source, "fixture", "Explicit fixture mode")
  equal(prepared$render_now, as.numeric(fixture$current$dt), "Fixture clock defaults to its synthetic observation")
  fails(read_dashboard_snapshot(path, now = now), "explicit WEATHER_FIXTURE_PATH",
        "Fixture snapshots cannot silently serve production")
  validated <- read_dashboard_snapshot(path, now = now, allow_fixture = TRUE)
  expect(identical(validated$payload, fixture), "Fixture JSON round trip")
  equal(as.character(dashboard_daily(validated)$date[1]), "2026-10-11",
        "Daily midnight timestamps must use Copenhagen dates")
  bad <- validated
  bad$schema_version <- 2L
  jsonlite::write_json(bad, path, auto_unbox = TRUE, digits = NA)
  fails(read_dashboard_snapshot(path, now = now, allow_fixture = TRUE), "schema",
        "Unknown snapshot versions must fail")
  bad <- validated
  bad$payload$hourly[[1]]$wind_speed <- NULL
  jsonlite::write_json(bad, path, auto_unbox = TRUE, digits = NA)
  fails(read_dashboard_snapshot(path, now = now, allow_fixture = TRUE), "hourly.wind_speed",
        "Malformed payloads must fail at the consumer boundary")
  bad <- validated
  bad$payload$hourly <- list()
  jsonlite::write_json(bad, path, auto_unbox = TRUE, digits = NA)
  fails(read_dashboard_snapshot(path, now = now, allow_fixture = TRUE), "hourly",
        "Empty hourly payloads cannot produce broken pages")
  fails(prepare_dashboard_snapshot(path, fixture_path = file.path(root, "absent.json"), now = now),
        "", "Missing fixture must fail")
  expect(!file.exists(path), "Fixture failure must invalidate the old snapshot too")

  hourly <- hourly_frame(fixture, weather_config$timezone)
  heat <- dashboard_heatmap_data(hourly, now)
  expect(nrow(heat) == 15L * 6L, "Heatmap must keep today's 08:00 through 22:00 only")
  expect(all(as.Date(heat$hour, tz = weather_config$timezone) == as.Date("2026-10-11")),
         "Heatmap must never include tomorrow")
  late_hourly <- hourly[hourly$time >= as.POSIXct("2026-10-11 23:00:00", tz = weather_config$timezone), ]
  equal(nrow(dashboard_heatmap_data(late_hourly,
                                   as.POSIXct("2026-10-11 23:30:00", tz = weather_config$timezone))),
        0L, "Late-night data must not fall back to tomorrow")
  after_filter <- hourly[format(hourly$time, "%H", tz = weather_config$timezone) %in% c("00", "06", "23"), ]
  equal(nrow(dashboard_heatmap_data(after_filter, now)), 0L, "Empty 07-22 filter must stay empty")
  empty_hours <- hourly[FALSE, ]
  equal(nrow(dashboard_heatmap_data(empty_hours, now)), 0L, "Zero-row input must stay empty")
  midnight <- as.POSIXct("2026-10-12 00:30:00", tz = weather_config$timezone)
  utc_hourly <- hourly
  attr(utc_hourly$time, "tzone") <- "UTC"
  midnight_heat <- dashboard_heatmap_data(utc_hourly, midnight)
  expect(nrow(midnight_heat) == 16L * 6L &&
           all(as.Date(midnight_heat$hour, tz = weather_config$timezone) == as.Date("2026-10-12")),
         "Copenhagen date and hour filters must work even with UTC input")
  for (day in c("2026-03-29", "2026-10-25")) {
    boundary <- hourly[1:4, ]
    boundary$time <- as.POSIXct(paste(day, c("06:00:00", "07:00:00", "22:00:00", "23:00:00")),
                              tz = weather_config$timezone)
    dst_heat <- dashboard_heatmap_data(boundary, as.POSIXct(paste(day, "00:30:00"), tz = weather_config$timezone))
    equal(unique(dst_heat$hour_label), c("07:00", "22:00"), "DST days preserve Copenhagen 07-22 slots")
  }
  equal(as.numeric(dashboard_best_hour(hourly, now)$score), max(outdoor_score(hourly[1:16, ])),
        "Dashboard preserves the outdoor score formula")

  # Copy only this agent's inputs into an isolated project for consumer and render tests.
  project <- file.path(root, "project")
  dir.create(project)
  for (directory in c("R", "scripts", "tests/fixtures")) {
    dir.create(file.path(project, directory), recursive = TRUE)
  }
  files <- c("R/weather.R", "R/dashboard.R", "scripts/prepare-dashboard.R", "tests/fixtures/weather.json",
             "index.qmd", "forecast.qmd", "daylight.qmd", "_quarto.yml", "styles.css")
  expect(all(file.copy(file.path(original_dir, files), file.path(project, files))), "Copy test project")
  setwd(project)
  Sys.setenv(WEATHER_FIXTURE_PATH = "tests/fixtures/weather.json")
  page_snapshot <- prepare_dashboard_snapshot()
  for (page in c("index.qmd", "forecast.qmd", "daylight.qmd")) {
    lines <- readLines(page)
    start <- which(lines == "```{r}")[1] + 1L
    end <- which(seq_along(lines) >= start & lines == "```")[1] - 1L
    consumer <- new.env(parent = environment())
    consumer$source <- function(file) {
      sys.source(file, envir = consumer)
      if (file == "R/weather.R") consumer$fetch_weather <- function(...) stop("Consumer fetched weather")
    }
    eval(parse(text = lines[start:end]), envir = consumer)
    equal(consumer$snapshot$build_id, page_snapshot$build_id, paste(page, "reads the shared build"))
    equal(consumer$snapshot$payload, page_snapshot$payload, paste(page, "reads identical weather"))
  }
  # The standalone preparation script and a reader run in separate R processes.
  run_r <- function(args) {
    output <- system2(file.path(R.home("bin"), "Rscript"), args, stdout = TRUE, stderr = TRUE)
    expect(is.null(attr(output, "status")), paste(output, collapse = "\n"))
    output
  }
  run_r(c("--vanilla", "scripts/prepare-dashboard.R"))
  standalone <- read_dashboard_snapshot()
  expect(standalone$build_id != page_snapshot$build_id, "Standalone preparation refreshes snapshot")
  reader <- run_r(c("-e", shQuote('source("R/weather.R"); source("R/dashboard.R"); cat(read_dashboard_snapshot()$build_id)')))
  equal(paste(reader, collapse = ""), standalone$build_id, "Separate R sessions share the snapshot")
  Sys.setenv(WEATHER_RENDER_NOW = "2026-10-12 00:30:00")
  overridden <- prepare_dashboard_snapshot()
  equal(format(dashboard_now(overridden), "%Y-%m-%d %H:%M:%S", tz = weather_config$timezone),
        "2026-10-12 00:30:00", "Explicit fixture clock is Copenhagen time")
  Sys.setenv(WEATHER_RENDER_NOW = "not a date")
  fails(prepare_dashboard_snapshot(), "YYYY-MM-DD", "Malformed fixture clock must fail")
  expect(!file.exists(dashboard_snapshot_path()), "Invalid clock must remove prior snapshot")
  Sys.unsetenv("WEATHER_RENDER_NOW")
  cat("Dashboard offline unit tests passed.\n")

  quarto <- Sys.getenv("QUARTO_BIN", unset = Sys.which("quarto"))
  if (!nzchar(quarto)) {
    cat("Dashboard render tests skipped: set QUARTO_BIN to enable them.\n")
    return(invisible(NULL))
  }
  render <- function(input = NULL) {
    output <- system2(quarto, c("render", input), stdout = TRUE, stderr = TRUE)
    expect(is.null(attr(output, "status")), paste(output, collapse = "\n"))
    read_dashboard_snapshot()
  }
  full <- render()
  expect(all(file.exists(file.path("_site", c("index.html", "forecast.html", "daylight.html")))),
         "Full render must produce all three pages")
  full_again <- render()
  expect(full_again$build_id != full$build_id, "Every full render must refresh")
  Sys.setenv(WEATHER_RENDER_NOW = "2026-10-14 23:30:00")
  single <- render("forecast.qmd")
  expect(single$build_id != full_again$build_id, "Standalone Quarto page render must refresh")
  html <- paste(readLines("_site/forecast.html", warn = FALSE), collapse = "\n")
  expect(grepl("No hourly forecast is available for today between 07:00 and 22:00", html, fixed = TRUE),
         "Rendered empty heatmap must show its explicit message")
  Sys.setenv(WEATHER_RENDER_NOW = "2026-10-11 23:30:00")
  late_fixture <- fixture
  late_fixture$hourly <- Filter(function(row) row$dt >= as.numeric(late_hourly$time[1]), fixture$hourly)
  late_path <- file.path(project, "tests", "fixtures", "late-night.json")
  jsonlite::write_json(late_fixture, late_path, auto_unbox = TRUE, digits = NA)
  Sys.setenv(WEATHER_FIXTURE_PATH = "tests/fixtures/late-night.json")
  render("forecast.qmd")
  late_html <- paste(readLines("_site/forecast.html", warn = FALSE), collapse = "\n")
  expect(grepl("No hourly forecast is available for today between 07:00 and 22:00", late_html, fixed = TRUE),
         "Late-night standalone render must show the empty message")
  published <- list.files("_site", recursive = TRUE, all.files = TRUE, include.dirs = TRUE)
  expect(!any(grepl("(^|/)(tests|R|scripts|[.]weather-build)(/|$)|weather[.]json|snapshot[.]json|[.]Renviron|[.]env", published)),
         "Published site must not contain fixtures, snapshots or credential files")
  Sys.setenv(WEATHER_FIXTURE_PATH = "tests/fixtures/missing.json")
  failed <- suppressWarnings(system2(quarto, c("render", "index.qmd"), stdout = TRUE, stderr = TRUE))
  expect(!is.null(attr(failed, "status")), "Quarto must abort when preparation fails")
  expect(!file.exists(dashboard_snapshot_path()), "Failed Quarto preparation cannot reuse prior data")
  cat("Dashboard full, refreshed, standalone, late-night and failure render tests passed.\n")
}

test_dashboard()
