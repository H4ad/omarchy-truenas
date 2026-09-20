#!/usr/bin/env bash
# Runs the suite against canned responses, with curl and
# omarchy-notification-send stubbed on PATH, so the whole notification matrix
# is testable with no network and no desktop.
#
# Each file in tests/cases is sourced in name order into this shell, which is
# how they share the pass and fail counters.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

shopt -s nullglob
for case_file in "$HERE"/cases/*.sh; do
  # shellcheck source=/dev/null
  source "$case_file"
done

printf '\nshell: %d passed, %d failed\n' "$PASS" "$FAIL"
shell_ok=$((FAIL == 0 ? 0 : 1))

# Model.js is plain JavaScript with no QML types in it, which is the whole
# reason it can be exercised under node. Missing node is reported rather than
# skipped silently: a suite that quietly stops testing half the logic is worse
# than one that fails.
model_ok=0
if command -v node >/dev/null 2>&1; then
  for suite in model search bar-variants links redact; do
    # A named suite whose file is missing is a failure, not a skip. Continuing
    # here is how the links suite sat registered and unrun while the summary
    # said every suite was green.
    if [[ ! -f $HERE/$suite.mjs ]]; then
      printf '\nthe %s suite is named here and its file is missing\n' "$suite"
      model_ok=1
      continue
    fi
    node "$HERE/$suite.mjs" || model_ok=1
  done
else
  printf '\nthe node suites SKIPPED, node is not installed\n'
  model_ok=1
fi

if ((shell_ok == 0 && model_ok == 0)); then
  printf '\nall suites green\n'
else
  printf '\nFAILED: shell=%d model=%d\n' "$shell_ok" "$model_ok"
fi
((shell_ok == 0 && model_ok == 0))
