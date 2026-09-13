# shellcheck shell=bash
# Task 6: the meta cadence. /system/info moves slower than the poll, so it is
# fetched once and reused until notify.metaMaxAgeSeconds lapses; alert/list and
# pool stay live every poll. --force-meta refetches the system on top of a
# normal poll.

# The library is sourced here too rather than leaning on 12-config.sh having
# sourced it first, so this file is meaningful on its own.
source "$ROOT/bin/truenas-lib.sh"

system_requests() { grep -c '/api/v2.0/system/info' "$STUB_CURL_LOG" || true; }
alert_requests()  { grep -c '/api/v2.0/alert/list'    "$STUB_CURL_LOG" || true; }
pool_requests()   { grep -c '/api/v2.0/pool'          "$STUB_CURL_LOG" || true; }
meta_file()       { jq -r "$1" "$XDG_STATE_HOME/omarchy/truenas/meta.json"; }

# The whole map every poll needs, with the system response variable so a case
# can change it between polls without losing the alert and pool entries.
meta_responses() {
  local rc=${1:-0} code=${2:-200} body=${3:-$ROOT/tests/fixtures/system-info.json}
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" "$rc" "$code" "$body"
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
poll
check "the second poll stays inside the window" 1 "$(system_requests)"
check "the system still reaches state from the cache" 25.04.2 "$(state '.system.version')"
check "and the alerts request still happened" 2 "$(alert_requests)"
check "so did the pool request" 2 "$(pool_requests)"
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
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "--force-meta spends exactly one more" 2 "$(system_requests)"
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
