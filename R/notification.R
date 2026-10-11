notification_timezone <- "Europe/Copenhagen"
notification_slots <- c(morning = 5L * 60L, afternoon = 15L * 60L)

empty_notification_state <- function() list(schema_version = 1L, deliveries = setNames(list(), character()))

notification_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x) &&
  nzchar(trimws(x, whitespace = "[\\x20\\t\\r\\n]"))

notification_date_valid <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x) ||
      !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x) || substr(x, 1, 4) == "0000") return(FALSE)
  parsed <- suppressWarnings(as.Date(x, format = "%Y-%m-%d"))
  !is.na(parsed) && identical(format(parsed, "%Y-%m-%d"), x)
}

notification_timestamp_valid <- function(x) {
  notification_string(x) &&
    grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$", x) &&
    notification_date_valid(substr(x, 1, 10))
}

normalize_notification_state <- function(state) {
  invalid <- function() stop("Invalid notification state (schema 1 required).", call. = FALSE)
  object <- function(x) is.list(x) && !is.null(names(x)) && !anyDuplicated(names(x))
  if (!object(state) || !setequal(names(state), c("schema_version", "deliveries")) ||
      !is.numeric(state$schema_version) || length(state$schema_version) != 1L ||
      is.na(state$schema_version) || state$schema_version != 1 || !is.list(state$deliveries)) invalid()
  # The previous schema-1 writer emitted [] for an empty deliveries map.
  if (!length(state$deliveries)) state$deliveries <- setNames(list(), character())
  if (!object(state$deliveries)) invalid()
  for (date in names(state$deliveries)) {
    slots <- state$deliveries[[date]]
    if (!notification_date_valid(date) || !object(slots) ||
        any(!names(slots) %in% names(notification_slots))) invalid()
    for (record in slots) {
      if (!object(record) || !setequal(names(record), c("request_id", "accepted_at", "run_id")) ||
          !notification_string(record$request_id) || !notification_string(record$run_id) ||
          !notification_timestamp_valid(record$accepted_at)) invalid()
    }
  }
  state$schema_version <- 1L
  state
}

legacy_notification_state <- function(lines) {
  state <- empty_notification_state()
  lines <- sub("\r$", "", lines)
  lines <- lines[nzchar(lines)]
  if (!length(lines) || any(!grepl("^(morning|afternoon)=", lines)))
    stop("Unrecognized legacy notification state.", call. = FALSE)
  slots <- sub("=.*$", "", lines)
  if (anyDuplicated(slots)) stop("Duplicate legacy notification slot.", call. = FALSE)
  for (i in seq_along(lines)) {
    slot <- slots[[i]]
    date <- sub("^[^=]+=", "", lines[[i]])
    if (nzchar(date)) {
      if (!notification_date_valid(date)) stop("Invalid legacy notification date.", call. = FALSE)
      if (is.null(state$deliveries[[date]])) state$deliveries[[date]] <- setNames(list(), character())
      state$deliveries[[date]][[slot]] <- list(
        accepted_at = paste0(date, "T00:00:00+00:00"), request_id = "legacy", run_id = "legacy"
      )
    }
  }
  state
}

read_notification_state <- function(path) {
  if (!file.exists(path)) {
    link <- Sys.readlink(path)
    if (!is.na(link) && nzchar(link)) stop("Unreadable notification state.", call. = FALSE)
    return(empty_notification_state())
  }
  if (isTRUE(file.info(path)$isdir) || file.access(path, 4L) != 0L || !file.info(path)$size)
    stop("Unreadable or empty notification state.", call. = FALSE)
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  state <- tryCatch(
    jsonlite::fromJSON(text, simplifyVector = FALSE),
    error = function(e) legacy_notification_state(strsplit(text, "\n", fixed = TRUE)[[1]])
  )
  normalize_notification_state(state)
}

merge_notification_state <- function(latest, accepted) {
  latest <- normalize_notification_state(latest)
  accepted <- normalize_notification_state(accepted)
  for (date in names(accepted$deliveries)) {
    if (is.null(latest$deliveries[[date]])) latest$deliveries[[date]] <- setNames(list(), character())
    for (slot in names(accepted$deliveries[[date]])) {
      if (is.null(latest$deliveries[[date]][[slot]]))
        latest$deliveries[[date]][[slot]] <- accepted$deliveries[[date]][[slot]]
    }
  }
  latest
}

atomic_notification_state <- function(state, path) {
  temporary <- tempfile(pattern = ".notification-", tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(state, temporary, auto_unbox = TRUE, pretty = TRUE, null = "null")
  if (!file.rename(temporary, path)) stop("Could not atomically replace notification state.", call. = FALSE)
}

write_notification_state <- function(state, path, today = as.Date(notification_local_date())) {
  state <- normalize_notification_state(state)
  keep_after <- as.character(as.Date(today) - 30L)
  dates <- names(state$deliveries)
  if (length(dates)) state$deliveries <- state$deliveries[dates >= keep_after]
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  # Journal first: retain accepted records even if replacing the working state fails.
  journal_path <- paste0(path, ".accepted.json")
  journal <- merge_notification_state(state, read_notification_state(journal_path))
  atomic_notification_state(journal, journal_path)
  atomic_notification_state(state, path)
  invisible(state)
}

notification_local_date <- function(now = Sys.time(), timezone = notification_timezone) {
  format(now, "%Y-%m-%d", tz = timezone)
}

notification_local_minute <- function(now = Sys.time(), timezone = notification_timezone) {
  as.integer(format(now, "%H", tz = timezone)) * 60L + as.integer(format(now, "%M", tz = timezone))
}

notification_was_accepted <- function(state, date, slot) {
  state <- normalize_notification_state(state)
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
  stopifnot(slot %in% names(notification_slots), notification_date_valid(date),
            notification_string(request_id), notification_string(run_id),
            notification_timestamp_valid(accepted_at))
  state <- normalize_notification_state(state)
  if (is.null(state$deliveries[[date]])) state$deliveries[[date]] <- setNames(list(), character())
  state$deliveries[[date]][[slot]] <- list(
    accepted_at = accepted_at, request_id = request_id, run_id = run_id
  )
  state
}

parse_pushover_acceptance <- function(response) {
  status_code <- httr::status_code(response)
  body_text <- httr::content(response, as = "text", encoding = "UTF-8")
  body <- tryCatch(jsonlite::fromJSON(body_text, simplifyVector = FALSE), error = function(e) list())
  if (!is.list(body)) body <- list()
  accepted <- identical(status_code, 200L) && is.list(body) && !anyDuplicated(names(body)) &&
    is.numeric(body$status) && length(body$status) == 1L && !is.na(body$status) &&
    body$status == 1 && notification_string(body$request)
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
