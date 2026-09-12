source("R/weather.R")

required <- c("PUSHOVER_APPKEY", "PUSHOVER_USERKEY", "OPENWEATHERMAP_APIKEY")
missing <- required[!nzchar(trimws(Sys.getenv(required)))]
if (length(missing)) stop(sprintf("Missing required environment variable(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

message <- notification_text(fetch_weather())
if (identical(Sys.getenv("PUSHOVER_DRY_RUN"), "true")) {
  message(message)
  quit(status = 0)
}

response <- httr::POST(
  "https://api.pushover.net/1/messages.json",
  body = list(token = Sys.getenv("PUSHOVER_APPKEY"), user = Sys.getenv("PUSHOVER_USERKEY"), title = "Weather forecast", message = message),
  encode = "form", httr::timeout(20)
)
if (httr::status_code(response) != 200) stop(sprintf("Pushover request failed (%s).", httr::status_code(response)), call. = FALSE)
message("Daily weather notification sent.")
