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
  response <- httr::GET(
    "https://api.openweathermap.org/data/3.0/onecall",
    query = list(lat = config$lat, lon = config$lon, appid = api_key, units = "metric"),
    httr::timeout(20)
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
  if (length(weather) && length(weather[[1]]$description)) weather[[1]]$description else "Unavailable"
}

as_local_time <- function(seconds, tz = weather_config$timezone) as.POSIXct(seconds, origin = "1970-01-01", tz = tz)

hourly_frame <- function(payload, tz = weather_config$timezone) {
  rows <- lapply(payload$hourly, function(x) data.frame(
    time = as_local_time(x$dt, tz), temp = x$temp, feels_like = x$feels_like,
    pop = (x$pop %||% 0) * 100, uv_index = x$uvi %||% NA_real_, wind_speed = x$wind_speed, clouds = x$clouds,
    humidity = x$humidity %||% NA_real_, rain_mm = if (is.null(x$rain)) 0 else (x$rain$`1h` %||% 0),
    description = weather_description(x$weather), stringsAsFactors = FALSE
  ))
  do.call(rbind, rows)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

daily_frame <- function(payload, tz = weather_config$timezone) {
  rows <- lapply(payload$daily, function(x) data.frame(
    date = as.Date(as_local_time(x$dt, tz)), sunrise = as_local_time(x$sunrise, tz), sunset = as_local_time(x$sunset, tz),
    min_temp = x$temp$min, max_temp = x$temp$max, pop = (x$pop %||% 0) * 100,
    wind_speed = x$wind_speed, description = weather_description(x$weather), stringsAsFactors = FALSE
  ))
  do.call(rbind, rows)
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
  hours <- sort(unique(as.integer(hours)))
  if (!length(hours)) return("none")
  groups <- cumsum(c(TRUE, diff(hours) != 1))
  pieces <- split(hours, groups)
  paste(vapply(pieces, function(x) if (length(x) == 1) as.character(x) else sprintf("%d-%d", min(x), max(x)), character(1)), collapse = ", ")
}

best_outdoor_hour <- function(hourly) {
  today <- hourly[as.Date(hourly$time) == as.Date(Sys.time(), tz = weather_config$timezone), , drop = FALSE]
  if (!nrow(today)) today <- hourly
  today$score <- outdoor_score(today)
  today[which.max(today$score), , drop = FALSE]
}

notification_text <- function(payload, config = weather_config) {
  daily <- daily_frame(payload, config$timezone)[1, , drop = FALSE]
  hourly <- hourly_frame(payload, config$timezone)
  today <- hourly[as.Date(hourly$time) == daily$date, , drop = FALSE]
  if (!nrow(today)) today <- hourly
  at_eight <- today[which.min(abs(as.numeric(difftime(today$time, as.POSIXct(paste(daily$date, "08:00:00"), tz = config$timezone), units = "secs")))), , drop = FALSE]
  peak_pop <- today[which.max(today$pop), , drop = FALSE]
  peak_uv <- today[which.max(ifelse(is.na(today$uv_index), -Inf, today$uv_index)), , drop = FALSE]
  today$rh_at_21c <- relative_humidity_at(today$temp, today$humidity)
  dry_hours <- today$rh_at_21c < 60 & as.integer(format(today$time, "%H")) >= 7 & as.integer(format(today$time, "%H")) <= 22
  sprintf(
    "Vejret kl. 08:00: %s, %.0f°C (føles som %.0f°C)\nDagens maksimum: %.0f°C\nNedbørssandsynlighed: %.0f%% kl. %s\nUV-indeks topper på: %.1f kl. %s\nSkydække: %.0f%%\nSolopgang: %s\nSolnedgang: %s\nRelativ luftfugtighed under 60%% ved 21°C: %s",
    at_eight$description, at_eight$temp, at_eight$feels_like,
    daily$max_temp, peak_pop$pop, format(peak_pop$time, "%H:%M"), peak_uv$uv_index, format(peak_uv$time, "%H:%M"),
    at_eight$clouds, format(daily$sunrise, "%H:%M"), format(daily$sunset, "%H:%M"),
    connected_hour_ranges(as.integer(format(today$time[dry_hours], "%H")))
  )
}
