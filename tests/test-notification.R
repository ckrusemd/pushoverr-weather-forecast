source("R/weather.R")
source("R/notification.R")

assert_identical <- function(actual, expected, label) {
  if (!identical(actual, expected)) stop(sprintf("%s: expected %s, got %s", label, deparse(expected), deparse(actual)), call. = FALSE)
}

at_copenhagen <- function(value) as.POSIXct(value, tz = notification_timezone)

state <- empty_notification_state()
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 04:59:00")), character(), "before morning")
assert_identical(notification_slot_is_due(state, "morning", at_copenhagen("2026-09-22 04:59:00")), FALSE, "morning not due early")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 05:00:00")), "morning", "morning boundary")
assert_identical(notification_slot_is_due(state, "morning", at_copenhagen("2026-09-22 05:00:00")), TRUE, "morning due at boundary")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 14:59:00")), "morning", "late morning catch-up")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 15:00:00")), c("morning", "afternoon"), "both slots due")

state <- record_notification_acceptance(state, "2026-09-22", "morning", "request-1", "2026-09-22T03:01:00Z", "run-1")
assert_identical(notification_slot_is_due(state, "morning", at_copenhagen("2026-09-22 06:00:00")), FALSE, "accepted morning not due")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 15:00:00")), "afternoon", "morning deduplicated")
state <- record_notification_acceptance(state, "2026-09-22", "afternoon", "request-2", "2026-09-22T13:01:00Z", "run-2")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-22 23:59:00")), character(), "day complete")
assert_identical(due_notification_slots(state, at_copenhagen("2026-09-23 05:00:00")), "morning", "new day")
assert_identical(due_notification_slots(empty_notification_state(), at_copenhagen("2026-03-29 05:00:00")), "morning", "summer-time boundary")
assert_identical(due_notification_slots(empty_notification_state(), at_copenhagen("2026-10-25 15:00:00")), c("morning", "afternoon"), "winter-time boundary")

legacy_path <- tempfile()
writeLines(c("morning=2026-09-22", "afternoon="), legacy_path)
legacy <- read_notification_state(legacy_path)
if (!notification_was_accepted(legacy, "2026-09-22", "morning")) stop("Legacy state migration failed.", call. = FALSE)

roundtrip_path <- tempfile()
write_notification_state(state, roundtrip_path, as.Date("2026-09-22"))
roundtrip <- read_notification_state(roundtrip_path)
if (!notification_was_accepted(roundtrip, "2026-09-22", "afternoon")) stop("JSON state round-trip failed.", call. = FALSE)

accepted_response <- structure(list(
  url = "https://api.pushover.net/1/messages.json", status_code = 200L,
  headers = list(`content-type` = "application/json"), all_headers = list(), cookies = data.frame(),
  content = charToRaw('{"status":1,"request":"abc-123"}'), date = Sys.time(), times = numeric(),
  request = list(), handle = NULL
), class = "response")
parsed <- parse_pushover_acceptance(accepted_response)
assert_identical(parsed$accepted, TRUE, "accepted response")
assert_identical(parsed$request_id, "abc-123", "request id")

bad_response <- accepted_response
bad_response$content <- charToRaw('{"status":0,"errors":["bad token"]}')
assert_identical(parse_pushover_acceptance(bad_response)$accepted, FALSE, "rejected response")

post_calls <- 0L
retrying_post <- function(...) {
  post_calls <<- post_calls + 1L
  if (post_calls == 1L) stop("temporary network error")
  accepted_response
}
retried <- send_pushover_message(
  "forecast", "title", app_key = "app", user_key = "user", attempts = 2L,
  post = retrying_post, sleep = function(seconds) invisible(seconds)
)
assert_identical(retried$attempts, 2L, "transport retry count")
assert_identical(post_calls, 2L, "transport retried")

cat("Notification tests passed.\n")
