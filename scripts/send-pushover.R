user_library <- Sys.getenv("R_LIBS_USER")
user_libraries <- strsplit(user_library, .Platform$path.sep, fixed = TRUE)[[1]]
.libPaths(c(user_libraries[dir.exists(user_libraries)], .libPaths()))

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

run_notifications <- function(args = parse_arguments(commandArgs(trailingOnly = TRUE)),
                              now = Sys.time(), config = weather_config,
                              fetch = fetch_weather, historical = fetch_historical_precipitation,
                              send = send_pushover_message, render = notification_text,
                              clock = Sys.time) {
  state <- read_notification_state(args$state)
  date <- notification_local_date(now, config$timezone)
  slots <- switch(args$mode,
    reconcile = due_notification_slots(state, now, config$timezone),
    scheduled = if (notification_slot_is_due(state, args$slot, now, config$timezone)) args$slot else character(),
    force = args$slot,
    `dry-run` = due_notification_slots(state, now, config$timezone)
  )

  if (!length(slots)) {
    message("No notification slots are due.")
    append_summary(c(
      "## Pushover reconciliation", "",
      sprintf("No slots due at %s Copenhagen time.", format(now, tz = config$timezone, usetz = TRUE))
    ))
    return(invisible(list(slots = slots, state = state, results = character())))
  }

  required <- "OPENWEATHERMAP_APIKEY"
  if (args$mode != "dry-run") required <- c(required, "PUSHOVER_APPKEY", "PUSHOVER_USERKEY")
  missing <- required[!nzchar(trimws(Sys.getenv(required)))]
  if (length(missing)) stop(sprintf("Missing required environment variable(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

  if (args$mode == "reconcile") write_notification_state(state, args$state, as.Date(date))
  payload <- tryCatch(fetch(config = config), error = function(e) {
    append_summary(c("## Pushover reconciliation", "", paste("Weather retrieval failed:", conditionMessage(e))))
    stop(e)
  })
  precipitation <- NA_real_
  if ("morning" %in% slots) {
    precipitation <- tryCatch(
      historical(as.Date(now, tz = config$timezone) - 1L, config = config),
      error = function(e) {
        warning(sprintf("Historical precipitation unavailable: %s", conditionMessage(e)), call. = FALSE)
        NA_real_
      }
    )
  }
  results <- character()
  failures <- character()

  for (slot in slots) {
    title <- if (slot == "morning") "Morning weather forecast" else "Afternoon weather update"
    result <- tryCatch({
      forecast_message <- render(
        payload, config = config, precipitation_yesterday_mm = precipitation,
        delivery_slot = slot, now = now
      )
      if (args$mode == "dry-run") {
        message(sprintf("[%s]\n%s", title, forecast_message))
        NULL
      } else {
        send(forecast_message, title)
      }
    }, error = function(e) e)
    if (inherits(result, "error")) {
      failures <- c(failures, sprintf("%s: %s", slot, conditionMessage(result)))
      results <- c(results, sprintf("- `%s`: failed", slot))
      next
    }
    if (args$mode == "dry-run") {
      results <- c(results, sprintf("- `%s`: dry run completed", slot))
      next
    }
    accepted_at <- format(clock(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
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
    sprintf("Copenhagen time: %s", format(now, tz = config$timezone, usetz = TRUE)),
    sprintf("Mode: `%s`", args$mode), "", results
  ))

  if (length(failures)) stop(paste(failures, collapse = " | "), call. = FALSE)
  invisible(list(slots = slots, state = state, results = results))
}

if (sys.nframe() == 0L) run_notifications()
