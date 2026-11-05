source("scripts/send-pushover.R")
source("tests/helpers-weather-correctness.R")

# These httr-shaped responses exercise actual content decoding, without a socket.
fetch_response <- function(status = 200L, body = "{}", headers = list()) {
  structure(list(url = "https://example.test/weather.json", status_code = as.integer(status), content = charToRaw(body),
                 headers = headers), class = "response")
}

fetch_transport <- function(results) {
  calls <- new.env(parent = emptyenv())
  calls$requests <- list()
  calls$delays <- numeric()
  list(
    calls = calls,
    get = function(url, query, ...) {
      calls$requests <- c(calls$requests, list(list(url = url, query = query, config = list(...))))
      result <- results[[min(length(calls$requests), length(results))]]
      if (inherits(result, "error")) stop(result)
      result
    },
    sleep = function(seconds) { calls$delays <- c(calls$delays, seconds) }
  )
}

local({
  fixture <- paste(readLines("tests/fixtures/weather.json"), collapse = "\n")
  expected <- jsonlite::fromJSON(fixture, simplifyVector = FALSE)
  history_body <- '{"data":[{"dt":1,"rain":{"1h":1.2}},{"dt":2},{"dt":3,"rain":{"1h":2}}]}'
  secret <- "offline-key-MUST-NOT-APPEAR"
  forecast <- function(transport) fetch_weather(api_key = secret, get = transport$get, sleep = transport$sleep)
  history <- function(transport) fetch_historical_precipitation(
    "2026-09-21", api_key = secret, get = transport$get, sleep = transport$sleep)
  endpoints <- list(
    forecast = list(fetch = forecast, body = fixture, result = expected, timeout = 20000, path = "onecall"),
    history = list(fetch = history, body = history_body, result = 3.2, timeout = 30000, path = "onecall/timemachine")
  )
  safe_error <- function(expr, expected) {
    output <- capture.output(error <- tryCatch({ force(expr); NULL }, error = identity), type = "message")
    correctness_assert(inherits(error, "error"), paste("Expected error:", expected))
    correctness_contains(conditionMessage(error), expected)
    correctness_assert(!any(grepl(secret, c(output, conditionMessage(error)), fixed = TRUE)), "API key leaked")
    correctness_assert(is.null(conditionCall(error)), "Error call may expose request arguments")
    invisible(error)
  }
  timeout <- structure(list(message = paste("Timeout at https://example.test/?appid=", secret), call = NULL),
                       class = c("curl_error_operation_timedout", "curl_error", "error", "condition"))
  transport_error <- simpleError(paste("Failed URL with appid=", secret))

  for (endpoint in endpoints) {
    success <- fetch_response(body = endpoint$body)
    t <- fetch_transport(list(success))
    correctness_equal(endpoint$fetch(t), endpoint$result, "Successful fetch decoded")
    correctness_equal(length(t$calls$requests), 1L, "Success makes one request")
    correctness_equal(t$calls$delays, numeric(), "Success does not sleep")
    request <- t$calls$requests[[1]]
    correctness_equal(request$url, paste0("https://api.openweathermap.org/data/3.0/", endpoint$path), "Endpoint URL")
    correctness_equal(request$query$appid, secret, "API key sent only as request parameter")
    correctness_equal(request$query$units, "metric", "Metric units preserved")
    correctness_equal(request$query$lat, weather_config$lat, "Configured latitude")
    correctness_equal(request$query$lon, weather_config$lon, "Configured longitude")
    correctness_equal(request$config[[1]]$options$timeout_ms, endpoint$timeout, "Request timeout bounded")
    if (endpoint$path == "onecall/timemachine") {
      correctness_equal(request$query$dt, as.numeric(as.POSIXct(as.Date("2026-09-21"), tz = "UTC")),
                        "Historical UTC timestamp preserved")
    }

    # Every permanent HTTP failure stops immediately, including codes outside the old allowlist.
    for (status in c(400L, 401L, 402L, 403L, 404L, 405L, 410L, 422L, 301L, 204L)) {
      t <- fetch_transport(list(fetch_response(status, paste("provider echoed", secret)), success))
      safe_error(endpoint$fetch(t), paste("HTTP", status))
      correctness_equal(length(t$calls$requests), 1L, "Permanent HTTP failure stops promptly")
      correctness_equal(t$calls$delays, numeric(), "Permanent failure never sleeps")
    }
    # Each retryable category both recovers and has a hard total-attempt budget.
    for (failure in list(timeout, transport_error, fetch_response(408), fetch_response(429),
                         fetch_response(500), fetch_response(502), fetch_response(503), fetch_response(504))) {
      t <- fetch_transport(list(failure, success))
      correctness_equal(endpoint$fetch(t), endpoint$result, "Transient failure recovers")
      correctness_equal(length(t$calls$requests), 2L, "Recovery stops further retries")
      correctness_equal(t$calls$delays, 1, "First retry delay")

      t <- fetch_transport(list(failure))
      safe_error(endpoint$fetch(t), "attempt 4 of 4")
      correctness_equal(length(t$calls$requests), 4L, "Transient failures exhaust four attempts")
      correctness_equal(t$calls$delays, c(1, 2, 4), "No sleep after final attempt")
    }
    t <- fetch_transport(list(timeout, fetch_response(429), fetch_response(503), success))
    correctness_equal(endpoint$fetch(t), endpoint$result, "Recovery on final allowed attempt")
    correctness_equal(length(t$calls$requests), 4L, "Final allowed recovery count")
    correctness_equal(t$calls$delays, c(1, 2, 4), "Mixed failure backoff")
    t <- fetch_transport(list(fetch_response(503), fetch_response(401), success))
    safe_error(endpoint$fetch(t), "HTTP 401; attempt 2 of 4")
    correctness_equal(length(t$calls$requests), 2L, "Permanent failure after transient stops")

    for (status in c(429, 503)) {
      t <- fetch_transport(list(fetch_response(status, headers = list(`retry-after` = "5")), success))
      correctness_equal(endpoint$fetch(t), endpoint$result, "Retry-After recovery")
      correctness_equal(t$calls$delays, 5, "Provider Retry-After honored")
      t <- fetch_transport(list(fetch_response(status, headers = list(`retry-after` = "86400")), success))
      safe_error(endpoint$fetch(t), "30-second retry limit")
      correctness_equal(length(t$calls$requests), 1L, "Long provider wait stops within budget")
      correctness_equal(t$calls$delays, numeric(), "Long provider wait never sleeps")
    }
    for (header in c("garbage", "-10", "Inf", "Wed, 01 Jan 2020 00:00:00 GMT")) {
      t <- fetch_transport(list(fetch_response(429, headers = list(`retry-after` = header)), success))
      correctness_equal(endpoint$fetch(t), endpoint$result, "Invalid or past Retry-After recovers")
      correctness_equal(t$calls$delays, 1, "Invalid or past Retry-After uses normal backoff")
    }
    future_header <- format(Sys.time() + 86400, "%a, %d %b %Y %H:%M:%S GMT", tz = "UTC", usetz = FALSE)
    t <- fetch_transport(list(fetch_response(429, headers = list(`retry-after` = future_header))))
    safe_error(endpoint$fetch(t), "30-second retry limit")

    for (body in c("", "<html>upstream unavailable</html>", paste0('{"secret":"', secret, '"'))) {
      t <- fetch_transport(list(fetch_response(body = body), success))
      safe_error(endpoint$fetch(t), "invalid JSON")
      correctness_equal(length(t$calls$requests), 1L, "Invalid JSON is not retried")
    }
  }

  # Structurally malformed forecasts cannot reach frame conversion or notifications.
  malformed <- c(
    'null', '[]', '1', '{}',
    '{"current":{},"hourly":{},"daily":[]}',
    '{"current":{},"hourly":[null],"daily":[]}',
    '{"current":{},"hourly":[1],"daily":[]}',
    '{"current":{},"hourly":[{"temp":"warm"}],"daily":[]}',
    '{"current":{},"hourly":[{"dt":[1,2]}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":2}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":null}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":{}}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":{"1h":null}}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":{"1h":-1}}],"daily":[]}',
    '{"current":{},"hourly":[{"rain":{"1h":"2"}}],"daily":[]}',
    '{"current":{},"hourly":[{"weather":[1]}],"daily":[]}',
    '{"current":{},"hourly":[{"weather":[{"description":2}]}],"daily":[]}',
    '{"current":{},"hourly":[{"pop":1e400}],"daily":[]}',
    '{"current":{},"hourly":[],"daily":[{"temp":2}]}',
    '{"current":{},"hourly":[],"daily":[{"temp":{"max":[1,2]}}]}',
    '{"current":null,"hourly":[],"daily":[]}',
    '{"current":{"temp":"warm"},"hourly":[],"daily":[]}',
    '{"current":{},"hourly":[],"daily":[],"hourly":[]}',
    '{"current":{},"hourly":[{"temp":1,"temp":2}],"daily":[]}'
  )
  for (body in malformed) {
    t <- fetch_transport(list(fetch_response(body = body)))
    safe_error(forecast(t), "OpenWeather")
    correctness_equal(length(t$calls$requests), 1L, "Malformed forecast fails without retry")
  }
  minimal <- '{"current":{},"hourly":[{"dt":1790056800,"temp":null}],"daily":[{"dt":1790056800}]}'
  t <- fetch_transport(list(fetch_response(body = minimal)))
  partial <- forecast(t)
  for (slot in c("morning", "afternoon")) {
    text <- notification_text(partial, delivery_slot = slot, now = correctness_time("2026-09-22 05:00:00"))
    correctness_contains(text, "Unavailable", "Partial forecast retains notification fallbacks")
    correctness_assert(!grepl("\\b(NA|NaN|Inf)\\b", text), "No malformed numbers in notification")
  }
  t <- fetch_transport(list(fetch_response(body = '{"current":{},"hourly":[],"daily":[]}')))
  correctness_equal(nrow(hourly_frame(forecast(t))), 0L, "Empty forecast arrays remain supported")

  for (body in c('{}', '{"data":null}', '{"data":[]}')) {
    correctness_equal(history(fetch_transport(list(fetch_response(body = body)))), NA_real_,
                      "Missing historical observations mean unavailable, never dry")
  }
  correctness_equal(history(fetch_transport(list(fetch_response(body = '{"data":[{"dt":1}]}')))),
                    0, "An observation without rain preserves dry-weather semantics")
  for (body in c('null', '[]', '{"data":2}', '{"data":{}}', '{"data":[null]}', '{"data":[1]}',
                 '{"data":[{}]}', '{"data":[{"rain":{"1h":1}}]}', '{"data":[{"dt":"wrong"}]}',
                 '{"data":[{"dt":1,"rain":2}]}', '{"data":[{"dt":1,"rain":{}}]}',
                 '{"data":[{"dt":1,"rain":null}]}',
                 '{"data":[{"dt":1,"rain":{"1h":null}}]}', '{"data":[{"dt":1,"rain":{"1h":"wet"}}]}',
                 '{"data":[{"dt":1,"rain":{"1h":[1,2]}}]}', '{"data":[{"dt":1,"rain":{"1h":-1}}]}',
                 '{"data":[{"dt":1,"rain":{"1h":1e400}}]}',
                 '{"data":[{"dt":1,"rain":{"1h":2}},{"dt":2,"rain":{"1h":null}}]}',
                 '{"data":[{"dt":1,"rain":{"1h":1e308}},{"dt":2,"rain":{"1h":1e308}}]}')) {
    t <- fetch_transport(list(fetch_response(body = body)))
    safe_error(history(t), "historical precipitation field")
    correctness_equal(length(t$calls$requests), 1L, "Malformed history fails without retry")
  }

  # Exercise the real notification consumer using the real fetchers and fake HTTP.
  variables <- c("OPENWEATHERMAP_APIKEY", "PUSHOVER_APPKEY", "PUSHOVER_USERKEY", "GITHUB_STEP_SUMMARY")
  saved <- Sys.getenv(variables, unset = NA_character_)
  on.exit({
    Sys.unsetenv(variables[is.na(saved)])
    if (any(!is.na(saved))) do.call(Sys.setenv, as.list(saved[!is.na(saved)]))
  })
  Sys.setenv(OPENWEATHERMAP_APIKEY = secret, PUSHOVER_APPKEY = "offline", PUSHOVER_USERKEY = "offline")
  summary <- tempfile()
  state <- tempfile()
  on.exit(unlink(c(summary, state)), add = TRUE)
  Sys.setenv(GITHUB_STEP_SUMMARY = summary)
  Sys.unsetenv("OPENWEATHERMAP_APIKEY")
  t <- fetch_transport(list(fetch_response(body = fixture)))
  safe_error(fetch_weather(get = t$get, sleep = t$sleep), "OPENWEATHERMAP_APIKEY is not configured")
  safe_error(fetch_historical_precipitation("2026-09-21", get = t$get, sleep = t$sleep),
             "OPENWEATHERMAP_APIKEY is not configured")
  correctness_equal(length(t$calls$requests), 0L, "Missing credentials fail before HTTP or retries")
  correctness_equal(t$calls$delays, numeric(), "Missing credentials never sleep")
  Sys.setenv(OPENWEATHERMAP_APIKEY = secret)
  args <- list(mode = "scheduled", slot = "morning", state = state)
  now <- correctness_time("2026-09-22 05:00:00")
  sent <- character()
  send <- function(message, title) {
    sent <<- c(sent, message)
    list(request_id = "offline-acceptance", attempts = 1L)
  }
  bad_forecast <- fetch_transport(list(fetch_response(401, secret)))
  safe_error(run_notifications(args, now = now, fetch = function(config) forecast(bad_forecast),
                               send = send), "HTTP 401")
  correctness_equal(sent, character(), "Forecast failure prevents notifications")
  correctness_assert(!file.exists(state), "Forecast failure cannot record acceptance")
  correctness_assert(!any(grepl(secret, readLines(summary), fixed = TRUE)), "Summary must not expose API keys")

  warnings <- character()
  bad_history <- fetch_transport(list(fetch_response(body = '{"data":[{"dt":1,"rain":{"1h":"wet"}}]}')))
  withCallingHandlers(
    run_notifications(args, now = now,
      fetch = function(config) forecast(fetch_transport(list(fetch_response(body = fixture)))),
      historical = function(date, config) history(bad_history), send = send, clock = function() now),
    warning = function(w) { warnings <<- c(warnings, conditionMessage(w)); invokeRestart("muffleWarning") }
  )
  correctness_contains(warnings, "Historical precipitation unavailable")
  correctness_contains(sent, "Precipitation yesterday: Unavailable")
  correctness_equal(length(sent), 1L, "Optional history failure permits morning notification")
  correctness_assert(!any(grepl(secret, warnings, fixed = TRUE)), "History warning must not expose API keys")
  correctness_assert(file.exists(state), "Successful send still records acceptance")
})

cat("Offline weather fetching tests passed.\n")
