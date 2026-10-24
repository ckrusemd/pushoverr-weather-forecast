source("R/weather.R")
source("R/notification.R")
source("R/notification-chart.R")
source("tests/helpers-weather-correctness.R")

local({
  now <- correctness_time("2026-09-22 05:02:00")
  payload <- correctness_payload()
  data <- notification_chart_data(payload, now)
  correctness_equal(nrow(data$hourly), 24L, "24 forecast hours")
  correctness_equal(format(data$start, "%H:%M", tz = data$timezone), "05:00", "Includes current forecast hour")
  correctness_equal(as.numeric(data$end - data$start, units = "hours"), 24, "24 elapsed-hour horizon")
  correctness_equal(data$hourly$pop, rep(20, 24), "PoP converted from fraction to percent")
  shuffled <- payload
  shuffled$hourly <- c(rev(payload$hourly), payload$hourly[6])
  correctness_equal(notification_chart_data(shuffled, now)$hourly, data$hourly,
                    "Sorts input and deduplicates absolute forecast timestamps")

  for (date in c("2026-03-29", "2026-10-25")) {
    p <- correctness_payload(date)
    chart <- notification_chart_data(p, correctness_time(paste(date, "00:05:00")))
    correctness_equal(nrow(chart$hourly), 24L, "DST retains 24 absolute hours")
    correctness_equal(diff(as.numeric(chart$hourly$time)), rep(3600, 23), "DST hours stay contiguous")
    correctness_equal(as.numeric(chart$end - chart$start, units = "hours"), 24, "DST elapsed horizon")
    plot <- notification_chart_plots(chart)$temperature
    labels <- ggplot2::ggplot_build(plot)$layout$panel_params[[1]]$x$get_labels()
    correctness_assert(any(grepl("CET", labels, fixed = TRUE)) && any(grepl("CEST", labels, fixed = TRUE)),
                       "DST axis distinguishes CET/CEST")
  }

  missing <- payload
  missing$hourly <- missing$hourly[-7]
  gap <- notification_chart_data(missing, now)$hourly
  correctness_equal(nrow(gap), 24L, "Missing forecast hour preserved as gap")
  correctness_assert(is.na(gap$temp[2]), "Missing hour does not bridge a temperature line")
  missing <- payload
  for (i in seq_along(missing$hourly)) {
    for (field in c("temp", "uvi", "pop", "clouds", "wind_speed")) missing$hourly[[i]][[field]] <- NULL
    missing$hourly[[i]]$rain <- list(`1h` = NA_real_)
  }
  missing_data <- notification_chart_data(missing, now)
  correctness_assert(all(is.na(missing_data$hourly$uv_index)), "Missing UV stays missing")
  for (plot in notification_chart_plots(missing_data)) invisible(ggplot2::ggplot_build(plot))
  empty <- payload
  empty$hourly <- list()
  correctness_error(notification_chart_data(empty, now), "No hourly forecasts")

  plots <- notification_chart_plots(data)
  correctness_equal(names(plots), c("temperature", "uv", "rain", "clouds_wind"), "Requested grid panel order")
  for (plot in plots) {
    axis <- ggplot2::ggplot_build(plot)$layout$panel_params[[1]]$x
    correctness_equal(length(axis$get_breaks()), 24L, "Every forecast hour has an axis mark")
    correctness_equal(sum(nzchar(axis$get_labels())), 6L, "Labels remain readable at four-hour intervals")
  }
  for (name in c("rain", "clouds_wind")) {
    y <- plots[[name]]$scales$get_scales("y")
    correctness_assert(all(is.finite(y$secondary.axis$trans(c(0, 1)))), "Dry/calm secondary axes finite")
  }
  correctness_assert(inherits(plots$rain$layers[[1]]$geom, "GeomCol"), "Rain uses bars")
  correctness_assert(inherits(plots$rain$layers[[2]]$geom, "GeomLine"), "PoP uses line")

  output <- tempfile(fileext = ".png")
  on.exit(unlink(output), add = TRUE)
  original_device <- grDevices::dev.cur()
  render_notification_chart(payload, output, now = now)
  correctness_equal(grDevices::dev.cur(), original_device, "Renderer restores original graphics device")
  header <- readBin(output, "raw", n = 24)
  correctness_equal(as.integer(header[1:8]), c(137L, 80L, 78L, 71L, 13L, 10L, 26L, 10L), "PNG signature")
  dimension <- function(bytes) sum(as.integer(bytes) * 256^(3:0))
  correctness_equal(dimension(header[17:20]), 1800, "Readable attachment width")
  correctness_equal(dimension(header[21:24]), 1500, "Readable attachment height")
  correctness_assert(file.info(output)$size > 1000 && file.info(output)$size <= 5 * 1024^2,
                     "Actual PNG below Pushover limit")

  response <- structure(list(url = "https://api.pushover.net/1/messages.json", status_code = 200L,
    headers = list(`content-type` = "application/json"),
    content = charToRaw('{"status":1,"request":"chart-accepted"}')), class = "response")
  calls <- 0L
  post <- function(url, body, encode, ...) {
    calls <<- calls + 1L
    correctness_equal(encode, "multipart", "PNG uses multipart transport")
    correctness_equal(body$message, "forecast text", "Chart keeps original message text")
    correctness_assert(inherits(body$attachment, "form_file"), "Binary file upload")
    correctness_equal(body$attachment$type, "image/png", "PNG MIME type")
    correctness_equal(body$attachment$path, normalizePath(output), "Upload points at rendered chart")
    if (calls == 1L) stop("offline temporary failure")
    response
  }
  sent <- send_pushover_message("forecast text", "title", "app", "user", attempts = 2L,
                                post = post, sleep = function(...) NULL, attachment = output)
  correctness_equal(sent$request_id, "chart-accepted", "Acceptance tracked on attachment send")
  correctness_equal(calls, 2L, "Attachment retry preserves original PNG")
  text_post <- function(url, body, encode, ...) {
    correctness_equal(encode, "form", "Text-only transport preserved")
    correctness_assert(is.null(body$attachment), "No image field on text fallback")
    response
  }
  send_pushover_message("forecast text", "title", "app", "user", post = text_post)
  correctness_error(send_pushover_message("text", "title", "app", "user", post = post,
                                         attachment = paste0(output, ".missing")), "readable image")
  oversized <- tempfile(fileext = ".png")
  on.exit(unlink(oversized), add = TRUE)
  writeBin(raw(5 * 1024^2 + 1), oversized)
  correctness_error(send_pushover_message("text", "title", "app", "user", post = post,
                                         attachment = oversized), "no larger than 5 MiB")
})

cat("Notification chart tests passed (layout, DST, gaps, PNG and multipart retries).\n")
