#!/usr/bin/env bash
set -euo pipefail

aggregate() {
  if [[ "$#" != 3 ]]; then
    echo 'linux ci: invalid integration aggregate arguments' >&2
    return 2
  fi
  local result
  for result in "$@"; do
    printf 'integration_lane=%s\n' "$result"
  done
  if [[ "$1" != success || "$2" != success || "$3" != success ]]; then
    echo 'linux ci: integration lane did not succeed' >&2
    return 1
  fi
}
self_test() (
  set -euo pipefail
  local first second third admitted=0 rejected=0 status
  for first in success failure skipped cancelled; do
    for second in success failure skipped cancelled; do
      for third in success failure skipped cancelled; do
        if aggregate "$first" "$second" "$third" >/dev/null 2>&1; then status=0; else status=$?; fi
        if [[ "$first/$second/$third" == success/success/success ]]; then
          [[ "$status" == 0 ]] || exit 1
          admitted=$((admitted + 1))
        else
          [[ "$status" != 0 ]] || exit 1
          rejected=$((rejected + 1))
        fi
      done
    done
  done
  [[ "$admitted" == 1 && "$rejected" == 63 ]] || exit 1
  if aggregate success success >/dev/null 2>&1; then status=0; else status=$?; fi
  [[ "$status" == 2 ]] || exit 1
  printf 'integration aggregate self-test PASS (64 combinations, admitted=%s, rejected=%s)\n' "$admitted" "$rejected"
)

if [[ "$#" == 1 && "$1" == --self-test ]]; then self_test; exit; fi
aggregate "$@"
