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

openweather_json <- function(path, query, label, timeout_seconds,
                             get = httr::GET, sleep = Sys.sleep) {
  # Four total attempts; transport errors, 408, 429 and 5xx may recover.
  # Never echo transport messages, URLs or response bodies: they can contain keys.
  for (attempt in seq_len(4L)) {
    response <- tryCatch(get(paste0("https://api.openweathermap.org/data/3.0/", path),
                             query = query, httr::timeout(timeout_seconds)), error = identity)
    if (inherits(response, "error")) {
      reason <- if (inherits(response, "curl_error_operation_timedout")) "timed out" else "transport error"
      failure <- sprintf("%s request failed (%s; attempt %d of 4).", label, reason, attempt)
    } else {
      status <- httr::status_code(response)
      if (status == 200L) {
        return(tryCatch(
          jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"),
                             simplifyVector = FALSE),
          error = function(e) stop(sprintf("%s response contains invalid JSON.", label), call. = FALSE)
        ))
      }
      failure <- sprintf("%s request failed (HTTP %d; attempt %d of 4).", label, status, attempt)
      transient <- status %in% c(408L, 429L) || (status >= 500L && status <= 599L)
      if (!transient) stop(failure, call. = FALSE)
    }
    if (attempt == 4L) stop(failure, call. = FALSE)
    delay <- 2^(attempt - 1L)
    if (!inherits(response, "error")) {
      retry_after <- httr::headers(response)[["retry-after"]]
      if (!is.null(retry_after)) {
        seconds <- suppressWarnings(as.numeric(retry_after))
        if (!is.finite(seconds)) {
          seconds <- as.numeric(httr::parse_http_date(retry_after)) - as.numeric(Sys.time())
        }
        if (length(seconds) == 1L && is.finite(seconds) && seconds >= 0) {
          # Do not retry earlier than requested or let the provider impose an unbounded wait.
          if (seconds > 30) stop(sprintf("%s Retry-After exceeds the 30-second retry limit.", label), call. = FALSE)
          delay <- max(delay, seconds)
        }
      }
    }
    sleep(delay)
  }
}

weather_object <- function(value) {
  is.list(value) && !is.null(names(value)) && !anyDuplicated(names(value)) && all(nzchar(names(value)))
}

weather_array <- function(value) is.list(value) && is.null(names(value))

validate_forecast_response <- function(payload) {
  fail <- function(field) stop(sprintf("Invalid OpenWeather forecast field: %s.", field), call. = FALSE)
  number <- function(value, field) {
    if (!is.null(value) && (!is.numeric(value) || length(value) != 1L || !is.finite(value))) fail(field)
  }
  fields <- function(row, required, prefix) {
    if (!weather_object(row)) fail(prefix)
    for (field in required) number(row[[field]], paste(prefix, field, sep = "."))
    if (!is.null(row$weather)) {
      if (!weather_array(row$weather)) fail(paste0(prefix, ".weather"))
      for (entry in row$weather) {
        if (!weather_object(entry)) fail(paste0(prefix, ".weather"))
        description <- entry$description
        if (!is.null(description) && (!is.character(description) ||
            length(description) != 1L || is.na(description))) fail(paste0(prefix, ".weather.description"))
      }
    }
  }
  if (!weather_object(payload)) fail("payload")
  missing <- setdiff(c("current", "hourly", "daily"), names(payload))
  if (length(missing)) stop(sprintf("OpenWeather response is missing: %s", paste(missing, collapse = ", ")), call. = FALSE)
  # Missing individual values remain available to the notification's fallback formatting.
  # Dashboard preparation applies its own stricter requirements before rendering.
  fields(payload$current, c("dt", "temp", "feels_like"), "current")
  for (section in c("hourly", "daily")) {
    if (!weather_array(payload[[section]])) fail(section)
    for (i in seq_along(payload[[section]])) {
      row <- payload[[section]][[i]]
      prefix <- sprintf("%s[%d]", section, i)
      if (section == "hourly") {
        fields(row, c("dt", "temp", "feels_like", "pop", "uvi", "wind_speed", "clouds", "humidity"), prefix)
        if ("rain" %in% names(row)) {
          if (!weather_object(row$rain)) fail(paste0(prefix, ".rain"))
          if (is.null(row$rain$`1h`)) fail(paste0(prefix, ".rain.1h"))
          number(row$rain$`1h`, paste0(prefix, ".rain.1h"))
          if (row$rain$`1h` < 0) fail(paste0(prefix, ".rain.1h"))
        }
      } else {
        fields(row, c("dt", "sunrise", "sunset", "pop", "wind_speed"), prefix)
        if (!is.null(row$temp)) {
          if (!weather_object(row$temp)) fail(paste0(prefix, ".temp"))
          for (field in c("min", "max")) number(row$temp[[field]], paste(prefix, "temp", field, sep = "."))
        }
      }
    }
  }
  invisible(payload)
}

fetch_weather <- function(config = weather_config, api_key = require_weather_key(),
                          get = httr::GET, sleep = Sys.sleep) {
  force(api_key)
  payload <- openweather_json("onecall",
    list(lat = config$lat, lon = config$lon, appid = api_key, units = "metric"),
    "OpenWeather forecast", 20, get = get, sleep = sleep)
  validate_forecast_response(payload)
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
                                            api_key = require_weather_key(),
                                            get = httr::GET, sleep = Sys.sleep) {
  force(api_key)
  timestamp <- as.numeric(as.POSIXct(as.Date(date), tz = "UTC"))
  payload <- openweather_json("onecall/timemachine",
    list(lat = config$lat, lon = config$lon, dt = timestamp, appid = api_key, units = "metric"),
    "OpenWeather historical precipitation", 30, get = get, sleep = sleep)
  fail <- function(field) stop(sprintf("Invalid OpenWeather historical precipitation field: %s.", field), call. = FALSE)
  if (!weather_object(payload)) fail("payload")
  if (is.null(payload$data)) return(NA_real_)
  if (!weather_array(payload$data)) fail("data")
  if (!length(payload$data)) return(NA_real_)
  total <- sum(vapply(seq_along(payload$data), function(i) {
    row <- payload$data[[i]]
    prefix <- sprintf("data[%d]", i)
    if (!weather_object(row)) fail(prefix)
    if (!is.numeric(row$dt) || length(row$dt) != 1L || !is.finite(row$dt)) fail(paste0(prefix, ".dt"))
    if (!"rain" %in% names(row)) return(0)
    if (!weather_object(row$rain)) fail(paste0(prefix, ".rain"))
    rain <- row$rain$`1h`
    if (!is.numeric(rain) || length(rain) != 1L || !is.finite(rain) || rain < 0) fail(paste0(prefix, ".rain.1h"))
    rain
  }, numeric(1)))
  if (!is.finite(total)) fail("data total")
  total
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
