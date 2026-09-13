# shellcheck shell=bash
# Task 5: desktop notifications and seen.json.

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

# The three endpoints every notification case needs. system carries no
# notification and is canned throughout.
notify_endpoints() {
  local alerts=$1 pool=$2
  respond     "/api/v2.0/alert/list"  0 200 "$alerts"
  respond_add "/api/v2.0/pool"        0 200 "$pool"
  respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
}

test_case "a new critical alert toasts once"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "one toast" 1 "$(notifications)"
check "and it names the alert" 1 "$(grep -c 'Pool storage state is DEGRADED' "$STUB_NOTIFY_LOG" || true)"
poll
check "the same alert does not toast again" 1 "$(notifications)"
teardown

test_case "clearing an alert toasts its resolution"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "a resolution toast" 1 "$(grep -c 'Resolved' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "a pool going DEGRADED toasts, recovering is low"
setup; single_instance_config
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a healthy pool is quiet" 0 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-degraded.json"
poll
check "one worsening toast" 1 "$(notifications)"
check "it names the pool" 1 "$(grep -c 'storage' "$STUB_NOTIFY_LOG" || true)"
check "with normal urgency" 1 "$(grep -c -e '-u normal' "$STUB_NOTIFY_LOG" || true)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a recovery toast" 2 "$(notifications)"
check "with low urgency" 1 "$(grep -c -e '-u low' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "an unreachable poll does not replay alerts on recovery"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "exactly one toast across the outage" 1 "$(notifications)"
teardown

test_case "a dismissed alert does not toast and does not resolve"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$(one_alert CRITICAL 'Pool storage state is DEGRADED' true)"
poll
check "no first toast for a dismissed alert" 0 "$(notifications)"
check "and it is not recorded as seen" 0 "$(seen '.alerts | length')"
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "and its absence is not a resolution" 0 "$(notifications)"
teardown

test_case "an alert dismissed after firing is not reported as cleared"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "it fired once" 1 "$(notifications)"
respond "/api/v2.0/alert/list" 0 200 "$(one_alert CRITICAL 'Pool storage state is DEGRADED' true)"
poll
check "dismissing it is silent" 1 "$(notifications)"
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "and going away is silent too" 1 "$(notifications)"
teardown

test_case "the batch threshold collapses new alerts into one summary"
setup; single_instance_config
cat >"$WORK/alerts.json" <<'JSON'
[ { "uuid": "a1", "level": "CRITICAL", "formatted": "crit one", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "a2", "level": "CRITICAL", "formatted": "crit two", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "a3", "level": "CRITICAL", "formatted": "crit three", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "a4", "level": "ERROR", "formatted": "err one", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "a5", "level": "WARNING", "formatted": "warn one", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" } ]
JSON
respond "/api/v2.0/alert/list" 0 200 "$WORK/alerts.json"
poll
check "one summary instead of five" 1 "$(notifications)"
check "it names the count" 1 "$(grep -c '5 new alerts' "$STUB_NOTIFY_LOG" || true)"
check "and how many are critical or error" 1 \
  "$(grep -c '4 critical or error' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "a batch threshold of zero always summarises"
setup; single_instance_config '{"batchThreshold":0}'
respond "/api/v2.0/alert/list" 0 200 "$(one_alert WARNING 'Disk warm')"
poll
check "one summary for one alert" 1 "$(notifications)"
check "name the count" 1 "$(grep -c '1 new alert' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "notify.levels excludes a warning"
setup; single_instance_config '{"levels":["critical"]}'
respond "/api/v2.0/alert/list" 0 200 "$(one_alert WARNING 'Disk warm')"
poll
check "the warning does not toast" 0 "$(notifications)"
check "but it is still recorded, so adding its level later is not a replay" 1 \
  "$(seen '.alerts | length')"
teardown

test_case "a failed poll leaves seen.json byte-identical"
setup; single_instance_config
notify_endpoints "$ROOT/tests/fixtures/alerts-critical.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
before=$(cat "$(seen_file)")
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "seen is byte-identical" "$before" "$(cat "$(seen_file)")"
teardown

test_case "renotify re-toasts a still-firing alert after the interval"
setup; single_instance_config '{"renotifyMinutes":1}'
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "first toast" 1 "$(notifications)"
jq '.alerts["11111111-2222-3333-4444-555555555555"].lastNotifiedAt = "2020-01-01T00:00:00Z"' \
  "$(seen_file)" >"$WORK/seen.json" && mv "$WORK/seen.json" "$(seen_file)"
poll
check "re-toasted" 2 "$(notifications)"
poll
check "but only once per interval" 2 "$(notifications)"
teardown

test_case "with renotify off a still-firing alert stays quiet"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
jq '.alerts["11111111-2222-3333-4444-555555555555"].lastNotifiedAt = "2020-01-01T00:00:00Z"' \
  "$(seen_file)" >"$WORK/seen.json" && mv "$WORK/seen.json" "$(seen_file)"
poll
check "no re-toast" 1 "$(notifications)"
teardown

test_case "resolved false keeps a cleared alert quiet"
setup; single_instance_config '{"resolved":false}'
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "no resolution toast" 1 "$(notifications)"
teardown

test_case "an outage toasts after the threshold and recovery once"
setup; single_instance_config '{"connectionFailuresBeforeToast":2}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a healthy poll is quiet" 0 "$(notifications)"
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "one failure is below the threshold" 0 "$(notifications)"
poll
check "two failures toast" 1 "$(notifications)"
check "naming the outage" 1 "$(grep -c 'unreachable' "$STUB_NOTIFY_LOG" || true)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "recovery toasts once" 2 "$(notifications)"
check "and says it is back" 1 "$(grep -c 'reachable again' "$STUB_NOTIFY_LOG" || true)"
# A fresh outage after recovery fires once, and repeated failures do not
# re-toast while it stays down.
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "below the threshold it stays quiet" 2 "$(notifications)"
poll
check "crossing it toasts again" 3 "$(notifications)"
poll
check "but staying down does not re-toast" 3 "$(notifications)"
teardown

test_case "a toast passes the exec command in the sender's argv form"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "the alert toast is recorded rather than rejected" 1 "$(notifications)"
check "with --exec xdg-open and the URL as separate words" 1 \
  "$(grep -c ' --exec xdg-open ' "$STUB_NOTIFY_LOG" || true)"
check "and the command ends with xdg-open and the URL" 1 \
  "$(awk '{ if ($(NF-1) == "xdg-open" && $NF ~ /^https:\/\//) n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
teardown

test_case "a failed pool section does not wipe or resolve the alert half"
setup; single_instance_config
notify_endpoints "$ROOT/tests/fixtures/alerts-critical.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the alert fired once" 1 "$(notifications)"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-critical.json"
respond_add "/api/v2.0/pool"        7 0 /dev/null
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "the alert half is preserved" 1 "$(seen '.alerts | length')"
check "no resolution toast" 0 "$(grep -c 'Resolved' "$STUB_NOTIFY_LOG" || true)"
poll
check "the still-firing alert stays quiet" 1 "$(notifications)"
teardown

test_case "a section that cannot be normalized is not a resolution"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "the alert fired once" 1 "$(notifications)"
# A valid-shaped array the normalizer cannot read must not empty the alert half
# and read that erasure as the alert having cleared.
printf '[ "not-an-alert" ]' >"$WORK/alerts-unreadable.json"
respond "/api/v2.0/alert/list" 0 200 "$WORK/alerts-unreadable.json"
poll
check "no bogus resolution toast" 1 "$(notifications)"
check "the alert half is preserved" 1 "$(seen '.alerts | length')"
teardown
