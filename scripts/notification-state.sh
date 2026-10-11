#!/usr/bin/env bash
# Schema-1 state transport. Diagnostics deliberately exclude remote URLs/content.
set -euo pipefail

state_error() {
  local detail="$1"
  printf '{"component":"notification-state","status":"error","reason":"%s"}\n' "$detail" >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '\n```json\n{"component":"notification-state","status":"error","reason":"%s"}\n```\n' "$detail" >> "$GITHUB_STEP_SUMMARY"
  fi
}

validate_state() {
  local path="$1"
  if [[ ! -e $path && ! -L $path ]]; then
    printf '{"schema_version":1,"deliveries":{}}\n'
    return
  fi
  [[ -f $path && -r $path && -s $path ]] || { state_error unreadable_or_empty; return 1; }
  # jq otherwise silently discards duplicate keys. Reject them before validating.
  # Python is part of ubuntu-latest; this remains independent of R setup.
  if ! python3 - "$path" <<'PY'
import json, sys
def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        json.load(handle, object_pairs_hook=unique)
except ValueError as error:
    if str(error) == "duplicate key":
        sys.exit(1)
PY
  then state_error duplicate_json_key; return 1; fi
  jq -es '
    def valid_date:
      if type != "string" then false
      elif (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then false
      else split("-") | map(tonumber) | . as $d |
        ($d[0] > 0 and $d[1] >= 1 and $d[1] <= 12 and $d[2] >= 1 and
         $d[2] <= ([31, (if ($d[0]%4 == 0 and ($d[0]%100 != 0 or $d[0]%400 == 0)) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$d[1]-1] // 0)) end;
    def nonblank: type == "string" and test("[^ \\t\\r\\n]");
    def timestamp:
      if type != "string" then false else
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$") and (.[0:10] | valid_date) end;
    def record:
      if type != "object" then false else
        (keys == ["accepted_at","request_id","run_id"]) and
        (.request_id | nonblank) and (.run_id | nonblank) and (.accepted_at | timestamp) end;
    if length != 1 then error("one document required") else .[0] end |
    if type != "object" then error("object required") else . end |
    if .deliveries == [] then .deliveries = {} else . end |
    if keys != ["deliveries","schema_version"] or .schema_version != 1 or (.deliveries | type) != "object"
    then error("schema") else . end |
    if all(.deliveries | to_entries[];
      (.key | valid_date) and
      (.value | if type != "object" or length == 0 then false else
        all(to_entries[]; (.key == "morning" or .key == "afternoon") and (.value | record)) end))
    then . else error("records") end
  ' "$path" 2>/dev/null && return
  # Only recognized legacy assignments may be migrated; arbitrary text is fatal.
  local line slot value seen=" " count=0 result='{"schema_version":1,"deliveries":{}}'
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -n $line ]] || continue
    [[ $line =~ ^(morning|afternoon)=(.*)$ ]] || { state_error malformed_state; return 1; }
    slot=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ $seen != *" $slot "* ]] || { state_error duplicate_legacy_slot; return 1; }
    seen+="$slot "
    count=$((count + 1))
    if [[ -n $value ]]; then
      [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ${value:0:4} != 0000 ]] &&
        [[ $(date -u -d "$value" +%F 2>/dev/null) == "$value" ]] || { state_error invalid_legacy_date; return 1; }
      result=$(jq --arg date "$value" --arg slot "$slot" \
        '.deliveries[$date][$slot] = {accepted_at: ($date + "T00:00:00+00:00"), request_id:"legacy", run_id:"legacy"}' <<< "$result")
    fi
  done < "$path"
  [[ $count -gt 0 ]] || { state_error malformed_state; return 1; }
  printf '%s\n' "$result"
}

atomic_validate() {
  local input="$1" output="$2" temporary
  temporary=$(mktemp "${output}.tmp.XXXXXX")
  if ! validate_state "$input" > "$temporary"; then
    rm -f "$temporary"; return 1
  fi
  if ! mv -T "$temporary" "$output"; then
    rm -f "$temporary"; state_error atomic_state_replace_failed; return 1
  fi
}

# Return 2 only for positively confirmed branch absence, 1 for transport errors.
fetch_state_branch() {
  local remote="$1" rc=0
  git ls-remote --exit-code "$remote" refs/heads/weather-notification-state > /dev/null 2>&1 || rc=$?
  if [[ $rc == 2 ]]; then return 2; fi
  [[ $rc == 0 ]] || { state_error remote_lookup_failed; return 1; }
  git fetch --quiet --no-tags "$remote" refs/heads/weather-notification-state > /dev/null 2>&1 || {
    state_error remote_fetch_failed; return 1;
  }
  git rev-parse FETCH_HEAD
}

load_state() {
  local output="$1" remote="${2:-origin}" commit rc=0 temporary
  commit=$(fetch_state_branch "$remote") || rc=$?
  if [[ $rc == 2 ]]; then
    temporary=$(mktemp "${output}.tmp.XXXXXX")
    printf '{"schema_version":1,"deliveries":{}}\n' > "$temporary"
    if ! mv -T "$temporary" "$output"; then
      rm -f "$temporary"; state_error atomic_state_replace_failed; return 1
    fi
    return
  fi
  [[ $rc == 0 ]] || return 1
  load_state_commit "$output" "$commit"
}

load_state_commit() {
  local output="$1" commit="$2" temporary object
  object=$(git ls-tree "$commit" -- notification-state.json delivery_state) || {
    state_error remote_tree_unreadable; return 1;
  }
  if [[ $object == *$'\tnotification-state.json'* ]]; then object=notification-state.json
  elif [[ $object == *$'\tdelivery_state'* ]]; then object=delivery_state
  else state_error remote_state_missing; return 1; fi
  temporary=$(mktemp "${output}.raw.XXXXXX")
  if ! git show "$commit:$object" > "$temporary" 2>/dev/null; then
    rm -f "$temporary"; state_error remote_state_unreadable; return 1
  fi
  local result=0
  atomic_validate "$temporary" "$output" || result=$?
  rm -f "$temporary"
  return "$result"
}

merge_state() {
  local latest accepted
  latest=$(validate_state "$1") || return 1
  accepted=$(validate_state "$2") || return 1
  # Latest remote records win conflicts; the accepted journal fills missing slots.
  jq -n --argjson latest "$latest" --argjson accepted "$accepted" \
    '$latest * {deliveries: ($accepted.deliveries * $latest.deliveries)}'
}

persist_state() {
  local path="$1" remote="${2:-origin}" attempts="${3:-3}" today="${4:-$(TZ=Europe/Copenhagen date +%F)}"
  local workspace attempt parent rc tree commit blob keep_after
  [[ $attempts =~ ^[1-9][0-9]*$ && $attempts -le 5 ]] || { state_error invalid_retry_bound; return 1; }
  [[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ${today:0:4} != 0000 ]] &&
    [[ $(date -u -d "$today" +%F 2>/dev/null) == "$today" ]] || { state_error invalid_retention_date; return 1; }
  keep_after=$(date -u -d "$today -30 days" +%F)
  [[ -f $path || -f $path.accepted.json ]] || { state_error accepted_state_missing; return 1; }
  workspace=$(mktemp -d)
  # Use a private index; never switch branches or stage repository credentials.
  for ((attempt=1; attempt<=attempts; attempt++)); do
    rc=0
    parent=$(fetch_state_branch "$remote") || rc=$?
    if [[ $rc == 1 ]]; then continue; fi
    if [[ $rc == 2 ]]; then
      printf '{"schema_version":1,"deliveries":{}}\n' > "$workspace/latest.json"
      parent=""
    elif ! load_state_commit "$workspace/latest.json" "$parent"; then
      rm -rf "$workspace"; return 1
    fi
    if ! merge_state "$workspace/latest.json" "$path" > "$workspace/merged.json"; then
      rm -rf "$workspace"; return 1
    fi
    if [[ -e $path.accepted.json ]] &&
       ! merge_state "$workspace/merged.json" "$path.accepted.json" > "$workspace/journal.json"; then
      rm -rf "$workspace"; return 1
    elif [[ -f $workspace/journal.json ]]; then
      mv "$workspace/journal.json" "$workspace/merged.json"
    fi
    # Prune after all unions so neither the remote nor the journal resurrects
    # records removed by the R writer. Keep the cutoff date itself, as R does.
    jq --arg cutoff "$keep_after" \
      '.deliveries |= with_entries(select(.key >= $cutoff))' \
      "$workspace/merged.json" > "$workspace/pruned.json"
    mv "$workspace/pruned.json" "$workspace/merged.json"
    if [[ -n $parent ]]; then
      GIT_INDEX_FILE="$workspace/index" git read-tree "$parent"
    else
      GIT_INDEX_FILE="$workspace/index" git read-tree --empty
    fi
    blob=$(git hash-object -w "$workspace/merged.json")
    GIT_INDEX_FILE="$workspace/index" git update-index --add --cacheinfo "100644,$blob,notification-state.json"
    tree=$(GIT_INDEX_FILE="$workspace/index" git write-tree)
    if [[ -n $parent && $tree == "$(git rev-parse "$parent^{tree}")" ]]; then
      rm -rf "$workspace"; return 0
    fi
    local parents=()
    [[ -z $parent ]] || parents=(-p "$parent")
    commit=$(git -c user.name='github-actions[bot]' \
      -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
      commit-tree "$tree" "${parents[@]}" -m 'Record accepted weather notifications')
    if git push --quiet "$remote" "$commit:refs/heads/weather-notification-state" > /dev/null 2>&1; then
      rm -rf "$workspace"; return 0
    fi
    # Non-fast-forward and transport failures both retry against a fresh snapshot.
  done
  rm -rf "$workspace"
  state_error persistence_failed_journal_retained
  return 1
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-}" in
    validate) validate_state "$2" ;;
    load) load_state "$2" "${3:-origin}" ;;
    merge) merge_state "$2" "$3" ;;
    persist) persist_state "$2" "${3:-origin}" "${4:-3}" "${5:-}" ;;
    *) state_error invalid_command; exit 1 ;;
  esac
fi
