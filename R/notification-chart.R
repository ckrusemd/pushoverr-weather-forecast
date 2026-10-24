# Offline chart rendering: reuses the sender's forecast, never fetches weather.
notification_chart_data <- function(payload, now = Sys.time(), config = weather_config) {
  start <- as_local_time(floor(as.numeric(now) / 3600) * 3600, config$timezone)
  end <- start + 24 * 3600
  hourly <- hourly_frame(payload, config$timezone)
  hourly <- hourly[which(!is.na(hourly$time) & hourly$time >= start & hourly$time < end), , drop = FALSE]
  hourly <- hourly[order(hourly$time), , drop = FALSE]
  hourly <- hourly[!duplicated(hourly$time), , drop = FALSE]
  if (!nrow(hourly)) stop("No hourly forecasts in the next 24 hours.", call. = FALSE)
  # Keep missing data missing, rather than drawing a reassuring zero forecast.
  for (column in c("temp", "uv_index", "pop", "rain_mm", "clouds", "wind_speed")) {
    invalid <- !is.finite(hourly[[column]])
    if (column != "temp") invalid <- invalid | hourly[[column]] < 0
    if (column %in% c("pop", "clouds")) invalid <- invalid | hourly[[column]] > 100
    hourly[[column]][invalid] <- NA_real_
  }
  # Insert missing forecast hours to break lines instead of bridging gaps.
  complete <- data.frame(time = seq(start, end - 3600, by = "hour"))
  hourly <- merge(complete, hourly, by = "time", all.x = TRUE, sort = TRUE)
  list(hourly = hourly, start = start, end = end, timezone = config$timezone)
}

notification_chart_plots <- function(data) {
  hourly <- data$hourly
  positive_max <- function(values, minimum) {
    max(c(minimum, values[is.finite(values)]))
  }
  rain_max <- max(1, ceiling(positive_max(hourly$rain_mm, 0) * 1.15 * 2) / 2)
  wind_max <- max(5, ceiling(positive_max(hourly$wind_speed, 0) * 1.1 / 5) * 5)
  uv_max <- max(3, ceiling(positive_max(hourly$uv_index, 0) * 1.1))
  crosses_dst <- format(data$start, "%z", tz = data$timezone) != format(data$end, "%z", tz = data$timezone)
  time_labels <- if (crosses_dst) "%d %b\n%H:%M %Z" else "%d %b\n%H:%M"
  hour_breaks <- seq(data$start, data$end - 3600, by = 3600)
  # Mark every forecast hour, but space labels out for the phone-sized panels.
  label_hours <- function(times) {
    labels <- format(times, time_labels, tz = data$timezone)
    labels[!as.numeric(times) %in% as.numeric(hour_breaks[seq(1, 24, by = 4)])] <- ""
    labels
  }
  base <- ggplot2::ggplot(hourly, ggplot2::aes(x = time)) +
    ggplot2::scale_x_datetime(
      timezone = data$timezone, limits = c(data$start - 1800, data$end - 1800),
      breaks = hour_breaks, labels = label_hours, minor_breaks = NULL,
      expand = ggplot2::expansion(mult = 0)
    ) +
    ggplot2::labs(x = NULL) +
    ggplot2::theme_minimal(base_size = 12, base_family = "sans") +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_line(colour = "#cbd5e1", linewidth = 0.4),
      axis.ticks.x = ggplot2::element_line(colour = "#64748b", linewidth = 0.4),
      axis.ticks.length = grid::unit(3, "pt"),
      panel.grid.major.y = ggplot2::element_line(colour = "#e2e8f0"),
      plot.title = ggplot2::element_text(face = "bold", size = 15, colour = "#172337"),
      axis.text = ggplot2::element_text(colour = "#41516b", size = 10),
      axis.title = ggplot2::element_text(size = 11),
      legend.position = "bottom", legend.title = ggplot2::element_blank(),
      legend.text = ggplot2::element_text(size = 10),
      plot.margin = ggplot2::margin(10, 12, 10, 12)
    )
  unavailable <- function(plot, columns) {
    if (all(vapply(columns, function(column) !any(is.finite(hourly[[column]])), logical(1))))
      plot <- plot + ggplot2::annotate("text", x = data$start + 12 * 3600, y = 0,
                                      label = "Forecast unavailable", colour = "#64748b", size = 4)
    plot
  }
  temperature <- base +
    ggplot2::geom_line(ggplot2::aes(y = temp), colour = "#df5945", linewidth = 1.15, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = temp), colour = "#df5945", size = 1.8, na.rm = TRUE) +
    ggplot2::labs(title = "Temperature", y = "Temperature (°C)")
  uv <- base +
    ggplot2::geom_area(ggplot2::aes(y = uv_index), stat = "identity", fill = "#f7c86a", alpha = 0.3, na.rm = TRUE) +
    ggplot2::geom_line(ggplot2::aes(y = uv_index), colour = "#b97509", linewidth = 1.15, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = uv_index), colour = "#b97509", size = 1.8, na.rm = TRUE) +
    ggplot2::scale_y_continuous(limits = c(0, uv_max), expand = ggplot2::expansion(mult = c(0, 0.06))) +
    ggplot2::labs(title = "UV index", y = "UV index")
  rain <- base +
    ggplot2::geom_col(ggplot2::aes(y = rain_mm, fill = "Rain (mm)"), width = 2700, na.rm = TRUE) +
    ggplot2::geom_line(ggplot2::aes(y = pop * rain_max / 100, colour = "PoP (%)"),
                       linewidth = 1.15, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = pop * rain_max / 100, colour = "PoP (%)"),
                        size = 1.8, na.rm = TRUE) +
    ggplot2::scale_fill_manual(values = c("Rain (mm)" = "#559bce")) +
    ggplot2::scale_colour_manual(values = c("PoP (%)" = "#9a438a")) +
    ggplot2::scale_y_continuous(
      name = "Rain (mm per hour)", limits = c(0, rain_max), expand = ggplot2::expansion(mult = c(0, 0.04)),
      sec.axis = ggplot2::sec_axis(~ . * 100 / rain_max, name = "Rain chance (%)", breaks = seq(0, 100, 25))
    ) + ggplot2::labs(title = "Rain amount & probability")
  clouds_wind <- base +
    ggplot2::geom_area(ggplot2::aes(y = clouds, fill = "Clouds (%)"), stat = "identity", alpha = 0.55, na.rm = TRUE) +
    ggplot2::geom_line(ggplot2::aes(y = wind_speed * 100 / wind_max, colour = "Wind (m/s)"),
                       linewidth = 1.15, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = wind_speed * 100 / wind_max, colour = "Wind (m/s)"),
                        size = 1.8, na.rm = TRUE) +
    ggplot2::scale_fill_manual(values = c("Clouds (%)" = "#a6b1c0")) +
    ggplot2::scale_colour_manual(values = c("Wind (m/s)" = "#11867a")) +
    ggplot2::scale_y_continuous(
      name = "Cloud cover (%)", limits = c(0, 100), breaks = seq(0, 100, 25),
      expand = ggplot2::expansion(mult = c(0, 0.04)),
      sec.axis = ggplot2::sec_axis(~ . * wind_max / 100, name = "Wind (m/s)")
    ) + ggplot2::labs(title = "Cloud cover & wind")
  list(
    temperature = unavailable(temperature, "temp"), uv = unavailable(uv, "uv_index"),
    rain = unavailable(rain, c("rain_mm", "pop")),
    clouds_wind = unavailable(clouds_wind, c("clouds", "wind_speed"))
  )
}

render_notification_chart <- function(payload, path, config = weather_config, now = Sys.time()) {
  data <- notification_chart_data(payload, now, config)
  plots <- notification_chart_plots(data)
  # Grob layout needs font metrics. Use an off-screen device, not Rplots.pdf
  # in the checkout; ggsave opens and closes its own PNG device afterwards.
  grDevices::pdf(file = NULL, width = 12, height = 10)
  metrics_device <- grDevices::dev.cur()
  on.exit(grDevices::dev.off(metrics_device), add = TRUE)
  grobs <- lapply(plots, ggplot2::ggplotGrob)
  # Equal panel widths keep hourly ticks aligned even with secondary axes.
  widths <- do.call(grid::unit.pmax, lapply(grobs, function(grob) grob$widths))
  for (i in seq_along(grobs)) grobs[[i]]$widths <- widths
  figure <- gtable::gtable(
    widths = grid::unit(c(1, 1), "null"),
    heights = grid::unit.c(grid::unit(0.85, "inches"), grid::unit(c(1, 1), "null"), grid::unit(0.3, "inches"))
  )
  title <- grid::textGrob(paste(config$location_name, "| Next 24 hours"),
    x = grid::unit(0.18, "inches"), y = 0.72, just = "left",
    gp = grid::gpar(fontsize = 22, fontface = "bold", col = "#172337"))
  subtitle <- grid::textGrob(sprintf("%s – %s  |  %s",
    format(data$start, "%a %d %b %H:%M %Z", tz = config$timezone),
    format(data$end, "%a %d %b %H:%M %Z", tz = config$timezone), config$timezone),
    x = grid::unit(0.18, "inches"), y = 0.23, just = "left",
    gp = grid::gpar(fontsize = 11, col = "#52637a"))
  figure <- gtable::gtable_add_grob(figure, grid::grobTree(title, subtitle), t = 1, l = 1, r = 2)
  figure <- gtable::gtable_add_grob(figure, grobs, t = c(2, 2, 3, 3), l = c(1, 2, 1, 2))
  caption <- grid::textGrob("Hourly forecast | PoP = probability of precipitation | Source: OpenWeather",
    gp = grid::gpar(fontsize = 10, col = "#52637a"))
  figure <- gtable::gtable_add_grob(figure, caption, t = 4, l = 1, r = 2)
  ggplot2::ggsave(path, plot = figure, device = "png", width = 12, height = 10,
                  units = "in", dpi = 150, bg = "white")
  if (!file.exists(path) || !is.finite(file.info(path)$size) || file.info(path)$size <= 0 ||
      file.info(path)$size > 5 * 1024^2)
    stop("Forecast image is empty or exceeds the Pushover 5 MiB limit.", call. = FALSE)
  invisible(path)
}
