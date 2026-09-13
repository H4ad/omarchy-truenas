# shellcheck shell=bash
test_case "the harness runs and the workspace is isolated"
setup
check "XDG_STATE_HOME points at the temp dir" "$WORK/state" "$XDG_STATE_HOME"
check "a credentials file the suite wrote is mode 600" 600 \
  "$(stat -c '%a' "$TRUENAS_CREDENTIALS_FILE")"
teardown
