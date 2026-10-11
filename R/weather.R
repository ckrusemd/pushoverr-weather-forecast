weather_config <- list(
  location_name = "Copenhagen",
  lat = 55.771979,
  lon = 12.494786,
  timezone = "Europe/Copenhagen"
)

require_weather_key <- function() {
  key <- Sys.getenv("OPENWEATHERMAP_APIKEY")
  if (!nzchar(trimws(key))) stop("OPENWEATHERMAP_APIKEY is not configured.", call. = FALSE)
  key
}

fetch_weather <- function(config = weather_config, api_key = require_weather_key()) {
  response <- httr::RETRY("GET",
    "https://api.openweathermap.org/data/3.0/onecall",
    query = list(lat = config$lat, lon = config$lon, appid = api_key, units = "metric"),
    times = 4, pause_base = 1, terminate_on = c(400, 401, 403, 404), httr::timeout(20)
  )
  if (httr::status_code(response) != 200) {
    stop(sprintf("OpenWeather request failed (%s).", httr::status_code(response)), call. = FALSE)
  }
  payload <- jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  required <- c("current", "hourly", "daily")
  missing <- setdiff(required, names(payload))
  if (length(missing)) stop(sprintf("OpenWeather response is missing: %s", paste(missing, collapse = ", ")), call. = FALSE)
  payload
}

weather_description <- function(weather) {
  description <- if (length(weather)) weather[[1]]$description else NULL
  if (length(description) == 1L && !is.na(description) && nzchar(description)) description else "Unavailable"
}

as_local_time <- function(seconds, tz = weather_config$timezone) as.POSIXct(seconds, origin = "1970-01-01", tz = tz)

hourly_frame <- function(payload, tz = weather_config$timezone) {
  empty <- data.frame(
    time = as_local_time(numeric(), tz), temp = numeric(), feels_like = numeric(),
    pop = numeric(), uv_index = numeric(), wind_speed = numeric(), clouds = numeric(),
    humidity = numeric(), rain_mm = numeric(), description = character()
  )
  rows <- lapply(payload$hourly, function(x) data.frame(
    time = as_local_time(x$dt %||% NA_real_, tz), temp = x$temp %||% NA_real_,
    feels_like = x$feels_like %||% NA_real_, pop = (x$pop %||% NA_real_) * 100,
    uv_index = x$uvi %||% NA_real_, wind_speed = x$wind_speed %||% NA_real_,
    clouds = x$clouds %||% NA_real_,
    humidity = x$humidity %||% NA_real_, rain_mm = if (is.null(x$rain)) 0 else (x$rain$`1h` %||% 0),
    description = weather_description(x$weather), stringsAsFactors = FALSE
  ))
  if (length(rows)) do.call(rbind, rows) else empty
}

`%||%` <- function(x, y) if (is.null(x)) y else x

daily_frame <- function(payload, tz = weather_config$timezone) {
  empty <- data.frame(
    date = as.Date(character()), sunrise = as_local_time(numeric(), tz), sunset = as_local_time(numeric(), tz),
    min_temp = numeric(), max_temp = numeric(), pop = numeric(), wind_speed = numeric(), description = character()
  )
  rows <- lapply(payload$daily, function(x) data.frame(
    date = as.Date(as_local_time(x$dt %||% NA_real_, tz), tz = tz),
    sunrise = as_local_time(x$sunrise %||% NA_real_, tz), sunset = as_local_time(x$sunset %||% NA_real_, tz),
    min_temp = x$temp$min %||% NA_real_, max_temp = x$temp$max %||% NA_real_, pop = (x$pop %||% NA_real_) * 100,
    wind_speed = x$wind_speed %||% NA_real_, description = weather_description(x$weather), stringsAsFactors = FALSE
  ))
  if (length(rows)) do.call(rbind, rows) else empty
}

outdoor_score <- function(hourly) {
  # A transparent, deliberately simple score: warmth, dry conditions and gentle wind win.
  pmax(0, pmin(100, 100 - abs(hourly$temp - 20) * 4 - hourly$pop * 0.55 - pmax(hourly$wind_speed - 3, 0) * 7 - hourly$clouds * 0.08))
}

relative_humidity_at <- function(temperature_c, relative_humidity, reference_c = 21) {
  # Infer dew point from the forecast RH, then calculate RH if the air is warmed
  # or cooled to the requested reference temperature.
  valid <- is.finite(temperature_c) & is.finite(relative_humidity) & relative_humidity > 0
  result <- rep(NA_real_, length(temperature_c))
  gamma <- log(relative_humidity[valid] / 100) + (17.625 * temperature_c[valid]) / (243.04 + temperature_c[valid])
  dew_point <- 243.04 * gamma / (17.625 - gamma)
  result[valid] <- 100 * exp((17.625 * dew_point) / (243.04 + dew_point) - (17.625 * reference_c) / (243.04 + reference_c))
  pmin(100, pmax(0, result))
}

connected_hour_ranges <- function(hours) {
  hours <- hours[is.finite(hours)]
  hours <- sort(unique(as.integer(hours)))
  if (!length(hours)) return("none")
  groups <- cumsum(c(TRUE, diff(hours) != 1))
  pieces <- split(hours, groups)
  paste(vapply(pieces, function(x) if (length(x) == 1) as.character(x) else sprintf("%d-%d", min(x), max(x)), character(1)), collapse = ", ")
}

format_signed_duration <- function(seconds) {
  if (!length(seconds) || !is.finite(seconds)) return("Unavailable")
  sign <- if (seconds >= 0) "+" else "-"
  total_seconds <- round(abs(seconds))
  sprintf("%s%d:%02d", sign, total_seconds %/% 60, total_seconds %% 60)
}

sunrise_sunset_change <- function(config = weather_config, now = Sys.time(),
                                get_sunlight_times = suncalc::getSunlightTimes) {
  today <- as.Date(now, tz = config$timezone)
  sun <- get_sunlight_times(date = c(today - 1, today), lat = config$lat,
                                    lon = config$lon, tz = config$timezone)
  clock_seconds <- function(x) {
    as.integer(format(x, "%H", tz = config$timezone)) * 3600 +
      as.integer(format(x, "%M", tz = config$timezone)) * 60 + as.integer(format(x, "%S", tz = config$timezone))
  }
  clock_delta <- function(previous, current) {
    delta <- clock_seconds(current) - clock_seconds(previous)
    if (!is.finite(delta)) return(NA_real_)
    if (delta > 12 * 3600) delta <- delta - 24 * 3600
    if (delta < -12 * 3600) delta <- delta + 24 * 3600
    delta
  }
  list(
    sunrise = sun$sunrise[2],
    sunrise_change = format_signed_duration(clock_delta(sun$sunrise[1], sun$sunrise[2])),
    sunset = sun$sunset[2],
    sunset_change = format_signed_duration(clock_delta(sun$sunset[1], sun$sunset[2]))
  )
}

fetch_historical_precipitation <- function(date, config = weather_config,
                                            api_key = require_weather_key()) {
  timestamp <- as.numeric(as.POSIXct(as.Date(date), tz = "UTC"))
  response <- httr::RETRY("GET", "https://api.openweathermap.org/data/3.0/onecall/timemachine",
                          query = list(lat = config$lat, lon = config$lon, dt = timestamp,
                                       appid = api_key, units = "metric"),
                          times = 3, pause_base = 1, httr::timeout(30))
  httr::stop_for_status(response)
  payload <- jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (!is.list(payload$data)) return(NA_real_)
  sum(vapply(payload$data, function(x) {
    if (is.null(x$rain)) 0 else as.numeric(x$rain$`1h` %||% 0)
  }, numeric(1)), na.rm = TRUE)
}

best_outdoor_hour <- function(hourly, now = Sys.time(), config = weather_config) {
  hourly <- hourly[which(!is.na(hourly$time)), , drop = FALSE]
  today <- hourly[which(as.Date(hourly$time, tz = config$timezone) == as.Date(now, tz = config$timezone)), , drop = FALSE]
  if (!nrow(today)) today <- hourly
  today$score <- outdoor_score(today)
  today[which.max(today$score), , drop = FALSE]
}

notification_text <- function(payload, config = weather_config,
                              precipitation_yesterday_mm = NA_real_,
                              delivery_slot = "morning", now = Sys.time()) {
  if (!delivery_slot %in% c("morning", "afternoon")) stop("Invalid delivery slot.", call. = FALSE)
  timezone <- config$timezone
  date <- as.Date(now, tz = timezone)
  hourly <- hourly_frame(payload, timezone)
  hourly <- hourly[order(hourly$time, na.last = TRUE), , drop = FALSE]
  today <- hourly[which(as.Date(hourly$time, tz = timezone) == date), , drop = FALSE]
  daily <- daily_frame(payload, timezone)
  daily <- daily[which(daily$date == date), , drop = FALSE]

  number <- function(value, pattern) {
    if (length(value) && is.finite(value[[1]])) sprintf(pattern, value[[1]]) else "Unavailable"
  }
  clock <- function(time) {
    if (length(time) && !is.na(time[[1]])) format(time[[1]], "%H:%M", tz = timezone) else "Unavailable"
  }
  peak <- function(frame, column, pattern) {
    available <- frame[which(is.finite(frame[[column]])), , drop = FALSE]
    if (!nrow(available)) return("Unavailable")
    row <- available[which.max(available[[column]]), , drop = FALSE]
    sprintf("%s at %s", number(row[[column]], pattern), clock(row$time))
  }
  high <- function(values) {
    values <- values[is.finite(values)]
    if (length(values)) number(max(values), "%.0f°C") else "Unavailable"
  }
  dry_ranges <- function(frame) {
    humidity <- relative_humidity_at(frame$temp, frame$humidity)
    if (!any(is.finite(humidity))) return("Unavailable")
    hours <- as.integer(format(frame$time, "%H", tz = timezone))
    connected_hour_ranges(hours[which(is.finite(humidity) & humidity < 60 & hours >= 7 & hours <= 22)])
  }
  weather_line <- function(row) {
    if (!nrow(row)) return("Weather: Unavailable")
    sprintf("Weather at %s: %s, %s (feels %s)", clock(row$time), row$description[[1]],
            number(row$temp, "%.0f°C"), number(row$feels_like, "%.0f°C"))
  }
  sun <- sunrise_sunset_change(config, now = now)
  next_day <- head(hourly[which(hourly$time >= now), , drop = FALSE], 24)
  rain <- if (nrow(next_day) && all(is.finite(next_day$rain_mm))) sum(next_day$rain_mm) else NA_real_
  rain_text <- number(rain, "%.1f mm")

  if (delivery_slot == "afternoon") {
    remaining <- today[which(today$time >= now), , drop = FALSE]
    return(paste(
      weather_line(head(remaining, 1)),
      paste("Rest-of-day high:", high(remaining$temp)),
      paste("PoP remaining:", peak(remaining, "pop", "%.0f%%")),
      paste("UV remaining tops at:", peak(remaining, "uv_index", "%.1f")),
      paste("Cloud cover:", number(remaining$clouds, "%.0f%%")),
      sprintf("Sunset: %s (%s)", clock(sun$sunset), sun$sunset_change),
      paste("Rain next 24h:", rain_text),
      paste("RH below 60% at 21°C:", dry_ranges(remaining)),
      sep = "\n"
    ))
  }

  target <- as.POSIXct(paste(date, "08:00:00"), tz = timezone)
  at_eight <- today[which.min(abs(as.numeric(difftime(today$time, target, units = "secs")))), , drop = FALSE]
  paste(
    weather_line(at_eight),
    paste("Today's high:", number(daily$max_temp, "%.0f°C")),
    paste("PoP:", peak(today, "pop", "%.0f%%")),
    paste("UV index tops at:", peak(today, "uv_index", "%.1f")),
    paste("Cloud cover:", number(at_eight$clouds, "%.0f%%")),
    sprintf("Sunrise: %s (%s)", clock(sun$sunrise), sun$sunrise_change),
    sprintf("Sunset: %s (%s)", clock(sun$sunset), sun$sunset_change),
    paste("Precipitation yesterday:", number(precipitation_yesterday_mm, "%.1f mm")),
    paste("Rain next 24h:", rain_text),
    paste("RH below 60% at 21°C:", dry_ranges(today)),
    sep = "\n"
  )
}
