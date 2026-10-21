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

# The verb is argv; the name or uuid is stdin, which is the panel's contract
# and the reason the target has no place in a process listing. A call with no
# target gets EOF so the helper complains instead of blocking a terminal run.
api() {
  local verb=${1:-} target=${2:-}
  if (( $# > 1 )); then
    "$ROOT/bin/truenas-api" "$verb" <<<"$target"
  else
    "$ROOT/bin/truenas-api" "$verb" </dev/null
  fi
}

# ------------------------------------------------- notification fixtures
# The builders every notification case needs: the fifteen endpoint map, one-row
# variants of the replication, cloud sync, service and app fixtures, and the
# seen.json accessors. Kept here rather than in a case file so a case that sorts
# before or after 11-notify.sh can use them.

# The poll writes seen.json under the XDG state home setup() exports, which is
# not known when this file is sourced, so the path is resolved per call.
seen_file() { printf '%s/omarchy/truenas/seen.json' "$XDG_STATE_HOME"; }
seen() { jq -r "$1" "$(seen_file)" 2>/dev/null; }

# One alert body written into $WORK and printed, so a case can hand it straight
# to respond without a fixture for every level and dismissal state.
one_alert() {
  local level=$1 text=$2 dismissed=${3:-false}
  local uuid=${4:-11111111-2222-3333-4444-555555555555}
  cat >"$WORK/alert-one.json" <<JSON
[ { "uuid": "$uuid", "level": "$level", "formatted": "$text", "text": "$text",
    "dismissed": $dismissed, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" } ]
JSON
  printf '%s' "$WORK/alert-one.json"
}

# The fifteen endpoints every notification case needs. system carries no
# notification and is canned throughout; the temperatures default to the cool
# fixture so an alert or pool case cannot grow a disk toast by accident, and the
# service and app lists default to the all-running fixtures so only a case that
# asks for a down row can grow a service or app toast. The shares and interfaces
# are quiet and canned too: they only need to answer so the meta cache reaches
# the warm path, and M5 adds no share or network notification.
notify_endpoints() {
  local alerts=$1 pool=$2 temps=${3:-"$ROOT/tests/fixtures/disk-temperatures.json"}
  local services=${4:-"$ROOT/tests/fixtures/services.json"}
  local apps=${5:-"$ROOT/tests/fixtures/apps.json"}
  local replication=${6:-"$ROOT/tests/fixtures/replication.json"}
  local cloudsync=${7:-"$ROOT/tests/fixtures/cloudsync.json"}
  local snapshots=${8:-$(quiet_snapshot_tasks)}
  local scrubs=${9:-$(quiet_scrubs)}
  respond     "/api/v2.0/alert/list"  0 200 "$alerts"
  # The specific pool sub-routes come before /api/v2.0/pool, because the stub
  # matches a URL by substring.
  respond_add "/api/v2.0/pool/snapshottask" 0 200 "$snapshots"
  respond_add "/api/v2.0/pool/scrub"        0 200 "$scrubs"
  respond_add "/api/v2.0/pool"        0 200 "$pool"
  respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
  respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$temps"
  respond_add "/api/v2.0/service"     0 200 "$services"
  respond_add "/api/v2.0/app"         0 200 "$apps"
  respond_add "/api/v2.0/replication" 0 200 "$replication"
  respond_add "/api/v2.0/cloudsync"   0 200 "$cloudsync"
  respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
  respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
  respond_add "/api/v2.0/iscsi/target" 0 200 "$ROOT/tests/fixtures/iscsi-target.json"
  respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
}

# Snapshot and scrub fixtures with every task disabled. A notification case
# that is not about protection starts from zero toasts: an enabled task with no
# recent run would otherwise be overdue on the first poll.
quiet_snapshot_tasks() {
  jq -c 'map(.enabled = false)' \
    "$ROOT/tests/fixtures/snapshot-tasks.json" >"$WORK/quiet-snapshot-tasks.json"
  printf '%s' "$WORK/quiet-snapshot-tasks.json"
}

quiet_scrubs() {
  jq -c 'map(.enabled = false)' \
    "$ROOT/tests/fixtures/scrubs.json" >"$WORK/quiet-scrubs.json"
  printf '%s' "$WORK/quiet-scrubs.json"
}

# The protection half of the map on its own: quiet alerts and pools, the real
# disks and services, and the replication and cloud sync bodies a case varies.
notify_protection() {
  local replication=$1 cloudsync=${2:-"$ROOT/tests/fixtures/cloudsync.json"}
  notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" \
    "$ROOT/tests/fixtures/pools-healthy.json" \
    "$ROOT/tests/fixtures/disk-temperatures.json" \
    "$ROOT/tests/fixtures/services.json" \
    "$ROOT/tests/fixtures/apps.json" \
    "$replication" "$cloudsync"
}

# A copy of the snapshot fixture with task id 1's last run moved back by
# `agoSeconds`, so an overdue case is relative to the poll's own clock.
snap_run_ago() {
  local ago=$1 out=$2 stamp
  stamp=$(date -u -d "@$(( $(date +%s) - ago ))" +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg s "$stamp" \
    'map(if .id == 1 then .state.datetime = $s else . end)' \
    "$ROOT/tests/fixtures/snapshot-tasks.json" >"$out"
}

# The pool fixture with storage's scrub finish moved back by `agoSeconds`, so a
# scrub overdue case does not depend on the fixture's calendar date.
pool_scrub_ago() {
  local ago=$1 out=$2 stamp
  stamp=$(date -u -d "@$(( $(date +%s) - ago ))" +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg s "$stamp" \
    'map(if .name == "storage" then
           .scan.function = "SCRUB" | .scan.state = "FINISHED"
           | .scan.end_time = $s
         else . end)' \
    "$ROOT/tests/fixtures/pools-healthy.json" >"$out"
}

# A copy of the replication fixture with task id 1's job state and error set.
rep_job() {
  local id=$1 state=$2 error=${3:-} out=$4
  jq -c --argjson id "$id" --arg s "$state" --arg e "$error" \
    'map(if .id == $id then .job = { state: $s, time_finished: null,
             error: (if $e == "" then null else $e end) } else . end)' \
    "$ROOT/tests/fixtures/replication.json" >"$out"
}

# A copy of the replication fixture with a warning on task id 1's task state.
rep_warn() {
  local id=$1 out=$2
  jq -c --argjson id "$id" \
    'map(if .id == $id then .state = { state: "FINISHED", datetime: null,
             warnings: ["snapshot failed"], last_snapshot: null }
         else . end)' \
    "$ROOT/tests/fixtures/replication.json" >"$out"
}

# A one-row cloud sync body with the job state and error a case wants.
cs_job() {
  local state=$1 error=${2:-} out=$3
  jq -nc --arg s "$state" --arg e "$error" \
    '[ { id: 3, description: "clouda", path: "/mnt/storage", enabled: true,
         direction: "PUSH", transfer_mode: "SYNC", schedule: null,
         job: { state: $s, time_finished: null,
                error: (if $e == "" then null else $e end) } } ]' >"$out"
}

# A copy of the service or app fixture with one row moved to another state, so a
# case can drive a single transition without restating the whole list.
down_service() {
  local name=$1 state=$2 out=$3
  jq -c --arg n "$name" --arg s "$state" \
    'map(if .service == $n then .state = $s else . end)' \
    "$ROOT/tests/fixtures/services.json" >"$out"
}

down_app() {
  local name=$1 state=$2 out=$3
  jq -c --arg n "$name" --arg s "$state" \
    'map(if .name == $n then .state = $s else . end)' \
    "$ROOT/tests/fixtures/apps.json" >"$out"
}
