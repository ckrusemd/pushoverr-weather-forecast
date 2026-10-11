correctness_assert <- function(value, label) {
  if (!isTRUE(value)) stop(label, call. = FALSE)
}

correctness_equal <- function(actual, expected, label) {
  correctness_assert(identical(actual, expected), label)
}

correctness_contains <- function(text, expected, label = expected) {
  correctness_assert(length(text) == 1L && grepl(expected, text, fixed = TRUE), label)
}

correctness_error <- function(expr, expected) {
  error <- tryCatch({ force(expr); NULL }, error = identity)
  correctness_assert(inherits(error, "error"), paste("Expected error:", expected))
  correctness_contains(conditionMessage(error), expected)
}

correctness_time <- function(value, tz = "Europe/Copenhagen") as.POSIXct(value, tz = tz)

correctness_hour <- function(time, temp = 18, rain = 0, uv = 2, humidity = 50) {
  list(
    dt = as.numeric(time), temp = temp, feels_like = temp - 1, pop = 0.2,
    uvi = uv, wind_speed = 2, clouds = 20, humidity = humidity,
    rain = list(`1h` = rain), weather = list(list(description = "clear sky"))
  )
}

correctness_daily <- function(date, temp = 22) {
  list(dt = as.numeric(correctness_time(paste(date, "12:00:00"))),
       temp = list(min = 12, max = temp), pop = 0.3, wind_speed = 2,
       weather = list(list(description = "clear sky")))
}

correctness_payload <- function(date = "2026-09-22", hours = 0:47) {
  start <- correctness_time(paste(date, "00:00:00"))
  list(current = list(), hourly = lapply(start + hours * 3600, correctness_hour),
       daily = list(correctness_daily(date), correctness_daily(as.character(as.Date(date) + 1L))))
}
