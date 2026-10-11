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

expect_error <- function(code, label) {
  result <- tryCatch({ force(code); NULL }, error = identity)
  if (!inherits(result, "error")) stop(paste(label, "did not fail"), call. = FALSE)
}

test_root <- tempfile("notification-tests-")
dir.create(test_root)
state_helper <- normalizePath("scripts/notification-state.sh")
gate_helper <- normalizePath("scripts/notification-gate.sh")
run_command <- function(command, args, expected_status = 0L) {
  output <- suppressWarnings(system2(command, vapply(args, shQuote, character(1)), stdout = TRUE, stderr = TRUE))
  status <- attr(output, "status")
  if (is.null(status)) status <- 0L
  if (!identical(as.integer(status), as.integer(expected_status)))
    stop(paste(command, "unexpected status", status, paste(output, collapse = "\n")), call. = FALSE)
  invisible(output)
}
shell_state <- function(command, ...) run_command("bash", c(state_helper, command, ...))
fixture <- function(text, name = "fixture.json") {
  path <- file.path(test_root, name)
  writeLines(text, path)
  path
}
shell_read <- function(path) jsonlite::fromJSON(paste(shell_state("validate", path), collapse = "\n"), simplifyVector = FALSE)
assert_identical(read_notification_state(file.path(test_root, "missing")), empty_notification_state(), "missing R state")
assert_identical(shell_read(file.path(test_root, "missing")), empty_notification_state(), "missing Bash state")
assert_identical(read_notification_state(test_root) |> tryCatch(error = function(e) "error"), "error", "directory unreadable")

for (deliveries in c("{}", "[]")) {
  path <- fixture(sprintf('{"schema_version":1,"deliveries":%s}', deliveries))
  assert_identical(read_notification_state(path), empty_notification_state(), paste("R empty", deliveries))
  assert_identical(shell_read(path), empty_notification_state(), paste("Bash empty", deliveries))
  write_notification_state(read_notification_state(path), path, as.Date("2026-09-22"))
  if (!grepl('"deliveries": \\{\\}', paste(readLines(path), collapse = " ")))
    stop("Empty state did not serialize to an object.", call. = FALSE)
}

valid_record <- '{"accepted_at":"2026-09-22T03:00:00Z","request_id":"request-1","run_id":"run-1"}'
valid_json <- sprintf('{"schema_version":1,"deliveries":{"2026-09-22":{"morning":%s}}}', valid_record)
valid_path <- fixture(valid_json)
assert_identical(shell_read(valid_path), read_notification_state(valid_path), "current record parity")
assert_identical(shell_read(legacy_path), read_notification_state(legacy_path), "legacy migration parity")
legacy_ids <- fixture(gsub("request-1", "legacy", gsub("run-1", "legacy", valid_json)), "legacy-ids.json")
assert_identical(shell_read(legacy_ids), read_notification_state(legacy_ids), "schema1 legacy IDs")
conflicting <- fixture(gsub("request-1", "latest-request", valid_json), "conflict.json")
bash_merge <- jsonlite::fromJSON(paste(shell_state("merge", conflicting, valid_path), collapse = "\n"), simplifyVector = FALSE)
assert_identical(bash_merge, merge_notification_state(read_notification_state(conflicting), read_notification_state(valid_path)), "merge conflict parity")
assert_identical(bash_merge$deliveries[["2026-09-22"]]$morning$request_id, "latest-request", "latest acceptance wins conflicts")

malformed <- c(
  "", "garbage", "{", "null", "[]", "{}", '{"schema_version":2,"deliveries":{}}',
  '{"schema_version":1,"deliveries":[{}]}', '{"schema_version":1,"deliveries":null}',
  '{"schema_version":1,"schema_version":1,"deliveries":{}}',
  '{"schema_version":1,"deliveries":{"2026-09-22":[]}}',
  '{"schema_version":1,"deliveries":{"2026-09-22":{"morning":null}}}',
  sub("2026-09-22", "2026-02-30", valid_json), sub("morning", "night", valid_json),
  sub('"request-1"', '""', valid_json), sub('"request-1"', '" \\t\\r\\n"', valid_json, fixed = TRUE),
  sub('"request-1"', '1', valid_json), sub('"request-1"', '["request-1"]', valid_json),
  sub('"request-1"', 'null', valid_json), sub('"run-1"', '""', valid_json),
  sub("T03:00:00Z", "T25:00:00Z", valid_json), sub("T03:00:00Z", "T03:00:00", valid_json),
  sub('"accepted_at"', '"other"', valid_json),
  "morning=2026-02-30", "morning=0000-01-01", "morning=2026-09-22\nmorning=2026-09-22",
  "morning=2026-09-22\nunknown=", paste(valid_json, valid_json)
)
for (i in seq_along(malformed)) {
  path <- fixture(malformed[[i]], paste0("invalid-", i, ".json"))
  expect_error(read_notification_state(path), paste("invalid R", i))
  run_command("bash", c(state_helper, "validate", path), expected_status = 1L)
}
unreadable <- fixture(valid_json, "unreadable.json")
Sys.chmod(unreadable, "0000")
if (file.access(unreadable, 4L) != 0L) {
  expect_error(read_notification_state(unreadable), "unreadable R")
  run_command("bash", c(state_helper, "validate", unreadable), expected_status = 1L)
}
Sys.chmod(unreadable, "0600")
broken_link <- file.path(test_root, "broken-link")
invisible(file.symlink(file.path(test_root, "absent-target"), broken_link))
expect_error(read_notification_state(broken_link), "broken symlink R")
run_command("bash", c(state_helper, "validate", broken_link), expected_status = 1L)

gate <- function(path, date, minute, event = "schedule", mode = "reconcile") {
  output <- run_command("bash", c(gate_helper, path, event, mode, "morning", date, as.character(minute)))
  result <- jsonlite::fromJSON(paste(output, collapse = "\n"), simplifyVector = TRUE)
  result$due <- as.character(unlist(result$due))
  result
}
empty_path <- fixture('{"schema_version":1,"deliveries":[]}', "empty.json")
for (date in c("2026-01-22", "2026-07-22", "2026-03-29", "2026-10-25")) {
  for (minute in c(0L, 299L, 300L, 540L, 899L, 900L, 1439L)) {
    now <- at_copenhagen(sprintf("%s %02d:%02d:00", date, minute %/% 60L, minute %% 60L))
    result <- gate(empty_path, date, minute)
    assert_identical(result$minute, minute, "Copenhagen gate minutes")
    assert_identical(result$due, due_notification_slots(empty_notification_state(), now), "CET/CEST gate parity")
    assert_identical(result$notify, length(result$due) > 0L, "scheduled gate decision")
  }
}
for (mode in c("reconcile", "force", "dry-run"))
  assert_identical(gate(empty_path, "2026-09-22", 0L, "workflow_dispatch", mode)$notify, TRUE, paste("manual", mode))
assert_identical(gate(valid_path, "2026-09-22", 899L)$notify, FALSE, "accepted morning skips R before afternoon")
assert_identical(gate(valid_path, "2026-09-22", 900L)$due, "afternoon", "accepted morning afternoon boundary")
complete_path <- fixture(jsonlite::toJSON(state, auto_unbox = TRUE), "complete.json")
assert_identical(gate(complete_path, "2026-09-22", 1439L)$reason, "no_slots_due", "structured skip reason")
assert_identical(gate(complete_path, "2026-09-22", 1439L)$notify, FALSE, "completed day skips R")
summary_path <- file.path(test_root, "summary")
output_path <- file.path(test_root, "outputs")
old_summary <- Sys.getenv("GITHUB_STEP_SUMMARY", unset = NA_character_)
old_output <- Sys.getenv("GITHUB_OUTPUT", unset = NA_character_)
Sys.setenv(GITHUB_STEP_SUMMARY = summary_path, GITHUB_OUTPUT = output_path)
invisible(gate(complete_path, "2026-09-22", 1439L))
run_command("bash", c(state_helper, "validate", file.path(test_root, "invalid-1.json")), 1L)
if (!any(grepl('"reason":"no_slots_due"', readLines(summary_path))) ||
    !any(grepl('"status":"error"', readLines(summary_path)))) stop("Missing structured summaries.", call. = FALSE)
assert_identical(readLines(output_path), "notify=false", "skip gate output")
if (is.na(old_summary)) Sys.unsetenv("GITHUB_STEP_SUMMARY") else Sys.setenv(GITHUB_STEP_SUMMARY = old_summary)
if (is.na(old_output)) Sys.unsetenv("GITHUB_OUTPUT") else Sys.setenv(GITHUB_OUTPUT = old_output)
run_command("bash", c(gate_helper, valid_path, "schedule", "reconcile", "morning", "2026-02-30", "300"), 1L)
run_command("bash", c(gate_helper, valid_path, "schedule", "reconcile", "morning", "2026-09-22", "1440"), 1L)
for (body in c('{"status":1,"request":" "}', '{"status":true,"request":"id"}',
               '{"status":"1","request":"id"}', '{"status":[1],"request":"id"}',
               '{"status":1.5,"request":"id"}', '{"status":1,"request":["id"]}',
               '{"status":1,"request":"id","request":"other"}', "null", "1", "invalid")) {
  response <- accepted_response
  response$content <- charToRaw(body)
  assert_identical(parse_pushover_acceptance(response)$accepted, FALSE, paste("strict acceptance", body))
}

# Simulate one accepted slot followed by a terminal rejection, without HTTP.
partial_path <- file.path(test_root, "partial.json")
partial <- empty_notification_state()
success <- send_pushover_message("forecast", "title", "app", "user", post = function(...) accepted_response)
partial <- record_notification_acceptance(partial, "2026-09-22", "morning", success$request_id, "2026-09-22T03:00:00Z")
write_notification_state(partial, partial_path, as.Date("2026-09-22"))
bad_response$status_code <- 400L
expect_error(send_pushover_message("forecast", "title", "app", "user", post = function(...) bad_response), "partial rejection")
assert_identical(due_notification_slots(read_notification_state(partial_path), at_copenhagen("2026-09-22 15:00:00")), "afternoon", "partial success persisted")
assert_identical(read_notification_state(paste0(partial_path, ".accepted.json")), partial, "accepted journal")
# A blocked destination must leave both its previous contents and journal intact.
blocked <- file.path(test_root, "blocked")
dir.create(blocked)
expect_error(suppressWarnings(write_notification_state(partial, blocked, as.Date("2026-09-22"))), "atomic replacement failure")
assert_identical(dir.exists(blocked), TRUE, "failed rename preserves destination")
assert_identical(read_notification_state(paste0(blocked, ".accepted.json")), partial, "failed rename retains acceptance")

# Offline transport tests use isolated repositories and local bare remotes.
repo <- file.path(test_root, "repo")
remote <- file.path(test_root, "remote.git")
run_command("git", c("init", "--quiet", repo))
run_command("git", c("init", "--quiet", "--bare", remote))
git <- function(...) run_command("git", c("-C", repo, ...))
git("config", "user.name", "Offline test")
git("config", "user.email", "offline@example.invalid")
git("remote", "add", "origin", remote)
original_branch <- git("branch", "--show-current")
loaded <- file.path(test_root, "loaded.json")
old_wd <- getwd()
setwd(repo)
shell_state("load", loaded)
assert_identical(read_notification_state(loaded), empty_notification_state(), "confirmed remote absence")
new_remote <- file.path(test_root, "new-remote.git")
run_command("git", c("init", "--quiet", "--bare", new_remote))
shell_state("persist", partial_path, new_remote)
shell_state("load", loaded, new_remote)
assert_identical(read_notification_state(loaded), partial, "create remote state branch")
writeLines("morning=2026-09-22", file.path(repo, "delivery_state"))
git("add", "delivery_state")
git("commit", "--quiet", "-m", "legacy")
git("push", "--quiet", "origin", "HEAD:refs/heads/weather-notification-state")
shell_state("load", loaded)
assert_identical(read_notification_state(loaded), legacy_notification_state("morning=2026-09-22"), "remote legacy migration")
remote_state <- record_notification_acceptance(empty_notification_state(), "2026-09-22", "afternoon", "remote-afternoon", "2026-09-22T13:00:00Z")
write_notification_state(remote_state, file.path(repo, "notification-state.json"), as.Date("2026-09-22"))
git("add", "notification-state.json")
git("commit", "--quiet", "-m", "remote afternoon")
git("push", "--quiet", "origin", "HEAD:refs/heads/weather-notification-state")
shell_state("persist", partial_path)
shell_state("load", loaded)
merged <- read_notification_state(loaded)
assert_identical(due_notification_slots(merged, at_copenhagen("2026-09-22 15:00:00")), character(), "merge preserves disjoint remote acceptance")
assert_identical(merged$deliveries[["2026-09-22"]]$afternoon$request_id, "remote-afternoon", "remote record retained")
assert_identical(merged$deliveries[["2026-09-22"]]$morning$request_id, "abc-123", "local record retained")
assert_identical(git("branch", "--show-current"), original_branch, "persistence preserves checkout")
assert_identical(read_notification_state(paste0(partial_path, ".accepted.json")), partial, "persistence preserves journal")

# Receiving hook verifies bounded retries and retained accepted evidence on failure.
hook <- file.path(remote, "hooks", "pre-receive")
counter <- file.path(test_root, "push-count")
writeLines(c("#!/usr/bin/env bash", sprintf("printf 'attempt\\n' >> %s", shQuote(counter)), "exit 1"), hook)
Sys.chmod(hook, "0755")
next_state <- record_notification_acceptance(partial, "2026-09-23", "morning", "next", "2026-09-23T03:00:00Z")
next_path <- file.path(test_root, "next.json")
write_notification_state(next_state, next_path, as.Date("2026-09-23"))
run_command("bash", c(state_helper, "persist", next_path, "origin", "3"), 1L)
assert_identical(length(readLines(counter)), 3L, "bounded push attempts")
assert_identical(read_notification_state(paste0(next_path, ".accepted.json")), next_state, "push failure retains journal")
writeLines(c("#!/usr/bin/env bash", sprintf("printf 'attempt\\n' >> %s", shQuote(counter)),
             sprintf("test $(wc -l < %s) -ge 5", shQuote(counter))), hook)
shell_state("persist", next_path, "origin", "3")
assert_identical(length(readLines(counter)), 5L, "short push retry succeeds")
shell_state("load", loaded)
assert_identical(notification_was_accepted(read_notification_state(loaded), "2026-09-23", "morning"), TRUE, "recovery persistence")

# A concurrent writer advances the remote after our fetch and before our push.
# The next attempt must merge that new record instead of overwriting it.
writer <- file.path(test_root, "writer")
run_command("git", c("clone", "--quiet", "--branch", "weather-notification-state", remote, writer))
run_command("git", c("-C", writer, "config", "user.name", "Concurrent test"))
run_command("git", c("-C", writer, "config", "user.email", "concurrent@example.invalid"))
concurrent <- record_notification_acceptance(read_notification_state(loaded), "2026-09-24", "afternoon", "concurrent", "2026-09-24T13:00:00Z")
write_notification_state(concurrent, file.path(writer, "notification-state.json"), as.Date("2026-09-24"))
run_command("git", c("-C", writer, "add", "notification-state.json"))
run_command("git", c("-C", writer, "commit", "--quiet", "-m", "concurrent afternoon"))
client_hook <- file.path(repo, ".git", "hooks", "pre-push")
flag <- file.path(test_root, "race-completed")
writeLines(c("#!/usr/bin/env bash", "set -euo pipefail", sprintf("if [[ ! -e %s ]]; then", shQuote(flag)),
             sprintf("  touch %s", shQuote(flag)),
             sprintf("  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C %s push --quiet origin HEAD:refs/heads/weather-notification-state", shQuote(writer)),
             "fi"), client_hook)
Sys.chmod(client_hook, "0755")
race <- record_notification_acceptance(next_state, "2026-09-24", "morning", "race-local", "2026-09-24T03:00:00Z")
race_path <- file.path(test_root, "race.json")
write_notification_state(race, race_path, as.Date("2026-09-24"))
shell_state("persist", race_path)
shell_state("load", loaded)
assert_identical(read_notification_state(loaded)$deliveries[["2026-09-24"]]$afternoon$request_id, "concurrent", "race retains concurrent remote record")
assert_identical(read_notification_state(loaded)$deliveries[["2026-09-24"]]$morning$request_id, "race-local", "race retains local acceptance")
assert_identical(length(readLines(counter)), 8L, "race includes concurrent push and retries rejected update")

# Recovery can proceed from just the journal if the working state was lost.
journal_only <- file.path(test_root, "journal-only.json")
journal_state <- record_notification_acceptance(race, "2026-09-25", "morning", "journal-only", "2026-09-25T03:00:00Z")
write_notification_state(journal_state, journal_only, as.Date("2026-09-25"))
unlink(journal_only)
shell_state("persist", journal_only)
shell_state("load", loaded)
assert_identical(notification_was_accepted(read_notification_state(loaded), "2026-09-25", "morning"), TRUE, "journal-only recovery")

run_command("bash", c(state_helper, "load", loaded, file.path(test_root, "nonexistent-remote")), 1L)
assert_identical(notification_was_accepted(read_notification_state(loaded), "2026-09-23", "morning"), TRUE, "transport failure preserves loaded state")
writeLines("malformed", file.path(repo, "notification-state.json"))
git("add", "notification-state.json")
git("commit", "--quiet", "-m", "corrupt state")
git("push", "--quiet", "--force", "origin", "HEAD:refs/heads/weather-notification-state")
run_command("bash", c(state_helper, "load", loaded), 1L)
run_command("bash", c(state_helper, "persist", next_path), 1L)
assert_identical(notification_was_accepted(read_notification_state(loaded), "2026-09-23", "morning"), TRUE, "malformed remote cannot reset local state")
# Existing branch without either recognized file is a failure, not absence.
git("rm", "--quiet", "notification-state.json", "delivery_state")
git("commit", "--quiet", "-m", "missing files")
git("push", "--quiet", "--force", "origin", "HEAD:refs/heads/weather-notification-state")
run_command("bash", c(state_helper, "load", loaded), 1L)
assert_identical(notification_was_accepted(read_notification_state(loaded), "2026-09-25", "morning"), TRUE, "missing remote files cannot reset state")
setwd(old_wd)
unlink(test_root, recursive = TRUE)

cat("Notification tests passed (offline R/Bash parity, gate, journal and Git persistence).\n")
