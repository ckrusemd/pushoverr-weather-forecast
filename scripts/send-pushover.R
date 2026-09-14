source("R/weather.R")

required <- c("PUSHOVER_APPKEY", "PUSHOVER_USERKEY", "OPENWEATHERMAP_APIKEY")
missing <- required[!nzchar(trimws(Sys.getenv(required)))]
if (length(missing)) stop(sprintf("Missing required environment variable(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

payload <- fetch_weather()
message <- notification_text(
  payload,
  precipitation_yesterday_mm = fetch_historical_precipitation(
    as.Date(Sys.time(), tz = weather_config$timezone) - 1
  )
)
if (identical(Sys.getenv("PUSHOVER_DRY_RUN"), "true")) {
  message(message)
  quit(status = 0)
}

response <- httr::POST(
  "https://api.pushover.net/1/messages.json",
  body = list(token = Sys.getenv("PUSHOVER_APPKEY"), user = Sys.getenv("PUSHOVER_USERKEY"), title = "Weather forecast", message = message),
  encode = "form", httr::timeout(20)
)
if (httr::status_code(response) != 200) {
  response_body <- tryCatch(
    jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"), simplifyVector = TRUE),
    error = function(e) list()
  )
  api_errors <- response_body$errors %||% response_body$error %||% "No diagnostic details returned."
  stop(sprintf("Pushover request failed (%s): %s", httr::status_code(response), paste(api_errors, collapse = "; ")), call. = FALSE)
}
message("Daily weather notification sent.")
