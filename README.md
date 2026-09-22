# Weather Console

A dark, responsive [Quarto](https://quarto.org/) weather dashboard for Copenhagen. It fetches live [OpenWeatherMap](https://openweathermap.org/api) data, publishes to GitHub Pages, and sends concise forecasts through [Pushover](https://pushover.net/).

## Features

- **Weather Forecasts**: Hourly and daily weather data via OpenWeatherMap One Call API 3.0
- **Dashboard**: Current conditions, outdoor score, 48-hour forecast, seven-day outlook and daylight view
- **Pushover notifications**: A full morning forecast after 05:00 and a refreshed rest-of-day outlook after 15:00 Europe/Copenhagen
- **GitHub Pages**: The site is rebuilt on pushes and once daily after 05:00 Europe/Copenhagen
- **Preserved analysis**: The former detailed report remains in `weather_pushoverr.Rmd` as a historical source during the Quarto migration

## Setup

### Prerequisites

- R 4.2+ and Quarto
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

Render the dashboard locally (with `OPENWEATHERMAP_APIKEY` set):

```bash
quarto render
```

The GitHub Actions workflows need `OPENWEATHERMAP_APIKEY`, `PUSHOVER_USERKEY`, and `PUSHOVER_APPKEY` stored as repository secrets. They never write secrets to files or the published site. Notification delivery is independent from Pages, reconciles every 15 minutes, retries transient failures, and records confirmed Pushover request IDs on the state branch. Delayed GitHub cron runs catch up every missing slot in the same run.

## License

MIT
