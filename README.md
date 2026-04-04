# Pushoverr Weather Forecast

An automated weather forecast system built with R that fetches weather data from the [OpenWeatherMap API](https://openweathermap.org/api) and sends daily push notifications via [Pushover](https://pushover.net/) using the [`pushoverr`](https://github.com/briandconnelly/pushoverr) R package.

## Features

- **Weather Forecasts**: Hourly and daily weather data via OpenWeatherMap One Call API 3.0
- **Push Notifications**: Automated forecast summaries sent to your phone via Pushover
- **Sun Tracking**: Sunrise, sunset, dawn, dusk and other solar events via [`suncalc`](https://github.com/datastorm-open/suncalc)
- **Automated Scheduling**: GitHub Actions workflow runs twice daily on a cron schedule
- **Bookdown Report**: Renders as an HTML bookdown site with weather charts and scorecards

## Setup

### Prerequisites

- R (with [`pacman`](https://github.com/trinker/pacman) for package management)
- API keys for:
  - [OpenWeatherMap](https://openweathermap.org/api) (One Call API 3.0)
  - [Pushover](https://pushover.net/) (App key + User key)

### Environment Variables

Create a `Renviron.site` file in the project root (this file is gitignored):

```
OPENWEATHERMAP_APIKEY=your_openweathermap_api_key
PUSHOVER_USERKEY=your_pushover_user_key
PUSHOVER_APPKEY=your_pushover_app_key
```

### GitHub Actions

The workflow uses GitHub repository secrets for the three API keys above. Configure them in your repository settings under **Settings > Secrets and variables > Actions**.

## Usage

Render the bookdown report locally:

```r
bookdown::render_book("index.Rmd")
```

Or push to the `master` branch to trigger the GitHub Actions workflow automatically.

## License

MIT
