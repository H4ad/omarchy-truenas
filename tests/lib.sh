# Sourced by tests/run.sh. Every helper a case file may use lives here, so a
# case file is nothing but test_case blocks and can be added without touching
# any file another task owns.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0

setup() {
  WORK=$(mktemp -d)
  export XDG_STATE_HOME="$WORK/state"
  export TRUENAS_CONFIG_FILE="$WORK/config.json"
  export TRUENAS_CREDENTIALS_FILE="$WORK/credentials"
  export TRUENAS_NOTIFY_BIN=omarchy-notification-send
  export STUB_MAP="$WORK/map.tsv"
  export STUB_NOTIFY_LOG="$WORK/notify.log"
  export STUB_CURL_LOG="$WORK/curl.log"
  export STUB_METHOD_LOG="$WORK/method.log"
  export STUB_PAYLOAD_LOG="$WORK/payload.log"
  unset STUB_CURL_HEADER_LOG # the one HTTP-quoting case opts in; others must not inherit it
  unset STUB_INSECURE_LOG    # the -k case opts in the same way
  export PATH="$ROOT/tests/stubs:$PATH"
  : >"$STUB_MAP"; : >"$STUB_NOTIFY_LOG"; : >"$STUB_CURL_LOG"
  : >"$STUB_METHOD_LOG"; : >"$STUB_PAYLOAD_LOG"
  STATE="$WORK/state/omarchy/truenas/state.json"
  HISTORY="$WORK/state/omarchy/truenas/history.json"
  printf 'TRUENAS_API_KEY=test-key\n' >"$TRUENAS_CREDENTIALS_FILE"
  chmod 600 "$TRUENAS_CREDENTIALS_FILE"
}

teardown() { rm -rf "$WORK"; }

single_instance_config() {
  local notify=${1:-"{}"}
  cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "schema": 1, "pollSeconds": 30, "timeoutSeconds": 8,
  "insecureTLS": true,
  "instances": [ { "id": "nas", "label": "NAS",
    "baseUrl": "https://nas.example:4433" } ],
  "notify": $notify }
JSON
}

respond() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$STUB_MAP"; }
respond_add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$STUB_MAP"; }

poll() { "$ROOT/bin/truenas-poll" --quiet; }
state() { jq -r "$1" "$STATE"; }
history() { jq -r "$1" "$HISTORY"; }
notifications() { awk 'END { print NR + 0 }' "$STUB_NOTIFY_LOG"; }
requests() { awk 'END { print NR + 0 }' "$STUB_CURL_LOG"; }

check() {
  local what=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$what"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       want %q\n       got  %q\n' "$what" "$want" "$got"
  fi
}

test_case() { printf '\n%s\n' "$1"; }

api() { "$ROOT/bin/truenas-api" "$@"; }
