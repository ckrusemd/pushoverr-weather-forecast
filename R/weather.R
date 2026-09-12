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
  sprintf(
    "Weather at 08:00: %s, %.0f°C (feels %.0f°C)\nToday's high: %.0f°C\nPoP: %.0f%% at %s\nUV index tops at: %.1f at %s\nCloud cover: %.0f%%\nSunrise: %s\nSunset: %s",
    at_eight$description, at_eight$temp, at_eight$feels_like,
    daily$max_temp, peak_pop$pop, format(peak_pop$time, "%H:%M"), peak_uv$uv_index, format(peak_uv$time, "%H:%M"),
    at_eight$clouds, format(daily$sunrise, "%H:%M"), format(daily$sunset, "%H:%M")
  )
}
