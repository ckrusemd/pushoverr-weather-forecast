#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/notification-state.sh"

# Deterministic overrides are Copenhagen date and integer minutes since midnight.
path=${1:?state path required}
event=${2:-schedule}
mode=${3:-reconcile}
slot=${4:-morning}
scheduled_delivery=${7:-false}
if [[ -z ${5:-} || -z ${6:-} ]]; then
  read -r current_date hour minute <<< "$(TZ=Europe/Copenhagen date '+%F %H %M')"
fi
local_date=${5:-$current_date}
if [[ -n ${6:-} ]]; then
  local_minute=$6
else
  local_minute=$((10#$hour * 60 + 10#$minute))
fi
[[ $scheduled_delivery =~ ^(true|false)$ &&
   $mode =~ ^(reconcile|scheduled|force|dry-run)$ && $slot =~ ^(morning|afternoon)$ &&
   $local_minute =~ ^(0|[1-9][0-9]{0,3})$ && $local_minute -lt 1440 &&
   $local_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ${local_date:0:4} != 0000 ]] &&
  [[ $(date -u -d "$local_date" +%F 2>/dev/null) == "$local_date" ]] || {
    state_error invalid_gate_input; exit 1;
  }
if [[ $scheduled_delivery == true && $mode != reconcile ]]; then
  state_error invalid_scheduled_mode; exit 1
fi
state=$(validate_state "$path") || exit 1
due=$(jq -c --arg date "$local_date" --argjson minute "$local_minute" '
  .deliveries[$date] as $records |
  [if $minute >= 300 and $records.morning == null then "morning" else empty end,
   if $minute >= 900 and $records.afternoon == null then "afternoon" else empty end]
' <<< "$state")
notify=false reason=no_slots_due
if [[ $event != schedule && $scheduled_delivery == false ]]; then
  notify=true reason=manual_dispatch
elif [[ $due != '[]' ]]; then
  notify=true reason=slots_due
fi
summary=$(jq -cn --arg date "$local_date" --argjson minute "$local_minute" \
  --arg mode "$mode" --arg event "$event" --argjson scheduled_delivery "$scheduled_delivery" \
  --arg reason "$reason" --argjson due "$due" --argjson notify "$notify" \
  '{component:"notification-gate", timezone:"Europe/Copenhagen", date:$date, minute:$minute,
    event:$event, scheduled_delivery:$scheduled_delivery, mode:$mode, notify:$notify, due:$due, reason:$reason}')
printf '%s\n' "$summary"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'notify=%s\n' "$notify" >> "$GITHUB_OUTPUT"; fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '\n```json\n%s\n```\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
