#!/usr/bin/env bash
# Lightweight Pages gate; no R, API credentials, polling, or clock waiting.
set -euo pipefail

event=${1:-schedule}
scheduled_delivery=${2:-false}
remote=${5:-origin}
if [[ -z ${3:-} || -z ${4:-} ]]; then
  read -r current_date hour minute <<< "$(TZ=Europe/Copenhagen date '+%F %H %M')"
fi
local_date=${3:-$current_date}
if [[ -n ${4:-} ]]; then local_minute=$4
else local_minute=$((10#$hour * 60 + 10#$minute)); fi

fail() {
  printf '{"component":"pages-gate","status":"error","reason":"%s"}\n' "$1" >&2
  exit 1
}
valid_date() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ${1:0:4} != 0000 ]] &&
    [[ $(date -u -d "$1" +%F 2>/dev/null) == "$1" ]]
}
[[ $scheduled_delivery =~ ^(true|false)$ &&
   $local_minute =~ ^(0|[1-9][0-9]{0,3})$ && $local_minute -lt 1440 ]] &&
  valid_date "$local_date" || fail invalid_gate_input

publish=true reason=manual_dispatch recorded=""
if [[ $event == schedule || $scheduled_delivery == true ]]; then
  status=0
  git ls-remote --exit-code --heads "$remote" refs/heads/weather-pages-state > /dev/null 2>&1 || status=$?
  if [[ $status == 0 ]]; then
    git fetch --quiet --no-tags "$remote" refs/heads/weather-pages-state > /dev/null 2>&1 || fail remote_fetch_failed
    recorded=$(git show FETCH_HEAD:last_deployment_date 2>/dev/null) || fail remote_state_missing
    valid_date "$recorded" || fail invalid_deployment_date
  elif [[ $status != 2 ]]; then
    fail remote_lookup_failed
  fi
  publish=false reason=before_morning
  if [[ $local_minute -ge 300 ]]; then
    reason=already_deployed
    if [[ $recorded != "$local_date" ]]; then publish=true reason=deployment_due; fi
  fi
fi
summary=$(jq -cn --arg event "$event" --argjson scheduled_delivery "$scheduled_delivery" \
  --arg date "$local_date" --argjson minute "$local_minute" --arg recorded "$recorded" \
  --arg reason "$reason" --argjson publish "$publish" \
  '{component:"pages-gate", timezone:"Europe/Copenhagen", event:$event,
    scheduled_delivery:$scheduled_delivery, date:$date, minute:$minute,
    recorded:$recorded, publish:$publish, reason:$reason}')
printf '%s\n' "$summary"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'publish=%s\n' "$publish" >> "$GITHUB_OUTPUT"; fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '\n```json\n%s\n```\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
