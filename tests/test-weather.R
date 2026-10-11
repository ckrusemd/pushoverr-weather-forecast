source("R/weather.R")
source("tests/helpers-weather-correctness.R")

local({
  old_tz <- Sys.getenv("TZ", unset = NA_character_)
  on.exit(if (is.na(old_tz)) Sys.unsetenv("TZ") else Sys.setenv(TZ = old_tz))
  Sys.setenv(TZ = "UTC")
  now <- correctness_time("2026-09-22 05:00:00")
  payload <- correctness_payload()
  text <- notification_text(payload, now = now)
  correctness_contains(text, "Weather at 08:00: clear sky, 18°C")
  correctness_contains(text, "UV index tops at: 2.0 at 00:00")
  correctness_contains(text, "RH below 60% at 21°C: 7-22")
  correctness_contains(text, "Precipitation yesterday: Unavailable")
  correctness_contains(notification_text(payload, precipitation_yesterday_mm = 3.2, now = now),
                       "Precipitation yesterday: 3.2 mm")

  late <- correctness_payload(hours = 11:47)
  late_text <- notification_text(late, now = correctness_time("2026-09-22 11:15:00"))
  correctness_contains(late_text, "Weather at 11:00:")
  correctness_assert(!grepl("Weather at 08:00:", late_text, fixed = TRUE), "Late forecast mislabeled 08:00")

  # A UTC timestamp on the previous date belongs to today in Copenhagen.
  midnight <- correctness_time("2026-09-21 22:30:00", "UTC")
  near_midnight <- list(current = list(), hourly = list(correctness_hour(midnight)),
                        daily = list(list(dt = as.numeric(midnight), temp = list(max = 24))))
  correctness_equal(daily_frame(near_midnight)$date, as.Date("2026-09-22"), "Daily Copenhagen midnight")
  correctness_equal(nrow(best_outdoor_hour(hourly_frame(near_midnight), now = midnight)), 1L,
                    "Best hour Copenhagen midnight")
  correctness_contains(notification_text(near_midnight, now = midnight), "Weather at 00:30:")
  correctness_contains(notification_text(near_midnight, now = midnight), "Today's high: 24°C")

  other_day <- near_midnight
  other_day$hourly <- list(correctness_hour(correctness_time("2026-09-21 21:30:00", "UTC"), temp = 20),
                          correctness_hour(midnight, temp = 17))
  best <- best_outdoor_hour(hourly_frame(other_day), now = midnight)
  correctness_equal(best$temp, 17, "Best hour uses local date rather than UTC")
  config <- weather_config
  config$timezone <- "America/New_York"
  correctness_equal(daily_frame(near_midnight, config$timezone)$date, as.Date("2026-09-21"),
                    "Explicit configured daily timezone")
  correctness_equal(best_outdoor_hour(hourly_frame(other_day), now = midnight, config = config)$temp,
                    20, "Explicit configured best-hour timezone")
  correctness_contains(notification_text(near_midnight, config = config, now = midnight),
                       "Weather at 18:30:")

  # Check real sunlight calculation and clock jumps across both DST boundaries.
  for (date in c("2026-03-29", "2026-10-25")) {
    boundary_now <- correctness_time(paste(date, "00:30:00"))
    sun <- sunrise_sunset_change(now = boundary_now)
    expected <- suncalc::getSunlightTimes(
      date = as.Date(date) + c(-1L, 0L), lat = weather_config$lat,
      lon = weather_config$lon, tz = weather_config$timezone
    )
    clock_seconds <- function(time) {
      as.integer(format(time, "%H", tz = weather_config$timezone)) * 3600 +
        as.integer(format(time, "%M", tz = weather_config$timezone)) * 60 +
        as.integer(format(time, "%S", tz = weather_config$timezone))
    }
    correctness_equal(sun$sunrise_change,
                      format_signed_duration(diff(clock_seconds(expected$sunrise))),
                      paste("Sunrise DST clock delta", date))
    correctness_equal(sun$sunset_change,
                      format_signed_duration(diff(clock_seconds(expected$sunset))),
                      paste("Sunset DST clock delta", date))
    boundary_payload <- correctness_payload(date = date, hours = 0:30)
    correctness_contains(notification_text(boundary_payload, now = boundary_now), "Weather at 08:00:")
  }
  # The injected sunlight result is intentionally UTC: formatting must use config.
  captured_dates <- NULL
  fake_sun <- function(date, lat, lon, tz) {
    captured_dates <<- date
    data.frame(sunrise = correctness_time(c("2026-03-28 05:00:00", "2026-03-29 05:00:00"), "UTC"),
               sunset = correctness_time(c("2026-03-28 17:00:00", "2026-03-29 17:00:00"), "UTC"))
  }
  sun <- sunrise_sunset_change(now = correctness_time("2026-03-28 23:30:00", "UTC"),
                              get_sunlight_times = fake_sun)
  correctness_equal(captured_dates, as.Date(c("2026-03-28", "2026-03-29")), "Sunlight local date")
  correctness_equal(sun$sunrise_change, "+60:00", "Sunrise uses configured clock")
  missing_sun <- function(date, lat, lon, tz) {
    data.frame(sunrise = as_local_time(c(NA_real_, NA_real_)),
               sunset = as_local_time(c(NA_real_, NA_real_)))
  }
  correctness_equal(sunrise_sunset_change(now = now, get_sunlight_times = missing_sun)$sunrise_change,
                    "Unavailable", "Missing sunlight has no nonfinite duration")

  empty <- list(current = list(), hourly = list(), daily = list())
  correctness_equal(nrow(hourly_frame(empty)), 0L, "Empty hourly frame")
  correctness_equal(nrow(daily_frame(empty)), 0L, "Empty daily frame")
  correctness_assert(inherits(hourly_frame(empty)$time, "POSIXct"), "Typed empty hourly time")
  correctness_assert(inherits(daily_frame(empty)$date, "Date"), "Typed empty daily date")
  correctness_equal(nrow(best_outdoor_hour(hourly_frame(empty), now = now)), 0L, "Empty best hour")
  undated <- list(hourly = list(correctness_hour(now)))
  undated$hourly[[1]]$dt <- NULL
  correctness_equal(nrow(best_outdoor_hour(hourly_frame(undated), now = now)), 0L, "Undated best hour unavailable")
  for (slot in c("morning", "afternoon")) {
    empty_text <- notification_text(empty, delivery_slot = slot, now = now)
    correctness_contains(empty_text, "Weather: Unavailable")
    correctness_contains(empty_text, "Rain next 24h: Unavailable")
    correctness_contains(empty_text, "RH below 60% at 21°C: Unavailable")
    correctness_assert(!grepl("\\b(NA|NaN|Inf|-Inf)\\b", empty_text), "No nonfinite values in empty text")
  }
  no_daily <- payload
  no_daily$daily <- NULL
  correctness_contains(notification_text(no_daily, now = now), "Today's high: Unavailable")
  correctness_contains(notification_text(no_daily, now = now), "Weather at 08:00:")
  no_hourly <- payload
  no_hourly$hourly <- NULL
  correctness_contains(notification_text(no_hourly, now = now), "Weather: Unavailable")
  correctness_contains(notification_text(no_hourly, now = now), "Today's high: 22°C")

  missing <- payload
  missing$hourly <- lapply(missing$hourly, function(row) {
    row$uvi <- row$humidity <- row$pop <- row$temp <- row$feels_like <- row$wind_speed <- row$clouds <- NULL
    row$weather <- NULL
    row$rain <- list(`1h` = NA_real_)
    row
  })
  missing$daily <- list(list(dt = payload$daily[[1]]$dt))
  correctness_equal(nrow(hourly_frame(missing)), 48L, "Missing fields retain rows")
  correctness_equal(nrow(best_outdoor_hour(hourly_frame(missing), now = now)), 0L, "All-NA best hour")
  for (slot in c("morning", "afternoon")) {
    missing_text <- notification_text(missing, delivery_slot = slot, now = now)
    correctness_contains(missing_text, "Unavailable")
    correctness_contains(missing_text, "Rain next 24h: Unavailable")
    correctness_contains(missing_text, "RH below 60% at 21°C: Unavailable")
    correctness_assert(!grepl("\\b(NA|NaN|Inf|-Inf)\\b", missing_text), "No nonfinite values for missing fields")
  }
  uv_missing <- payload
  uv_missing$hourly <- lapply(uv_missing$hourly, function(row) { row$uvi <- NA_real_; row })
  correctness_contains(notification_text(uv_missing, now = now), "UV index tops at: Unavailable")
  correctness_contains(notification_text(uv_missing, delivery_slot = "afternoon", now = now),
                       "UV remaining tops at: Unavailable")
  humidity_missing <- payload
  humidity_missing$hourly <- lapply(humidity_missing$hourly, function(row) { row$humidity <- NULL; row })
  correctness_contains(notification_text(humidity_missing, now = now),
                       "RH below 60% at 21°C: Unavailable")
  humidity_missing$hourly <- lapply(humidity_missing$hourly, function(row) { row$humidity <- NA_real_; row })
  correctness_contains(notification_text(humidity_missing, delivery_slot = "afternoon", now = now),
                       "RH below 60% at 21°C: Unavailable")
  tomorrow_only <- correctness_payload(date = "2026-09-23")
  correctness_contains(notification_text(tomorrow_only, now = now), "Weather: Unavailable")
  correctness_contains(notification_text(tomorrow_only, now = now), "Today's high: Unavailable")

  # Tomorrow's rain counts toward the next 24h; tomorrow's heat/UV do not
  # count toward the remaining part of today. Past hours and row 25 are excluded.
  cross_midnight <- correctness_payload(hours = 22:48)
  cross_midnight$hourly <- lapply(seq_along(cross_midnight$hourly), function(i) {
    time <- cross_midnight$hourly[[i]]$dt
    correctness_hour(as_local_time(time), temp = if (i >= 3L) 40 else 18,
                     rain = if (i == 1L || i == 26L || i == 27L) 100 else 1,
                     uv = if (i >= 3L) 10 else 2)
  })
  evening <- notification_text(cross_midnight, delivery_slot = "afternoon",
                               now = correctness_time("2026-09-22 23:00:00"))
  correctness_contains(evening, "Rain next 24h: 24.0 mm")
  correctness_contains(evening, "Rest-of-day high: 18°C")
  correctness_contains(evening, "UV remaining tops at: 2.0 at 23:00")
  expired <- notification_text(cross_midnight, delivery_slot = "afternoon",
                               now = correctness_time("2026-09-22 23:30:00"))
  correctness_contains(expired, "Weather: Unavailable")
  correctness_contains(expired, "Rest-of-day high: Unavailable")
  correctness_contains(expired, "PoP remaining: Unavailable")
  correctness_equal(connected_hour_ranges(c(NA, 7, 8, 10)), "7-8, 10", "NA hours excluded")
  correctness_error(notification_text(payload, delivery_slot = "night", now = now), "Invalid delivery slot")
})

cat("Weather correctness tests passed.\n")
