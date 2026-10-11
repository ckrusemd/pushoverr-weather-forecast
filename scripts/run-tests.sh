#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"
export TZ=Europe/Copenhagen
# Tests use fixtures and mocked transports, never production credentials.
unset OPENWEATHERMAP_APIKEY PUSHOVER_APPKEY PUSHOVER_USERKEY
shopt -s nullglob

shell_scripts=(scripts/*.sh)
shell_tests=(tests/test-*.sh)
for script in "${shell_scripts[@]}" "${shell_tests[@]}"; do
  printf 'Checking shell syntax: %s\n' "$script"
  bash -n "$script"
done

r_tests=(tests/test-*.R)
if [ "${#r_tests[@]}" -eq 0 ]; then
  echo "No tests/test-*.R files found." >&2
  exit 1
fi

for test_file in "${r_tests[@]}"; do
  printf 'Running offline R test: %s\n' "$test_file"
  Rscript --vanilla "$test_file"
done

for test_file in "${shell_tests[@]}"; do
  printf 'Running offline shell helper test: %s\n' "$test_file"
  bash "$test_file"
done

printf 'All offline tests passed.\n'
