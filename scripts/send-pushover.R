user_library <- Sys.getenv("R_LIBS_USER")
if (nzchar(user_library) && dir.exists(user_library)) .libPaths(c(user_library, .libPaths()))

source("R/weather.R")
source("R/notification.R")

parse_arguments <- function(args) {
  result <- list(
    mode = "reconcile", slot = "morning",
    state = Sys.getenv("NOTIFICATION_STATE_PATH", "notification-state.json")
  )
  for (arg in args) {
    parts <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(parts) == 2L && parts[[1]] %in% names(result)) result[[parts[[1]]]] <- parts[[2]]
  }
  if (!result$mode %in% c("reconcile", "scheduled", "force", "dry-run")) stop("Invalid --mode.", call. = FALSE)
  if (!result$slot %in% names(notification_slots)) stop("Invalid --slot.", call. = FALSE)
  result
}

append_summary <- function(lines) {
  path <- Sys.getenv("GITHUB_STEP_SUMMARY")
  if (nzchar(path)) cat(paste0(lines, collapse = "\n"), "\n", file = path, append = TRUE)
}

args <- parse_arguments(commandArgs(trailingOnly = TRUE))
required <- "OPENWEATHERMAP_APIKEY"
if (args$mode != "dry-run") required <- c(required, "PUSHOVER_APPKEY", "PUSHOVER_USERKEY")
missing <- required[!nzchar(trimws(Sys.getenv(required)))]
if (length(missing)) stop(sprintf("Missing required environment variable(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

state <- read_notification_state(args$state)
now <- Sys.time()
date <- notification_local_date(now)
if (args$mode == "reconcile") write_notification_state(state, args$state, as.Date(date))
slots <- switch(args$mode,
  reconcile = due_notification_slots(state, now),
  scheduled = if (notification_slot_is_due(state, args$slot, now)) args$slot else character(),
  force = args$slot,
  `dry-run` = due_notification_slots(state, now)
)

if (!length(slots)) {
  message("No notification slots are due.")
  append_summary(c(
    "## Pushover reconciliation", "",
    sprintf("No slots due at %s Copenhagen time.", format(now, tz = notification_timezone, usetz = TRUE))
  ))
  quit(status = 0)
}

payload <- tryCatch(fetch_weather(), error = function(e) {
  append_summary(c("## Pushover reconciliation", "", paste("Weather retrieval failed:", conditionMessage(e))))
  stop(e)
})
precipitation <- tryCatch(
  fetch_historical_precipitation(as.Date(now, tz = notification_timezone) - 1L),
  error = function(e) {
    warning(sprintf("Historical precipitation unavailable: %s", conditionMessage(e)), call. = FALSE)
    NA_real_
  }
)
results <- character()
failures <- character()

for (slot in slots) {
  title <- if (slot == "morning") "Morning weather forecast" else "Afternoon weather update"
  forecast_message <- notification_text(
    payload, precipitation_yesterday_mm = precipitation, delivery_slot = slot
  )
  if (args$mode == "dry-run") {
    message(sprintf("[%s]\n%s", title, forecast_message))
    results <- c(results, sprintf("- `%s`: dry run completed", slot))
    next
  }
  result <- tryCatch(send_pushover_message(forecast_message, title), error = function(e) e)
  if (inherits(result, "error")) {
    failures <- c(failures, sprintf("%s: %s", slot, conditionMessage(result)))
    results <- c(results, sprintf("- `%s`: failed after retries", slot))
    next
  }
  accepted_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  results <- c(results, sprintf(
    "- `%s`: accepted as request `%s` after %d attempt(s)", slot, result$request_id, result$attempts
  ))
  message(sprintf("Pushover accepted %s notification as request %s.", slot, result$request_id))
  if (args$mode %in% c("reconcile", "scheduled")) {
    state <- record_notification_acceptance(
      state, date, slot, result$request_id, accepted_at, Sys.getenv("GITHUB_RUN_ID", "local")
    )
    write_notification_state(state, args$state, as.Date(date))
  }
}

append_summary(c(
  "## Pushover reconciliation", "",
  sprintf("Copenhagen time: %s", format(now, tz = notification_timezone, usetz = TRUE)),
  sprintf("Mode: `%s`", args$mode), "", results
))

if (length(failures)) stop(paste(failures, collapse = " | "), call. = FALSE)
