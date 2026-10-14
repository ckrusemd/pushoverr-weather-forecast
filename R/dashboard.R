# Render-scoped data: preparation always replaces the snapshot; consumers only read.
dashboard_snapshot_path <- function() file.path(".weather-build", "weather-snapshot.json")

validate_dashboard_payload <- function(payload) {
  fail <- function(field) stop(sprintf("Invalid dashboard weather field: %s.", field), call. = FALSE)
  number <- function(value, field) {
    if (!is.numeric(value) || length(value) != 1L || !is.finite(value)) fail(field)
  }
  fields <- function(row, required, prefix) {
    if (!is.list(row)) fail(prefix)
    for (field in required) number(row[[field]], paste(prefix, field, sep = "."))
    if (!is.list(row$weather) || !length(row$weather) ||
        !is.character(row$weather[[1]]$description) ||
        length(row$weather[[1]]$description) != 1L || is.na(row$weather[[1]]$description)) {
      fail(paste0(prefix, ".weather"))
    }
  }
  if (!is.list(payload)) fail("payload")
  fields(payload$current, c("dt", "temp", "feels_like"), "current")
  if (!is.list(payload$hourly) || !length(payload$hourly)) fail("hourly")
  for (row in payload$hourly) {
    fields(row, c("dt", "temp", "feels_like", "wind_speed", "clouds"), "hourly")
    for (field in c("pop", "uvi", "humidity")) {
      if (!is.null(row[[field]])) number(row[[field]], paste0("hourly.", field))
    }
    if (!is.null(row$rain)) {
      if (!is.list(row$rain)) fail("hourly.rain")
      if (!is.null(row$rain$`1h`)) number(row$rain$`1h`, "hourly.rain.1h")
    }
  }
  if (!is.list(payload$daily) || !length(payload$daily)) fail("daily")
  for (row in payload$daily) {
    fields(row, c("dt", "sunrise", "sunset", "wind_speed"), "daily")
    if (!is.list(row$temp)) fail("daily.temp")
    for (field in c("min", "max")) number(row$temp[[field]], paste0("daily.temp.", field))
    if (!is.null(row$pop)) number(row$pop, "daily.pop")
  }
  invisible(payload)
}

dashboard_render_time <- function(payload, fixture_path, now) {
  override <- Sys.getenv("WEATHER_RENDER_NOW")
  if (!nzchar(fixture_path)) {
    if (nzchar(override)) stop("WEATHER_RENDER_NOW requires WEATHER_FIXTURE_PATH.", call. = FALSE)
    return(now)
  }
  # Fixtures are deterministic even if rendered years after their synthetic date.
  if (!nzchar(override)) return(as_local_time(payload$current$dt, weather_config$timezone))
  value <- as.POSIXct(override, format = "%Y-%m-%d %H:%M:%S", tz = weather_config$timezone)
  if (is.na(value) || format(value, "%Y-%m-%d %H:%M:%S", tz = weather_config$timezone) != override) {
    stop("WEATHER_RENDER_NOW must be a Copenhagen time: YYYY-MM-DD HH:MM:SS.", call. = FALSE)
  }
  value
}

prepare_dashboard_snapshot <- function(path = dashboard_snapshot_path(),
                                       fixture_path = Sys.getenv("WEATHER_FIXTURE_PATH"),
                                       now = Sys.time(), fetch = fetch_weather) {
  # Invalidate before any operation that might fail; never serve the previous build.
  if (file.exists(path) && unlink(path) != 0L) stop("Cannot invalidate dashboard snapshot.", call. = FALSE)
  payload <- if (nzchar(fixture_path)) {
    jsonlite::fromJSON(fixture_path, simplifyVector = FALSE)
  } else {
    fetch()
  }
  validate_dashboard_payload(payload)
  render_now <- dashboard_render_time(payload, fixture_path, now)
  if (!nzchar(fixture_path) &&
      (as.numeric(now) - payload$current$dt > 6 * 3600 || payload$current$dt - as.numeric(now) > 300)) {
    stop("OpenWeather current observation is stale or in the future.", call. = FALSE)
  }
  snapshot <- list(
    schema_version = 1L,
    build_id = basename(tempfile("weather-render-")),
    prepared_at = as.numeric(now),
    render_now = as.numeric(render_now),
    timezone = weather_config$timezone,
    source = if (nzchar(fixture_path)) "fixture" else "live",
    payload = payload
  )
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile("snapshot-", tmpdir = dirname(path), fileext = ".json")
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(snapshot, temporary, auto_unbox = TRUE, digits = NA)
  # Validate exactly what independent page sessions will read before publishing it.
  read_dashboard_snapshot(temporary, now = now, allow_fixture = nzchar(fixture_path))
  if (!file.rename(temporary, path)) stop("Cannot write dashboard snapshot.", call. = FALSE)
  invisible(snapshot)
}

read_dashboard_snapshot <- function(path = dashboard_snapshot_path(), now = Sys.time(),
                                    max_age_seconds = 3600,
                                    allow_fixture = nzchar(Sys.getenv("WEATHER_FIXTURE_PATH"))) {
  if (!file.exists(path)) stop("Dashboard snapshot missing; run the pre-render preparation.", call. = FALSE)
  snapshot <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  scalar_number <- function(x) is.numeric(x) && length(x) == 1L && is.finite(x)
  scalar_text <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)
  if (!is.list(snapshot) || !identical(snapshot$schema_version, 1L) ||
      !scalar_text(snapshot$build_id) || !scalar_number(snapshot$prepared_at) ||
      !scalar_number(snapshot$render_now) || !identical(snapshot$timezone, weather_config$timezone) ||
      !scalar_text(snapshot$source) || !snapshot$source %in% c("live", "fixture")) {
    stop("Invalid dashboard snapshot schema.", call. = FALSE)
  }
  age <- as.numeric(now) - snapshot$prepared_at
  if (!is.finite(age) || age < -300 || age > max_age_seconds) {
    stop("Dashboard snapshot is stale or in the future; prepare a new render.", call. = FALSE)
  }
  if (snapshot$source == "fixture" && !allow_fixture) {
    stop("Fixture snapshot requires explicit WEATHER_FIXTURE_PATH.", call. = FALSE)
  }
  if (snapshot$source == "live" && abs(snapshot$render_now - snapshot$prepared_at) > 1) {
    stop("Invalid dashboard snapshot render time.", call. = FALSE)
  }
  validate_dashboard_payload(snapshot$payload)
  snapshot
}

dashboard_now <- function(snapshot) as_local_time(snapshot$render_now, snapshot$timezone)

dashboard_daily <- function(snapshot) {
  daily <- daily_frame(snapshot$payload, snapshot$timezone)
  today <- as.Date(dashboard_now(snapshot), tz = snapshot$timezone)
  daily <- daily[which(daily$date >= today & daily$date < today + 7), , drop = FALSE]
  head(daily[order(daily$date), , drop = FALSE], 7)
}

dashboard_today <- function(snapshot) {
  daily <- dashboard_daily(snapshot)
  head(daily[which(daily$date == as.Date(dashboard_now(snapshot), tz = snapshot$timezone)), , drop = FALSE], 1)
}

dashboard_hourly <- function(hourly, now, hours = 48) {
  times <- as.numeric(hourly$time)
  remaining <- hourly[which(times >= as.numeric(now) & times < as.numeric(now) + hours * 3600), , drop = FALSE]
  remaining[order(remaining$time), , drop = FALSE]
}

dashboard_best_hour <- function(hourly, now, tz = weather_config$timezone) {
  # Keep notification helpers unchanged: the dashboard recommends remaining hours today.
  remaining <- dashboard_hourly(hourly, now)
  remaining <- remaining[which(as.Date(remaining$time, tz = tz) == as.Date(now, tz = tz)), , drop = FALSE]
  remaining$score <- outdoor_score(remaining)
  remaining <- remaining[which(is.finite(remaining$score)), , drop = FALSE]
  remaining[which.max(remaining$score), , drop = FALSE]
}

dashboard_number <- function(value, pattern) {
  if (length(value) && is.finite(value[[1]])) sprintf(pattern, value[[1]]) else "Unavailable"
}

dashboard_clock <- function(value, tz = weather_config$timezone) {
  if (length(value) && !is.na(value[[1]])) format(value[[1]], "%H:%M", tz = tz) else "Unavailable"
}

dashboard_freshness <- function(snapshot) {
  stamp <- function(time) format(time, "%Y-%m-%d %H:%M %Z", tz = snapshot$timezone)
  sprintf("Observed %s · Forecast as of %s (Europe/Copenhagen).",
          stamp(as_local_time(snapshot$payload$current$dt, snapshot$timezone)), stamp(dashboard_now(snapshot)))
}

dashboard_chart_theme <- function() {
  ggplot2::theme_minimal(base_size = 13) +
    ggplot2::theme(
      text = ggplot2::element_text(colour = "#e6edf8"),
      axis.text = ggplot2::element_text(colour = "#e6edf8"),
      panel.grid = ggplot2::element_line(colour = "#334155"),
      panel.grid.minor = ggplot2::element_blank(),
      plot.background = ggplot2::element_rect(fill = "#172033", colour = NA),
      panel.background = ggplot2::element_rect(fill = "#172033", colour = NA),
      legend.position = "bottom", legend.key.width = grid::unit(1.5, "cm")
    )
}

dashboard_heatmap_data <- function(hourly, now, tz = weather_config$timezone) {
  hours <- as.integer(format(hourly$time, "%H", tz = tz))
  heat <- hourly[which(as.numeric(hourly$time) >= as.numeric(now) & as.Date(hourly$time, tz = tz) == as.Date(now, tz = tz) &
                        hours >= 7 & hours <= 22), , drop = FALSE]
  heat <- heat[order(heat$time), , drop = FALSE]
  columns <- c("Temperature °C" = "temp", "PoP %" = "pop", "Rain mm" = "rain_mm",
               "Cloud cover %" = "clouds", "UV index" = "uv_index", "Wind m/s" = "wind_speed")
  heat_long <- do.call(rbind, lapply(names(columns), function(label) {
    data.frame(hour = heat$time, variable = rep(label, nrow(heat)), value = heat[[columns[[label]]]])
  }))
  heat_long$hour_label <- format(heat_long$hour, "%H:%M", tz = tz)
  heat_long$variable <- factor(heat_long$variable, levels = names(columns))
  heat_long
}
