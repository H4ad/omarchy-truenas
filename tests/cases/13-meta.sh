# shellcheck shell=bash
# Task 6: the meta cadence. /system/info moves slower than the poll, so it is
# fetched once and reused until notify.metaMaxAgeSeconds lapses; alert/list and
# pool stay live every poll. --force-meta refetches the system on top of a
# normal poll.

# The library is sourced here too rather than leaning on 12-config.sh having
# sourced it first, so this file is meaningful on its own.
source "$ROOT/bin/truenas-lib.sh"

system_requests()    { grep -c '/api/v2.0/system/info'       "$STUB_CURL_LOG" || true; }
alert_requests()     { grep -c '/api/v2.0/alert/list'        "$STUB_CURL_LOG" || true; }
pool_requests()      { grep -c '/api/v2.0/pool'              "$STUB_CURL_LOG" || true; }
disk_requests()      { grep -c '/api/v2.0/disk/details'      "$STUB_CURL_LOG" || true; }
disk_temp_requests() { grep -c '/api/v2.0/disk/temperatures' "$STUB_CURL_LOG" || true; }
meta_file()          { jq -r "$1" "$XDG_STATE_HOME/omarchy/truenas/meta.json"; }

# The whole map every poll needs, with the system response variable so a case
# can change it between polls without losing the alert, pool and disk entries.
meta_responses() {
  local rc=${1:-0} code=${2:-200} body=${3:-$ROOT/tests/fixtures/system-info.json}
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" "$rc" "$code" "$body"
  respond_add "/api/v2.0/disk/details"      0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
}

# A system/info body whose version is the one field a case varies.
system_body() {
  jq -c --arg v "$1" '.version = $v' \
    "$ROOT/tests/fixtures/system-info.json" >"$WORK/system.json"
}

test_case "a fresh meta.json suppresses the refetch and the alerts stay live"
setup; single_instance_config
meta_responses
poll
check "the first poll has no cache and asks" 1 "$(system_requests)"
check "and caches the normalized system" 25.04.2 "$(meta_file '.system.data.version')"
check "with an ISO fetch time" true "$(meta_file '.system.fetchedAt | test("^[0-9]{4}-")')"
check "the raw disk rows are cached" 5 "$(meta_file '.disks.rows | length')"
check "with an ISO fetch time of their own" true \
  "$(meta_file '.disks.fetchedAt | test("^[0-9]{4}-")')"
check "the raw temperatures are cached" 5 "$(meta_file '.diskTemps.map | length')"
check "with an ISO fetch time of their own" true \
  "$(meta_file '.diskTemps.fetchedAt | test("^[0-9]{4}-")')"
check "the cold poll fetched the details once" 1 "$(disk_requests)"
check "and the temperatures once" 1 "$(disk_temp_requests)"
poll
check "the second poll stays inside the window" 1 "$(system_requests)"
check "the system still reaches state from the cache" 25.04.2 "$(state '.system.version')"
check "and the alerts request still happened" 2 "$(alert_requests)"
check "so did the pool request" 2 "$(pool_requests)"
check "the cached poll makes no disk request" 1 "$(disk_requests)"
check "nor a temperatures request" 1 "$(disk_temp_requests)"
check "a warm poll is two fast requests" 7 "$(requests)"
check "the disk rows still reach state from the cache" 5 "$(state '.disks | length')"
check "with their temperature normalized" 38 \
  "$(state '.disks[] | select(.name=="sda") | .tempC')"
teardown

test_case "--force-meta spends one more system request and refreshes the version"
setup; single_instance_config
meta_responses
poll
check "the first poll asks once" 1 "$(system_requests)"
system_body 25.10.0
meta_responses 0 200 "$WORK/system.json"
poll
check "a plain poll keeps the cached version" 25.04.2 "$(state '.system.version')"
check "and does not ask again" 1 "$(system_requests)"
check "nor refetches the disks" 1 "$(disk_requests)"
check "nor the temperatures" 1 "$(disk_temp_requests)"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "--force-meta spends exactly one more" 2 "$(system_requests)"
check "and one more disk fetch" 2 "$(disk_requests)"
check "and one more temperatures fetch" 2 "$(disk_temp_requests)"
check "and reports the new version" 25.10.0 "$(state '.system.version')"
check "the alerts are still polled every time" 3 "$(alert_requests)"
teardown

test_case "a changed system body is picked up once the interval lapses"
setup; single_instance_config
meta_responses
poll
check "the cached version" 25.04.2 "$(state '.system.version')"
system_body 25.10.0
meta_responses 0 200 "$WORK/system.json"
poll
check "still cached before the interval" 25.04.2 "$(state '.system.version')"
# Age the cache past the 300s default and the next plain poll refetches.
meta_file '.system.fetchedAt = "2000-01-01T00:00:00Z"' \
  >"$WORK/meta.json"
cp "$WORK/meta.json" "$XDG_STATE_HOME/omarchy/truenas/meta.json"
poll
check "the lapsed cache is refetched" 25.10.0 "$(state '.system.version')"
check "at the cost of one more request" 2 "$(system_requests)"
check "and one more disk fetch" 2 "$(disk_requests)"
check "and one more temperatures fetch" 2 "$(disk_temp_requests)"
teardown

test_case "the default metaMaxAgeSeconds is 300 and the config is honoured"
setup; single_instance_config
check "default" 300 "$(tn_load_config | jq -r '.notify.metaMaxAgeSeconds')"
single_instance_config '{"metaMaxAgeSeconds": 45}'
check "configured" 45 "$(tn_load_config | jq -r '.notify.metaMaxAgeSeconds')"
teardown

test_case "a configured metaMaxAgeSeconds is what the poll uses"
setup; single_instance_config '{"metaMaxAgeSeconds": 0}'
meta_responses
poll
poll
check "a zero interval refetches every poll" 2 "$(system_requests)"
check "and so do the disks" 2 "$(disk_requests)"
check "and the temperatures" 2 "$(disk_temp_requests)"
teardown

test_case "a failed forced refetch leaves state.system null and the cache intact"
setup; single_instance_config
meta_responses
poll
good_fetched=$(meta_file '.system.fetchedAt')
check "the good cache is in place" 25.04.2 "$(meta_file '.system.data.version')"
meta_responses 7 0 /dev/null
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "the forced poll asked again" 2 "$(system_requests)"
check "system is null, not the stale cache" null "$(state '.system')"
check "a warning names the system section" system \
  "$(state '.warnings[] | select(.section=="system") | .section')"
check "the cached data is not overwritten" 25.04.2 "$(meta_file '.system.data.version')"
check "nor is its fetch time advanced" "$good_fetched" "$(meta_file '.system.fetchedAt')"
check "the alerts answered, so the connection is up" true "$(state '.connection.ok')"
teardown

test_case "a failed disk fetch leaves the previous meta byte-for-byte intact"
setup; single_instance_config
meta_responses
poll
before=$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 500 "$ROOT/tests/fixtures/err-500.json"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "the forced poll asked for the disks" 2 "$(disk_requests)"
check "a warning names the disk section" disk \
  "$(state '.warnings[] | select(.section=="disk") | .section')"
check "the meta file is byte-for-byte the previous one" "$before" \
  "$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")"
teardown

test_case "the meta cache round-trips a null system field"
setup; single_instance_config
jq -c 'del(.uptime_seconds, .cores, .physmem)' \
  "$ROOT/tests/fixtures/system-info.json" >"$WORK/system.json"
meta_responses 0 200 "$WORK/system.json"
poll
check "the fresh poll reports an unknown uptime" null "$(state '.system.uptimeSeconds')"
check "and caches it as null, not 0" null "$(meta_file '.system.data.uptimeSeconds')"
check "the version still round-trips" 25.04.2 "$(state '.system.version')"
poll
check "the cached reuse keeps uptime unknown" null "$(state '.system.uptimeSeconds')"
check "and cores unknown" null "$(state '.system.cores')"
check "and physmem unknown" null "$(state '.system.physmem')"
teardown
