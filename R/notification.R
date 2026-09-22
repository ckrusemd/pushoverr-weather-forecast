notification_timezone <- "Europe/Copenhagen"
notification_slots <- c(morning = 5L * 60L, afternoon = 15L * 60L)

empty_notification_state <- function() list(schema_version = 1L, deliveries = list())

normalize_notification_state <- function(state) {
  if (!is.list(state)) state <- empty_notification_state()
  state$schema_version <- 1L
  if (is.null(state$deliveries) || !is.list(state$deliveries)) state$deliveries <- list()
  state
}

legacy_notification_state <- function(lines) {
  state <- empty_notification_state()
  for (slot in names(notification_slots)) {
    value <- sub(sprintf("^%s=", slot), "", grep(sprintf("^%s=", slot), lines, value = TRUE))
    if (length(value) && nzchar(value[[1]])) {
      date <- value[[1]]
      if (is.null(state$deliveries[[date]])) state$deliveries[[date]] <- list()
      state$deliveries[[date]][[slot]] <- list(
        accepted_at = paste0(date, "T00:00:00+00:00"), request_id = "legacy", run_id = "legacy"
      )
    }
  }
  state
}

read_notification_state <- function(path) {
  if (!file.exists(path) || !file.info(path)$size) return(empty_notification_state())
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  state <- tryCatch(
    jsonlite::fromJSON(text, simplifyVector = FALSE),
    error = function(e) legacy_notification_state(strsplit(text, "\n", fixed = TRUE)[[1]])
  )
  normalize_notification_state(state)
}

write_notification_state <- function(state, path, today = Sys.Date()) {
  state <- normalize_notification_state(state)
  keep_after <- as.character(as.Date(today) - 30L)
  dates <- names(state$deliveries)
  if (length(dates)) state$deliveries <- state$deliveries[dates >= keep_after]
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(state, path, auto_unbox = TRUE, pretty = TRUE, null = "null")
  invisible(state)
}

notification_local_date <- function(now = Sys.time(), timezone = notification_timezone) {
  format(now, "%Y-%m-%d", tz = timezone)
}

notification_local_minute <- function(now = Sys.time(), timezone = notification_timezone) {
  as.integer(format(now, "%H", tz = timezone)) * 60L + as.integer(format(now, "%M", tz = timezone))
}

notification_was_accepted <- function(state, date, slot) {
  !is.null(state$deliveries[[date]]) && !is.null(state$deliveries[[date]][[slot]])
}

due_notification_slots <- function(state, now = Sys.time(), timezone = notification_timezone) {
  state <- normalize_notification_state(state)
  date <- notification_local_date(now, timezone)
  minute <- notification_local_minute(now, timezone)
  names(notification_slots)[vapply(names(notification_slots), function(slot) {
    minute >= notification_slots[[slot]] && !notification_was_accepted(state, date, slot)
  }, logical(1))]
}

notification_slot_is_due <- function(state, slot, now = Sys.time(), timezone = notification_timezone) {
  stopifnot(slot %in% names(notification_slots))
  slot %in% due_notification_slots(state, now, timezone)
}

record_notification_acceptance <- function(state, date, slot, request_id, accepted_at, run_id = "local") {
  stopifnot(slot %in% names(notification_slots), nzchar(request_id))
  state <- normalize_notification_state(state)
  if (is.null(state$deliveries[[date]])) state$deliveries[[date]] <- list()
  state$deliveries[[date]][[slot]] <- list(
    accepted_at = accepted_at, request_id = request_id, run_id = run_id
  )
  state
}

parse_pushover_acceptance <- function(response) {
  status_code <- httr::status_code(response)
  body_text <- httr::content(response, as = "text", encoding = "UTF-8")
  body <- tryCatch(jsonlite::fromJSON(body_text, simplifyVector = TRUE), error = function(e) list())
  accepted <- identical(status_code, 200L) && identical(as.integer(body$status %||% 0L), 1L) &&
    is.character(body$request) && length(body$request) == 1L && nzchar(body$request)
  list(
    accepted = accepted, status_code = status_code,
    request_id = if (accepted) body$request else "",
    errors = body$errors %||% body$error %||% "No diagnostic details returned."
  )
}

send_pushover_message <- function(message, title, app_key = Sys.getenv("PUSHOVER_APPKEY"),
                                  user_key = Sys.getenv("PUSHOVER_USERKEY"), attempts = 4L,
                                  post = httr::POST, sleep = Sys.sleep) {
  if (!nzchar(trimws(app_key)) || !nzchar(trimws(user_key))) {
    stop("Pushover credentials are not configured.", call. = FALSE)
  }
  last_result <- NULL
  last_error <- NULL
  for (attempt in seq_len(attempts)) {
    response <- tryCatch(
      post(
        "https://api.pushover.net/1/messages.json",
        body = list(token = app_key, user = user_key, title = title, message = message),
        encode = "form", httr::timeout(20)
      ),
      error = function(e) {
        last_error <<- conditionMessage(e)
        NULL
      }
    )
    if (!is.null(response)) {
      last_result <- parse_pushover_acceptance(response)
      if (last_result$accepted) return(c(last_result, list(attempts = attempt)))
      terminal <- last_result$status_code >= 400L && last_result$status_code < 500L &&
        !last_result$status_code %in% c(408L, 429L)
      if (terminal) break
    }
    if (attempt < attempts) sleep(2^(attempt - 1L))
  }
  if (!is.null(last_result)) {
    stop(sprintf("Pushover rejected the request (%s): %s", last_result$status_code,
                 paste(last_result$errors, collapse = "; ")), call. = FALSE)
  }
  stop(sprintf("Pushover request failed: %s", last_error %||% "unknown transport error"), call. = FALSE)
}
