# shellcheck shell=bash
# Task 4: the poll reads alerts, system and pools into state.json.

# alert/list and pool are read every poll; system/info is slow-moving and is
# cached after the first poll (Task 6, tests/cases/13-meta.sh). Every case here
# starts from an empty state dir, so the first poll still fetches all three. The
# other endpoints are canned here rather than repeated in each case.
all_healthy() {
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
  respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
  respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
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
check "the uptime is the real number" 3629000 "$(state '.system.uptimeSeconds')"
check "so are the cores" 16 "$(state '.system.cores')"
check "and the memory" 68719476736 "$(state '.system.physmem')"
check "connection carries the version" 25.04.2 "$(state '.connection.version')"
check "the dialect is named" rest-v2.0 "$(state '.connection.dialect')"
check "a healthy scan is FINISHED" FINISHED "$(state '.pools[] | select(.name=="storage") | .scan.state')"
check "five disks" 5 "$(state '.disks | length')"
check "rows sorted by name" nvme0n1 "$(state '.disks[0].name')"
check "pool mapping" boot-pool "$(state '.disks[] | select(.name=="sda") | .pool')"
check "temperature" 38 "$(state '.disks[] | select(.name=="sda") | .tempC')"
check "critical" 60 "$(state '.disks[] | select(.name=="sda") | .tempCriticalC')"
check "state ok" ok "$(state '.disks[] | select(.name=="sda") | .tempState')"
check "the model is carried" SATA_HDD_500G "$(state '.disks[] | select(.name=="sda") | .model')"
check "the size is a number" 500107862016 "$(state '.disks[] | select(.name=="sda") | .size')"
check "eight services" 8 "$(state '.services | length')"
check "services sorted by name" "cifs,ftp,iscsitarget,nfs,nvmet,snmp,ssh,ups" \
  "$(state '.services | map(.service) | join(",")')"
check "an enabled service is true" true "$(state '.services[] | select(.service=="cifs") | .enable')"
check "a disabled service is false" false "$(state '.services[] | select(.service=="ftp") | .enable')"
check "the service state is the wire string" RUNNING \
  "$(state '.services[] | select(.service=="ssh") | .state')"
check "five apps" 5 "$(state '.apps | length')"
check "apps sorted by name" "appa,appb,appc,appd,appe" \
  "$(state '.apps | map(.name) | join(",")')"
check "an app title comes from metadata" appc \
  "$(state '.apps[] | select(.name=="appc") | .title')"
check "a missing title falls back to the name" appa \
  "$(state '.apps[] | select(.name=="appa") | .title')"
check "a missing state is the empty string, not RUNNING" "" \
  "$(state '.apps[] | select(.name=="appd") | .state')"
check "a missing human_version falls back to version" 10.9.0 \
  "$(state '.apps[] | select(.name=="appd") | .version')"
check "a missing container count is null, not 0" null \
  "$(state '.apps[] | select(.name=="appa") | .containers')"
check "a real container count is a number" 2 \
  "$(state '.apps[] | select(.name=="appb") | .containers')"
check "the Web UI portal is chosen" "Web UI" \
  "$(state '.apps[] | select(.name=="appc") | .webui.label')"
check "with its url" "http://nas.example:30142/" \
  "$(state '.apps[] | select(.name=="appc") | .webui.url')"
check "a portal with no Web UI uses the first sorted key" Admin \
  "$(state '.apps[] | select(.name=="appe") | .webui.label')"
check "an empty portal map is null" null \
  "$(state '.apps[] | select(.name=="appa") | .webui')"
check "the upgrade flag is a boolean" true \
  "$(state '.apps[] | select(.name=="appb") | .upgradeAvailable')"
check "the details request is a POST" 2 "$(grep -o 'POST' "$STUB_METHOD_LOG" | wc -l)"
check "with the USED type" 1 "$(grep -c '"type":"USED"' "$STUB_PAYLOAD_LOG" || true)"
check "and temperatures asked per disk, with thresholds" 1 \
  "$(grep -c '"name":\["nvme0n1","sda","sdb","sdc","sdd"\],"include_thresholds":true' "$STUB_PAYLOAD_LOG" || true)"
check "no warnings on a clean poll" 0 "$(state '.warnings | length')"
teardown

test_case "disk rows are sorted by name even when the wire order is reversed"
setup; single_instance_config
jq -c 'reverse' "$ROOT/tests/fixtures/disks.json" >"$WORK/disks-reversed.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$WORK/disks-reversed.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
poll
check "the wire order is not the state order" "nvme0n1,sda,sdb,sdc,sdd" \
  "$(state '.disks | map(.name) | join(",")')"
teardown

test_case "a failed disk details call leaves disks empty and skips temperatures"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "disks are empty, not fabricated rows" "[]" "$(state '.disks')"
check "no disk carries a fabricated 0" 0 \
  "$(state '[.disks[]? | select(.tempC == 0)] | length')"
check "a warning names the disk section" disk \
  "$(state '.warnings[] | select(.section=="disk") | .section')"
check "the temperatures request is skipped" 0 \
  "$(grep -c '/api/v2.0/disk/temperatures' "$STUB_CURL_LOG" || true)"
check "and no diskTemp warning claims an answer" 0 \
  "$(state '[.warnings[] | select(.section=="diskTemp")] | length')"
teardown

test_case "a 200 with an object disk body is not a disk list"
setup; single_instance_config
printf '{}\n' >"$WORK/disks-wrong.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$WORK/disks-wrong.json"
poll
check "no rows are read from an object" "[]" "$(state '.disks')"
check "a warning names the disk section" disk \
  "$(state '.warnings[] | select(.section=="disk") | .section')"
teardown

test_case "a 200 with an array temperatures body is not a temperature map"
setup; single_instance_config
printf '[]\n' >"$WORK/temps-wrong.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$WORK/temps-wrong.json"
poll
check "the disk rows survive" 5 "$(state '.disks | length')"
check "every state is unknown" 0 \
  "$(state '[.disks[] | select(.tempState != "unknown")] | length')"
check "a warning names the diskTemp section" diskTemp \
  "$(state '.warnings[] | select(.section=="diskTemp") | .section')"
teardown

test_case "a failed temperatures call is unknown, never a zero"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "the disk rows survive" 5 "$(state '.disks | length')"
check "every temperature is null" 0 \
  "$(state '[.disks[] | select(.tempC != null)] | length')"
check "every threshold is null too" 0 \
  "$(state '[.disks[] | select(.tempCriticalC != null)] | length')"
check "every state is unknown" 0 \
  "$(state '[.disks[] | select(.tempState != "unknown")] | length')"
check "no temperature zero is invented" 0 \
  "$(state '[.disks[] | select(.tempC == 0)] | length')"
check "a warning names the diskTemp section" diskTemp \
  "$(state '.warnings[] | select(.section=="diskTemp") | .section')"
teardown

test_case "a hot disk is critical and a warm one is warning"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "sda is critical" critical "$(state '.disks[] | select(.name=="sda") | .tempState')"
check "sdc is in the warning band" warning "$(state '.disks[] | select(.name=="sdc") | .tempState')"
check "sdb is still ok" ok "$(state '.disks[] | select(.name=="sdb") | .tempState')"
teardown

test_case "a bare temperature without a threshold is unknown, not ok"
setup; single_instance_config
printf '{ "sda": 38.0 }\n' >"$WORK/temps-bare.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$WORK/temps-bare.json"
poll
check "the bare temperature is read" 38 \
  "$(state '.disks[] | select(.name=="sda") | .tempC')"
check "the missing threshold is null" null \
  "$(state '.disks[] | select(.name=="sda") | .tempCriticalC')"
check "so the state is unknown" unknown \
  "$(state '.disks[] | select(.name=="sda") | .tempState')"
teardown

test_case "the temperature bands are pinned at the threshold and ten below"
setup; single_instance_config
printf '{ "sda": [60.0, 60.0], "sdb": [50.0, 60.0] }\n' >"$WORK/temps-bands.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$WORK/temps-bands.json"
poll
check "at the critical threshold is critical" critical \
  "$(state '.disks[] | select(.name=="sda") | .tempState')"
check "exactly ten below is warning" warning \
  "$(state '.disks[] | select(.name=="sdb") | .tempState')"
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

test_case "a system that omits a field is unknown, never zero"
setup; single_instance_config
jq -c 'del(.uptime_seconds, .cores, .physmem)' \
  "$ROOT/tests/fixtures/system-info.json" >"$WORK/system.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$WORK/system.json"
poll
check "the system is still present" 25.04.2 "$(state '.system.version')"
check "an absent uptime is null, not an up 0s" null "$(state '.system.uptimeSeconds')"
check "an absent core count is null, not 0" null "$(state '.system.cores')"
check "absent memory is null, not 0" null "$(state '.system.physmem')"
teardown

test_case "a numeric zero stays zero while a non-number is unknown"
setup; single_instance_config
jq -c '.uptime_seconds = 0 | .cores = "sixteen" | .physmem = null' \
  "$ROOT/tests/fixtures/system-info.json" >"$WORK/system.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$WORK/system.json"
poll
check "a real zero is not lost" 0 "$(state '.system.uptimeSeconds')"
check "a non-numeric core count is null" null "$(state '.system.cores')"
check "an explicit null memory is null" null "$(state '.system.physmem')"
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

test_case "a failed service call leaves services empty while pools render"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 500 "$ROOT/tests/fixtures/err-500.json"
respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
poll
check "services are empty, not fabricated rows" "[]" "$(state '.services')"
check "no service carries a fabricated 0" 0 \
  "$(state '[.services[]? | select(.id == 0)] | length')"
check "a warning names the service section" service \
  "$(state '.warnings[] | select(.section=="service") | .section')"
check "the pools still render" 2 "$(state '.pools | length')"
check "and the apps answered" 5 "$(state '.apps | length')"
teardown

test_case "a failed app call leaves apps empty while pools render"
setup; single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app"         0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "apps are empty, not fabricated rows" "[]" "$(state '.apps')"
check "a warning names the app section" app \
  "$(state '.warnings[] | select(.section=="app") | .section')"
check "the pools still render" 2 "$(state '.pools | length')"
check "and the services answered" 8 "$(state '.services | length')"
teardown

test_case "a 200 with a non-object list row fails the section, not fabricates a card"
setup; single_instance_config
printf '[{}, null]\n' >"$WORK/bad-list.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$WORK/bad-list.json"
respond_add "/api/v2.0/app"         0 200 "$WORK/bad-list.json"
poll
check "services are empty, not a nameless card" "[]" "$(state '.services')"
check "and a warning names the service section" service \
  "$(state '.warnings[] | select(.section=="service") | .section')"
check "apps are empty too" "[]" "$(state '.apps')"
check "and a warning names the app section" app \
  "$(state '.warnings[] | select(.section=="app") | .section')"
check "the pools still render" 2 "$(state '.pools | length')"
teardown

test_case "no instance at all is unconfigured, and still writes state"
setup
poll
check "not connected" false "$(state '.connection.ok')"
check "named as unconfigured" unconfigured "$(state '.connection.error')"
check "no pools" 0 "$(state '.pools | length')"
check "and no disks" 0 "$(state '.disks | length')"
check "the schema is still present" 1 "$(state '.schema')"
teardown

test_case "--force-meta is accepted and does not change the result"
setup; single_instance_config
all_healthy
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "connected" true "$(state '.connection.ok')"
check "seven requests on a cold poll" 7 "$(requests)"
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

test_case "a vdev missing an error field makes that total unknown, not smaller"
setup; single_instance_config
cat >"$WORK/pools.json" <<'JSON'
[ { "name": "storage", "status": "ONLINE", "healthy": true,
    "size": 1000, "allocated": 100, "free": 900,
    "topology": { "data": [
      { "name": "mirror-0", "type": "MIRROR",
        "stats": { "read_errors": 3, "write_errors": 0, "checksum_errors": 9 } },
      { "name": "mirror-1", "type": "MIRROR",
        "stats": { "write_errors": 1, "checksum_errors": 1 } } ] } } ]
JSON
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$WORK/pools.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "the un-reported read count is null, not a partial 3" null \
  "$(state '.pools[0].vdevErrors.read')"
check "the fully reported writes are summed" 1 "$(state '.pools[0].vdevErrors.write')"
check "so are the checksums" 10 "$(state '.pools[0].vdevErrors.checksum')"
teardown
