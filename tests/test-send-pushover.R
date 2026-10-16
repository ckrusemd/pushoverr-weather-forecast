source("scripts/send-pushover.R")
source("tests/helpers-weather-correctness.R")

local({
  variables <- c("OPENWEATHERMAP_APIKEY", "PUSHOVER_APPKEY", "PUSHOVER_USERKEY", "GITHUB_STEP_SUMMARY", "TZ")
  saved <- Sys.getenv(variables, unset = NA_character_)
  on.exit({
    Sys.unsetenv(variables[is.na(saved)])
    if (any(!is.na(saved))) do.call(Sys.setenv, as.list(saved[!is.na(saved)]))
  })
  Sys.unsetenv(variables)
  Sys.setenv(TZ = "UTC")
  now <- correctness_time("2026-09-22 15:00:00")
  baseline_now <- now
  args_for <- function(path = tempfile(), mode = "reconcile", slot = "morning") {
    list(mode = mode, slot = slot, state = path)
  }
  harness <- function() {
    calls <- new.env(parent = emptyenv())
    calls$fetch <- 0L
    calls$historical <- list()
    calls$render <- list()
    calls$send <- character()
    calls$charts <- 0L
    calls$attachments <- list()
    calls$chart_paths <- character()
    list(
      calls = calls,
      fetch = function(config) { calls$fetch <- calls$fetch + 1L; correctness_payload() },
      historical = function(date, config) {
        calls$historical <- c(calls$historical, list(date))
        3.2
      },
      render = function(payload, config, precipitation_yesterday_mm, delivery_slot, now) {
        calls$render <- c(calls$render, list(list(
          slot = delivery_slot, now = now, precipitation = precipitation_yesterday_mm,
          timezone = config$timezone
        )))
        delivery_slot
      },
      chart = function(payload, path, config, now) {
        calls$charts <- calls$charts + 1L
        calls$chart_paths <- c(calls$chart_paths, path)
        writeBin(as.raw(c(137, 80, 78, 71, 13, 10, 26, 10)), path)
        invisible(path)
      },
      send = function(message, title, attachment = NULL) {
        calls$send <- c(calls$send, message)
        calls$attachments <- c(calls$attachments, list(attachment))
        if (!is.null(attachment)) correctness_assert(file.exists(attachment), "Image exists during send")
        list(accepted = TRUE, request_id = paste0("request-", message), attempts = 1L)
      }
    )
  }
  run <- function(args, now = baseline_now, h = harness(), ...) {
    run_notifications(args, now = now, fetch = h$fetch, historical = h$historical,
                      send = h$send, render = h$render, clock = function() now, chart = h$chart, ...)
  }

  # Before the morning boundary, no secrets, network or state files are needed.
  for (mode in c("reconcile", "scheduled", "dry-run")) {
    args <- args_for(mode = mode)
    h <- harness()
    result <- run(args, now = correctness_time("2026-09-21 22:30:00", "UTC"), h = h)
    correctness_equal(result$slots, character(), paste(mode, "Copenhagen midnight is not due"))
    correctness_equal(h$calls$fetch, 0L, paste(mode, "no weather request"))
    correctness_equal(length(h$calls$historical), 0L, paste(mode, "no history request"))
    correctness_equal(length(h$calls$send), 0L, paste(mode, "no sends"))
    correctness_equal(h$calls$charts, 0L, paste(mode, "no chart rendering before morning"))
    correctness_assert(!file.exists(args$state), paste(mode, "no state write"))
  }
  for (date in c("2026-03-29", "2026-10-25")) {
    h <- harness()
    args <- args_for()
    run(args, now = correctness_time(paste(date, "04:59:00")), h = h)
    correctness_equal(h$calls$fetch, 0L, paste("Before morning DST boundary", date))
    correctness_assert(!file.exists(args$state), "DST no-work no state writes")
  }

  legacy_path <- tempfile()
  writeLines(c("morning=2026-09-22", "afternoon=2026-09-22"), legacy_path)
  original <- readBin(legacy_path, "raw", n = file.info(legacy_path)$size)
  h <- harness()
  result <- run(args_for(legacy_path), h = h)
  correctness_equal(result$slots, character(), "Legacy accepted slots deduplicated")
  correctness_equal(h$calls$fetch, 0L, "Completed legacy state skips HTTP without secrets")
  correctness_equal(h$calls$charts, 0L, "Completed state skips chart rendering")
  correctness_equal(readBin(legacy_path, "raw", n = file.info(legacy_path)$size), original,
                    "No-work legacy state is unchanged")
  scheduled_path <- tempfile()
  writeLines("morning=2026-09-22", scheduled_path)
  original <- readBin(scheduled_path, "raw", n = file.info(scheduled_path)$size)
  h <- harness()
  result <- run(args_for(scheduled_path, "scheduled", "morning"), h = h)
  correctness_equal(result$slots, character(), "Scheduled morning skips despite due afternoon")
  correctness_equal(h$calls$fetch, 0L, "Scheduled accepted slot no HTTP without secrets")
  correctness_equal(readBin(scheduled_path, "raw", n = file.info(scheduled_path)$size), original,
                    "Scheduled no-work preserves legacy bytes")

  # Missing credentials on due work must fail before state migration or HTTP.
  args <- args_for()
  h <- harness()
  correctness_error(run(args, h = h), "Missing required environment variable(s)")
  correctness_equal(h$calls$fetch, 0L, "Due missing secrets skips HTTP")
  correctness_assert(!file.exists(args$state), "Due missing secrets skips state writes")
  Sys.setenv(OPENWEATHERMAP_APIKEY = "offline-placeholder")
  args <- args_for()
  correctness_error(run(args), "PUSHOVER_APPKEY")
  correctness_assert(!file.exists(args$state), "Missing Pushover secrets skips state writes")

  # Dry-run needs only weather credentials, previews both due slots, never sends
  # and preserves existing bytes (including the legacy state format).
  dry_path <- tempfile()
  writeLines(c("morning=2026-09-21", "afternoon=2026-09-21"), dry_path)
  original <- readBin(dry_path, "raw", n = file.info(dry_path)$size)
  h <- harness()
  result <- run(args_for(dry_path, "dry-run"), h = h)
  correctness_equal(result$slots, c("morning", "afternoon"), "Dry-run reconciles due slots")
  correctness_equal(h$calls$fetch, 1L, "Dry-run fetches weather once")
  correctness_equal(length(h$calls$historical), 1L, "Dry-run morning history once")
  correctness_equal(length(h$calls$send), 0L, "Dry-run never sends")
  correctness_equal(h$calls$charts, 1L, "Dry-run renders one chart without sending")
  correctness_assert(!any(file.exists(h$calls$chart_paths)), "Dry-run removes temporary image")
  correctness_equal(readBin(dry_path, "raw", n = file.info(dry_path)$size), original,
                    "Dry-run preserves state bytes")
  args <- args_for(mode = "dry-run")
  run(args)
  correctness_assert(!file.exists(args$state), "Dry-run never creates state")

  Sys.setenv(PUSHOVER_APPKEY = "offline-placeholder", PUSHOVER_USERKEY = "offline-placeholder")
  # Afternoon-only reconciliation, scheduled and force calls require no history.
  for (mode in c("reconcile", "scheduled", "force", "dry-run")) {
    path <- tempfile()
    writeLines("morning=2026-09-22", path)
    original <- readBin(path, "raw", n = file.info(path)$size)
    h <- harness()
    result <- run(args_for(path, mode, "afternoon"), h = h)
    correctness_equal(result$slots, "afternoon", paste(mode, "afternoon-only slots"))
    correctness_equal(h$calls$fetch, 1L, paste(mode, "forecast once"))
    correctness_equal(h$calls$charts, 1L, paste(mode, "chart once"))
    correctness_assert(!any(file.exists(h$calls$chart_paths)), "Temporary image removed after send")
    correctness_equal(length(h$calls$historical), 0L, paste(mode, "zero historical requests"))
    correctness_assert(is.na(h$calls$render[[1]]$precipitation), "Afternoon history stays unavailable")
    correctness_equal(h$calls$render[[1]]$now, now, "Renderer receives fixed clock")
    if (mode %in% c("reconcile", "scheduled")) {
      state <- read_notification_state(path)
      correctness_assert(notification_was_accepted(state, "2026-09-22", "morning"), "Legacy morning preserved")
      correctness_equal(state$deliveries[["2026-09-22"]]$afternoon$request_id,
                        "request-afternoon", "Accepted afternoon recorded")
      correctness_equal(state$deliveries[["2026-09-22"]]$afternoon$accepted_at,
                        "2026-09-22T13:00:00Z", "Acceptance timestamp is UTC")
    } else {
      correctness_equal(readBin(path, "raw", n = file.info(path)$size), original,
                        paste(mode, "state unchanged"))
    }
  }

  # Late morning catches up only morning; history date follows Copenhagen.
  h <- harness()
  path <- tempfile()
  result <- run(args_for(path), now = correctness_time("2026-09-22 11:15:00"), h = h)
  correctness_equal(result$slots, "morning", "Late morning catch-up")
  correctness_equal(h$calls$historical[[1]], as.Date("2026-09-21"), "History is yesterday in Copenhagen")
  correctness_equal(h$calls$render[[1]]$precipitation, 3.2, "History reaches morning renderer")
  correctness_equal(h$calls$send, "morning", "Late morning single send")
  for (date in c("2026-03-29", "2026-10-25")) {
    h <- harness()
    path <- tempfile()
    result <- run(args_for(path), now = correctness_time(paste(date, "05:00:00")), h = h)
    correctness_equal(result$slots, "morning", paste("Morning DST boundary", date))
    correctness_equal(h$calls$historical[[1]], as.Date(date) - 1L, "DST history local date")
    correctness_assert(notification_was_accepted(read_notification_state(path), date, "morning"),
                       "DST acceptance local date")
  }

  # A failed slot never prevents the other due slot from succeeding, and only
  # provider acceptances enter persisted state. Exercise both failure orders.
  for (failed_slot in c("morning", "afternoon")) {
    path <- tempfile()
    h <- harness()
    h$send <- function(message, title, attachment = NULL) {
      h$calls$send <- c(h$calls$send, message)
      if (message == failed_slot) stop("offline rejection", call. = FALSE)
      list(accepted = TRUE, request_id = paste0("accepted-", message), attempts = 2L)
    }
    summary_path <- tempfile()
    Sys.setenv(GITHUB_STEP_SUMMARY = summary_path)
    correctness_error(run(args_for(path), h = h), paste(failed_slot, "offline rejection", sep = ": "))
    Sys.unsetenv("GITHUB_STEP_SUMMARY")
    state <- read_notification_state(path)
    accepted_slot <- setdiff(c("morning", "afternoon"), failed_slot)
    correctness_equal(h$calls$send, c("morning", "afternoon"), "Both slots attempted despite failure")
    correctness_assert(!notification_was_accepted(state, "2026-09-22", failed_slot), "Failed slot not recorded")
    correctness_equal(state$deliveries[["2026-09-22"]][[accepted_slot]]$request_id,
                      paste0("accepted-", accepted_slot), "Partial success persisted")
    summary <- paste(readLines(summary_path), collapse = "\n")
    correctness_contains(summary, paste0("accepted-", accepted_slot))
    correctness_contains(summary, paste0("- `", failed_slot, "`: failed"))
    retry_h <- harness()
    retry_result <- run(args_for(path), h = retry_h)
    correctness_equal(retry_result$slots, failed_slot, "Next reconciliation retries only failed slot")
    correctness_equal(retry_h$calls$send, failed_slot, "Accepted slot never resent")
    correctness_equal(length(retry_h$calls$historical), if (failed_slot == "morning") 1L else 0L,
                      "Partial-success retry fetches history only for morning")
    correctness_equal(read_notification_state(path)$deliveries[["2026-09-22"]][[accepted_slot]]$request_id,
                      paste0("accepted-", accepted_slot), "Previous acceptance preserved on retry")
  }

  # Rendering failure is also isolated to its slot.
  h <- harness()
  normal_render <- h$render
  h$render <- function(...) {
    arguments <- list(...)
    if (arguments$delivery_slot == "morning") stop("offline render failure", call. = FALSE)
    do.call(normal_render, arguments)
  }
  path <- tempfile()
  correctness_error(run(args_for(path), h = h), "morning: offline render failure")
  correctness_assert(notification_was_accepted(read_notification_state(path), "2026-09-22", "afternoon"),
                     "Afternoon survives morning render failure")

  # Reconciliation reuses a single image for both due slots, and removes it.
  h <- harness()
  run(args_for(), h = h)
  correctness_equal(h$calls$charts, 1L, "Both due slots share one chart")
  correctness_equal(h$calls$attachments[[1]], h$calls$attachments[[2]], "Both messages attach the same chart")
  correctness_assert(!any(file.exists(h$calls$chart_paths)), "Shared chart cleaned up")

  # A broken renderer cannot block the text forecast or change idempotency.
  h <- harness()
  h$chart <- function(...) stop("offline chart unavailable", call. = FALSE)
  path <- tempfile()
  chart_warning <- NULL
  withCallingHandlers(run(args_for(path), h = h), warning = function(w) {
    chart_warning <<- conditionMessage(w)
    invokeRestart("muffleWarning")
  })
  correctness_contains(chart_warning, "sending text only")
  correctness_equal(h$calls$send, c("morning", "afternoon"), "Text fallback still sends both slots")
  correctness_assert(all(vapply(h$calls$attachments, is.null, logical(1))), "Fallback attaches no invalid image")
  correctness_assert(notification_was_accepted(read_notification_state(path), "2026-09-22", "morning"),
                     "Text fallback records accepted slot normally")

  # History failure remains nonfatal, and force never creates state.
  h <- harness()
  h$historical <- function(...) stop("offline history unavailable", call. = FALSE)
  args <- args_for(mode = "force")
  warning_message <- NULL
  result <- withCallingHandlers(run(args, h = h), warning = function(w) {
    warning_message <<- conditionMessage(w)
    invokeRestart("muffleWarning")
  })
  correctness_contains(warning_message, "Historical precipitation unavailable")
  correctness_assert(is.na(h$calls$render[[1]]$precipitation), "Failed history is unavailable")
  correctness_assert(!file.exists(args$state), "Force does not create state")
  correctness_equal(result$slots, "morning", "Force single slot")

  # Exercise the unchanged CLI safely: both slots are already accepted and all
  # credentials are absent, so any accidental credential/network work fails.
  Sys.unsetenv(c("OPENWEATHERMAP_APIKEY", "PUSHOVER_APPKEY", "PUSHOVER_USERKEY"))
  path <- tempfile()
  state <- empty_notification_state()
  for (date in as.character(as.Date(notification_local_date()) + c(-1L, 0L, 1L))) {
    for (slot in names(notification_slots)) {
      state <- record_notification_acceptance(state, date, slot, "offline", "2026-09-22T00:00:00Z")
    }
  }
  write_notification_state(state, path, as.Date(notification_local_date()))
  original <- readBin(path, "raw", n = file.info(path)$size)
  cli <- system2(file.path(R.home("bin"), "Rscript"),
                 c("--vanilla", "scripts/send-pushover.R", paste0("--state=", path)),
                 stdout = TRUE, stderr = TRUE)
  correctness_assert(is.null(attr(cli, "status")), "No-work CLI exits successfully without secrets")
  correctness_contains(paste(cli, collapse = "\n"), "No notification slots are due.")
  correctness_equal(readBin(path, "raw", n = file.info(path)$size), original, "No-work CLI no state write")
  correctness_equal(parse_arguments(c("--mode=force", "--slot=afternoon"))$mode, "force", "CLI force preserved")
  correctness_error(parse_arguments("--mode=invalid"), "Invalid --mode")
  correctness_error(parse_arguments("--slot=invalid"), "Invalid --slot")
})

cat("Send-Pushover correctness tests passed.\n")
