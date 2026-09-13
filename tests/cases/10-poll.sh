# shellcheck shell=bash
# Task 4: the poll reads alerts, system and pools into state.json.

# Every poll reads all three endpoints. Most cases vary one of them, so the
# other two are canned here rather than repeated in each case.
all_healthy() {
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
}

test_case "a healthy NAS reports the pools and a quiet count"
setup; single_instance_config
all_healthy
poll
check "connected" true "$(state '.connection.ok')"
check "two pools" 2 "$(state '.pools | length')"
check "no alerts" 0 "$(state '.counts.total')"
check "storage is used" 71 "$(state '.pools[] | select(.name=="storage") | .usedPct')"
check "boot-pool is used" 19 "$(state '.pools[] | select(.name=="boot-pool") | .usedPct')"
check "the version came from system.info" 25.04.2 "$(state '.system.version')"
check "and the hostname too" nas "$(state '.system.hostname')"
check "connection carries the version" 25.04.2 "$(state '.connection.version')"
check "the dialect is named" rest-v2.0 "$(state '.connection.dialect')"
check "a healthy scan is FINISHED" FINISHED "$(state '.pools[] | select(.name=="storage") | .scan.state')"
check "no warnings on a clean poll" 0 "$(state '.warnings | length')"
teardown

test_case "an unreachable NAS is unknown, not zero"
setup; single_instance_config
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "not connected" false "$(state '.connection.ok')"
check "no count is invented" 0 "$(state '.counts.total')"
check "and the reason is named" unreachable "$(state '.connection.error')"
check "the pool list is empty rather than wrong" 0 "$(state '.pools | length')"
teardown

test_case "a 401 says the key was rejected"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 401 "$ROOT/tests/fixtures/err-401.json"
poll
check "named as unauthenticated" unauthenticated "$(state '.connection.error')"
check "no alerts are invented" 0 "$(state '.counts.total')"
teardown

test_case "a 500 is a server error, not a healthy empty answer"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "named as server_error" server_error "$(state '.connection.error')"
check "and its message is carried" "internal server error" "$(state '.connection.message')"
check "still no invented count" 0 "$(state '.counts.total')"
teardown

test_case "a 200 with a non-array alert body is not a quiet NAS"
setup; single_instance_config
printf '{}\n' >"$WORK/alerts.json"
respond     "/api/v2.0/alert/list"  0 200 "$WORK/alerts.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "not connected, the alert body was unusable" false "$(state '.connection.ok')"
check "named as not_json" not_json "$(state '.connection.error')"
check "a warning names the alert section" alert \
  "$(state '.warnings[] | select(.section=="alert") | .section')"
check "no counts are invented" 0 "$(state '.counts.total')"
teardown

test_case "a 200 with an empty system object is not a system"
setup; single_instance_config
printf '{}\n' >"$WORK/system.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$WORK/system.json"
poll
check "connected, the other sections answered" true "$(state '.connection.ok')"
check "system is null, not a row of fabricated zeroes" null "$(state '.system')"
check "a warning names the system section" system \
  "$(state '.warnings[] | select(.section=="system") | .section')"
check "counts are still present" 0 "$(state '.counts.total')"
check "pools are still present" 2 "$(state '.pools | length')"
teardown

test_case "a 200 with an object pool body is not a pool list"
setup; single_instance_config
printf '{}\n' >"$WORK/pools.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$WORK/pools.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "pools are empty rather than a junk row" 0 "$(state '.pools | length')"
check "a warning names the pool section" pool \
  "$(state '.warnings[] | select(.section=="pool") | .section')"
check "counts are still present" 0 "$(state '.counts.total')"
check "the system is still present" 25.04.2 "$(state '.system.version')"
teardown

test_case "a DEGRADED pool normalizes and keeps its scrub"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-degraded.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "not healthy" false "$(state '.pools[0].healthy')"
check "status carried" DEGRADED "$(state '.pools[0].status')"
check "scan state" FINISHED "$(state '.pools[0].scan.state')"
check "scan errors" 12 "$(state '.pools[0].scan.errors')"
check "scan start is an ISO string, never an object" string \
  "$(state '.pools[0].scan.startTime | type')"
check "vdev errors are summed" 12 \
  "$(state '.pools[0].vdevErrors.read + .pools[0].vdevErrors.checksum')"
teardown

test_case "alert levels bucket and dismissed alerts leave the counts"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-mixed.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "critical" 1 "$(state '.counts.critical')"
check "warning" 1 "$(state '.counts.warning')"
check "info" 1 "$(state '.counts.info')"
check "notice" 0 "$(state '.counts.notice')"
check "total excludes the dismissed one" 3 "$(state '.counts.total')"
check "dismissed is counted apart" 1 "$(state '.counts.dismissed')"
check "every row is still listed, flagged" 4 "$(state '.alerts | length')"
check "the datetime is an ISO string" string \
  "$(state '.alerts[] | select(.level=="critical") | .datetime | type')"
check "formatted wins when both text and formatted exist" \
  "Pool storage state is DEGRADED" \
  "$(state '.alerts[] | select(.level=="critical") | .text')"
teardown

test_case "an unknown level falls to notice, ALERT to critical"
setup; single_instance_config
cat >"$WORK/alerts.json" <<'JSON'
[ { "uuid": "u1", "level": "EMERGENCY", "formatted": "emergency", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "u2", "level": "ALERT", "formatted": "alert", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" },
  { "uuid": "u3", "level": "weird", "formatted": "weird", "dismissed": false, "dismissable": true, "datetime": "2026-08-21T14:28:00Z" } ]
JSON
respond     "/api/v2.0/alert/list"  0 200 "$WORK/alerts.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "two criticals" 2 "$(state '.counts.critical')"
check "the unknown one is a notice" 1 "$(state '.counts.notice')"
teardown

test_case "a number written as a string is still a number"
setup; single_instance_config
cat >"$WORK/pools.json" <<'JSON'
[ { "name": "storage", "status": "ONLINE", "healthy": true,
    "size": "4000", "allocated": "1000", "free": "3000", "fragmentation": "5",
    "scan": null } ]
JSON
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$WORK/pools.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "size coerced" 4000 "$(state '.pools[0].size')"
check "and compared as a number" 25 "$(state '.pools[0].usedPct')"
check "no scan is null, not a fabricated FINISHED" null "$(state '.pools[0].scan')"
teardown

test_case "a failed pool call leaves pools empty, keeps the alerts"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-critical.json"
respond_add "/api/v2.0/pool"        7 0 /dev/null
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "the alerts still count" 1 "$(state '.counts.critical')"
check "the pools are empty rather than wrong" 0 "$(state '.pools | length')"
check "a warning names the pool section" pool \
  "$(state '.warnings[] | select(.section=="pool") | .section')"
check "the alert answered, so the connection is up" true "$(state '.connection.ok')"
teardown

test_case "a failed system call is null, not a fabricated zero"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-critical.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 7 0 /dev/null
poll
check "the system is null, not an object of zeroes" null "$(state '.system')"
check "a warning names the system section" system \
  "$(state '.warnings[] | select(.section=="system") | .section')"
check "the alerts answered, so the connection is up" true "$(state '.connection.ok')"
check "no version is claimed" null "$(state '.connection.version')"
check "the alerts still count" 1 "$(state '.counts.critical')"
check "the pools are still present" 2 "$(state '.pools | length')"
teardown

test_case "no instance at all is unconfigured, and still writes state"
setup
poll
check "not connected" false "$(state '.connection.ok')"
check "named as unconfigured" unconfigured "$(state '.connection.error')"
check "no pools" 0 "$(state '.pools | length')"
check "the schema is still present" 1 "$(state '.schema')"
teardown

test_case "--force-meta is accepted and does not change the result"
setup; single_instance_config
all_healthy
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "connected" true "$(state '.connection.ok')"
check "one request per endpoint" 3 "$(requests)"
teardown

test_case "failures accumulate, hold lastOkAt, and reset on recovery"
setup; single_instance_config
all_healthy
poll
last_ok=$(state '.connection.lastOkAt')
check "a first success is clean" 0 "$(state '.connection.consecutiveFailures')"
check "and records when it was" 1 "$(printf '%s' "$last_ok" | grep -c '^[0-9]\{4\}-')"
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "one failure" 1 "$(state '.connection.consecutiveFailures')"
check "lastOkAt survives it" "$last_ok" "$(state '.connection.lastOkAt')"
poll
check "two failures" 2 "$(state '.connection.consecutiveFailures')"
all_healthy
poll
check "recovery resets the counter" 0 "$(state '.connection.consecutiveFailures')"
check "and writes a lastOkAt again" 1 \
  "$(state '.connection.lastOkAt' | grep -c '^[0-9]')"
teardown

test_case "a pool with no size reports no percentage, never zero"
setup; single_instance_config
cat >"$WORK/pools.json" <<'JSON'
[ { "name": "storage", "status": "ONLINE", "healthy": true,
    "size": null, "allocated": 1000, "free": null, "scan": null } ]
JSON
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$WORK/pools.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "no size" null "$(state '.pools[0].size')"
check "no percentage invented" null "$(state '.pools[0].usedPct')"
check "no vdev errors invented" null "$(state '.pools[0].vdevErrors')"
teardown
