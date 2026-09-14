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
# The trailing space pins the exact pool route: /api/v2.0/pool is a substring
# of /api/v2.0/pool/scrub and /api/v2.0/pool/snapshottask.
pool_requests()      { grep -c '/api/v2.0/pool '             "$STUB_CURL_LOG" || true; }
disk_requests()      { grep -c '/api/v2.0/disk/details'      "$STUB_CURL_LOG" || true; }
disk_temp_requests() { grep -c '/api/v2.0/disk/temperatures' "$STUB_CURL_LOG" || true; }
service_requests()   { grep -c '/api/v2.0/service'           "$STUB_CURL_LOG" || true; }
app_requests()       { grep -c '/api/v2.0/app'               "$STUB_CURL_LOG" || true; }
replication_requests() { grep -c '/api/v2.0/replication '    "$STUB_CURL_LOG" || true; }
cloudsync_requests()   { grep -c '/api/v2.0/cloudsync '      "$STUB_CURL_LOG" || true; }
snapshot_requests()    { grep -c '/api/v2.0/pool/snapshottask' "$STUB_CURL_LOG" || true; }
scrub_requests()       { grep -c '/api/v2.0/pool/scrub'      "$STUB_CURL_LOG" || true; }
smb_requests()         { grep -c '/api/v2.0/sharing/smb'     "$STUB_CURL_LOG" || true; }
nfs_requests()         { grep -c '/api/v2.0/sharing/nfs'     "$STUB_CURL_LOG" || true; }
iscsi_requests()       { grep -c '/api/v2.0/iscsi/target'    "$STUB_CURL_LOG" || true; }
network_requests()     { grep -c '/api/v2.0/interface'       "$STUB_CURL_LOG" || true; }
meta_file()          { jq -r "$1" "$XDG_STATE_HOME/omarchy/truenas/meta.json"; }

# The whole map every poll needs, with the system response variable so a case
# can change it between polls without losing the alert, pool, disk, service and
# app entries.
meta_responses() {
  local rc=${1:-0} code=${2:-200} body=${3:-$ROOT/tests/fixtures/system-info.json}
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
  respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" "$rc" "$code" "$body"
  respond_add "/api/v2.0/disk/details"      0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
  respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
  respond_add "/api/v2.0/replication" 0 200 "$ROOT/tests/fixtures/replication.json"
  respond_add "/api/v2.0/cloudsync"   0 200 "$ROOT/tests/fixtures/cloudsync.json"
  respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
  respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
  respond_add "/api/v2.0/iscsi/target" 0 200 "$ROOT/tests/fixtures/iscsi-target.json"
  respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
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
check "the cache keeps the wire key, not a normalized row" boot-pool \
  "$(meta_file '.disks.rows[] | select(.name=="sda") | .imported_zpool')"
check "the raw temperatures are cached" 5 "$(meta_file '.diskTemps.map | length')"
check "and the wire pair, not the normalized row" true \
  "$(meta_file '.diskTemps.map.sda == [38,60]')"
check "with an ISO fetch time of their own" true \
  "$(meta_file '.diskTemps.fetchedAt | test("^[0-9]{4}-")')"
check "the cold poll fetched the details once" 1 "$(disk_requests)"
check "and the temperatures once" 1 "$(disk_temp_requests)"
check "and the services once" 1 "$(service_requests)"
check "and the apps once" 1 "$(app_requests)"
check "and the replication tasks once" 1 "$(replication_requests)"
check "and the cloud sync tasks once" 1 "$(cloudsync_requests)"
check "and the snapshot tasks once" 1 "$(snapshot_requests)"
check "and the scrub tasks once" 1 "$(scrub_requests)"
check "and the SMB shares once" 1 "$(smb_requests)"
check "and the NFS exports once" 1 "$(nfs_requests)"
check "and the iSCSI targets once" 1 "$(iscsi_requests)"
check "and the interfaces once" 1 "$(network_requests)"
poll
check "the second poll stays inside the window" 1 "$(system_requests)"
check "the system still reaches state from the cache" 25.04.2 "$(state '.system.version')"
check "and the alerts request still happened" 2 "$(alert_requests)"
check "so did the pool request" 2 "$(pool_requests)"
check "the cached poll makes no disk request" 1 "$(disk_requests)"
check "nor a temperatures request" 1 "$(disk_temp_requests)"
check "nor a service request" 1 "$(service_requests)"
check "nor an app request" 1 "$(app_requests)"
check "nor a replication request" 1 "$(replication_requests)"
check "nor a cloud sync request" 1 "$(cloudsync_requests)"
check "nor a snapshot task request" 1 "$(snapshot_requests)"
check "nor a scrub request" 1 "$(scrub_requests)"
check "nor a share request" 1 "$(smb_requests)"
check "nor an NFS request" 1 "$(nfs_requests)"
check "nor an iSCSI request" 1 "$(iscsi_requests)"
check "nor an interface request" 1 "$(network_requests)"
check "a warm poll is two fast requests" 17 "$(requests)"
check "the disk rows still reach state from the cache" 5 "$(state '.disks | length')"
check "with their temperature normalized" 38 \
  "$(state '.disks[] | select(.name=="sda") | .tempC')"
check "the cached service rows still reach state" 8 "$(state '.services | length')"
check "so do the cached apps" 5 "$(state '.apps | length')"
check "so do the cached replication tasks" 2 "$(state '.replication | length')"
check "and the cached snapshot tasks" 3 "$(state '.snapshotTasks | length')"
check "and the cached scrub tasks" 2 "$(state '.scrubs | length')"
check "and the cached SMB shares" 3 "$(state '.shares.smb | length')"
check "and the cached NFS exports" 1 "$(state '.shares.nfs | length')"
check "and the cached iSCSI targets" 2 "$(state '.shares.iscsi | length')"
check "and the cached interfaces" 1 "$(state '.network | length')"
teardown

test_case "a cold and a warm poll render the same services and apps"
setup; single_instance_config
meta_responses
poll
cold_services=$(jq -c '.services' "$STATE")
cold_apps=$(jq -c '.apps' "$STATE")
poll
check "the warm service rows match the cold ones" "$cold_services" \
  "$(jq -c '.services' "$STATE")"
check "the warm app rows match the cold ones" "$cold_apps" \
  "$(jq -c '.apps' "$STATE")"
check "so the fallback version survives the cache" 10.9.0 \
  "$(state '.apps[] | select(.name=="appd") | .version')"
check "and the absent state stays empty through the cache" "" \
  "$(state '.apps[] | select(.name=="appd") | .state')"
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
check "and one more service fetch" 2 "$(service_requests)"
check "and one more app fetch" 2 "$(app_requests)"
check "and one more replication fetch" 2 "$(replication_requests)"
check "and one more cloud sync fetch" 2 "$(cloudsync_requests)"
check "and one more snapshot task fetch" 2 "$(snapshot_requests)"
check "and one more scrub fetch" 2 "$(scrub_requests)"
check "and one more SMB fetch" 2 "$(smb_requests)"
check "and one more NFS fetch" 2 "$(nfs_requests)"
check "and one more iSCSI fetch" 2 "$(iscsi_requests)"
check "and one more interface fetch" 2 "$(network_requests)"
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

test_case "a failed temperatures fetch leaves the previous meta byte-for-byte intact"
setup; single_instance_config
meta_responses
poll
before=$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 500 "$ROOT/tests/fixtures/err-500.json"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "the forced poll asked for the temperatures" 2 "$(disk_temp_requests)"
check "a warning names the diskTemp section" diskTemp \
  "$(state '.warnings[] | select(.section=="diskTemp") | .section')"
check "the meta file is byte-for-byte the previous one" "$before" \
  "$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")"
teardown

test_case "a failed service fetch leaves the previous meta byte-for-byte intact"
setup; single_instance_config
meta_responses
poll
before=$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 500 "$ROOT/tests/fixtures/err-500.json"
respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "the forced poll asked for the services" 2 "$(service_requests)"
check "a warning names the service section" service \
  "$(state '.warnings[] | select(.section=="service") | .section')"
check "the meta file is byte-for-byte the previous one" "$before" \
  "$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")"
teardown

test_case "a failed app fetch leaves the previous meta byte-for-byte intact"
setup; single_instance_config
meta_responses
poll
before=$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app"         0 500 "$ROOT/tests/fixtures/err-500.json"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "the forced poll asked for the apps" 2 "$(app_requests)"
check "a warning names the app section" app \
  "$(state '.warnings[] | select(.section=="app") | .section')"
check "the meta file is byte-for-byte the previous one" "$before" \
  "$(cat "$XDG_STATE_HOME/omarchy/truenas/meta.json")"
teardown

test_case "a meta.json missing any slow-section key self-heals on the next poll"
setup; single_instance_config
meta_responses
poll
# A cache from before this milestone: a usable system section, a fresh fetch
# time, and one slow-section key at a time missing. The fresh age must not save
# it; each presence predicate has to stand on its own.
for missing in disks diskTemps services apps replication cloudSync snapshotTasks scrubs smb nfs iscsi network; do
  jq -c --arg k "$missing" 'del(.[$k])' \
    "$XDG_STATE_HOME/omarchy/truenas/meta.json" >"$WORK/meta-m1.json"
  cp "$WORK/meta-m1.json" "$XDG_STATE_HOME/omarchy/truenas/meta.json"
  : >"$STUB_CURL_LOG"
  poll
  check "a cache missing $missing is stale and refetches all fifteen" 15 "$(requests)"
  check "and $missing is written again" true "$(meta_file "has(\"$missing\")")"
done
check "the disk rows are cached again" 5 "$(meta_file '.disks.rows | length')"
check "and the temperature map too" 5 "$(meta_file '.diskTemps.map | length')"
check "and the service rows too" 8 "$(meta_file '.services.rows | length')"
check "and the app rows too" 5 "$(meta_file '.apps.rows | length')"
check "and the replication rows too" 2 "$(meta_file '.replication.rows | length')"
check "and the snapshot task rows too" 3 "$(meta_file '.snapshotTasks.rows | length')"
check "and the scrub rows too" 2 "$(meta_file '.scrubs.rows | length')"
check "and the SMB rows too" 3 "$(meta_file '.smb.rows | length')"
check "and the NFS rows too" 1 "$(meta_file '.nfs.rows | length')"
check "and the iSCSI rows too" 2 "$(meta_file '.iscsi.rows | length')"
check "and the network rows too" 1 "$(meta_file '.network.rows | length')"
check "the old system data was not lost" 25.04.2 "$(state '.system.version')"
teardown

test_case "the meta cache keeps the consumed disk fields and drops identifiers"
setup; single_instance_config
jq -c '[ .[] | . + { serial: "FAKE-SERIAL", identifier: "fake-id", lunid: "fake-lun" } ]' \
  "$ROOT/tests/fixtures/disks.json" >"$WORK/disks-with-ids.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$WORK/disks-with-ids.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
respond_add "/api/v2.0/replication" 0 200 "$ROOT/tests/fixtures/replication.json"
respond_add "/api/v2.0/cloudsync"   0 200 "$ROOT/tests/fixtures/cloudsync.json"
respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
respond_add "/api/v2.0/iscsi/target" 0 200 "$ROOT/tests/fixtures/iscsi-target.json"
respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
poll
check "no cached row carries a serial, identifier or lunid" 0 \
  "$(meta_file '[.disks.rows[] | select(has("serial") or has("identifier") or has("lunid"))] | length')"
check "the consumed fields survive the filter" boot-pool \
  "$(meta_file '.disks.rows[] | select(.name=="sda") | .imported_zpool')"
check "the filtered rows still normalize" 5 "$(state '.disks | length')"
check "with the temperature from the raw map" 38 \
  "$(state '.disks[] | select(.name=="sda") | .tempC')"
teardown

test_case "the meta cache keeps the consumed app fields and drops notes and image ids"
setup; single_instance_config
meta_responses
poll
check "the app rows are cached" 5 "$(meta_file '.apps.rows | length')"
check "no cached app row carries notes" 0 \
  "$(meta_file '[.apps.rows[] | select(has("notes"))] | length')"
check "no cached app row carries an image identifier" 0 \
  "$(meta_file '[.apps.rows[] | select(has("image") or has("image_id"))] | length')"
check "nor a workload detail beyond the container count" 0 \
  "$(meta_file '[.apps.rows[] | select(.active_workloads | has("container_details") or has("used_ports"))] | length')"
check "the reduced workload count survives" 1 \
  "$(meta_file '.apps.rows[] | select(.name=="appc") | .active_workloads.containers')"
check "the consumed metadata survives the filter" appc \
  "$(meta_file '.apps.rows[] | select(.name=="appc") | .metadata.title')"
check "the cached wire key is kept, not a normalized row" 16.0.4-rootless_1.2.39 \
  "$(meta_file '.apps.rows[] | select(.name=="appc") | .human_version')"
check "the service rows are cached" 8 "$(meta_file '.services.rows | length')"
check "no cached service row carries pids" 0 \
  "$(meta_file '[.services.rows[] | select(has("pids"))] | length')"
check "the service wire key is kept" RUNNING \
  "$(meta_file '.services.rows[] | select(.service=="cifs") | .state')"
check "and the filtered rows still normalize" 8 "$(state '.services | length')"
teardown

test_case "a non-object metadata does not stall the meta cache"
setup; single_instance_config
jq -c '[ .[] | if .name == "appc" then .metadata = "junk" else . end ]' \
  "$ROOT/tests/fixtures/apps.json" >"$WORK/apps-junk-meta.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app"         0 200 "$WORK/apps-junk-meta.json"
respond_add "/api/v2.0/replication" 0 200 "$ROOT/tests/fixtures/replication.json"
respond_add "/api/v2.0/cloudsync"   0 200 "$ROOT/tests/fixtures/cloudsync.json"
respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
respond_add "/api/v2.0/iscsi/target" 0 200 "$ROOT/tests/fixtures/iscsi-target.json"
respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
poll
check "the meta cache advanced anyway" true "$(meta_file 'has("apps")')"
check "the junk metadata is cached as an empty object" null \
  "$(meta_file '.apps.rows[] | select(.name=="appc") | .metadata.title')"
check "and the title falls back to the name" appc \
  "$(state '.apps[] | select(.name=="appc") | .title')"
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

test_case "the meta cache keeps the consumed protection fields and drops secrets"
setup; single_instance_config
jq -nc '[ { id: 3, description: "clouda", path: "/mnt/storage",
  enabled: true, direction: "PUSH", transfer_mode: "SYNC",
  schedule: { minute: "0", hour: "2", dom: "*", month: "*", dow: "*" },
  credentials: { id: 1, name: "clouda", provider: { secret_access_key: "FAKE-SECRET" } },
  encryption_password: "FAKE-PW", encryption_salt: "FAKE-SALT",
  pre_script: "echo FAKE-PRE", post_script: "echo FAKE-POST",
  job: { id: 5, state: "SUCCESS", error: null,
         logs_excerpt: "FAKE-LOGS", time_finished: { "$date": 1789358400000 } } } ]' \
  >"$WORK/cloudsync-row.json"
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
respond_add "/api/v2.0/pool/scrub" 0 200 "$ROOT/tests/fixtures/scrubs.json"
respond_add "/api/v2.0/pool" 0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service" 0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app" 0 200 "$ROOT/tests/fixtures/apps.json"
respond_add "/api/v2.0/replication" 0 200 "$ROOT/tests/fixtures/replication.json"
respond_add "/api/v2.0/cloudsync" 0 200 "$WORK/cloudsync-row.json"
respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
respond_add "/api/v2.0/iscsi/target" 0 200 "$ROOT/tests/fixtures/iscsi-target.json"
respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
poll
check "the cloud sync row is cached" 1 "$(meta_file '.cloudSync.rows | length')"
check "and it normalizes from the cache" clouda "$(state '.cloudSync[0].name')"
check "with its job state" SUCCESS "$(state '.cloudSync[0].job.state')"
check "no cloud sync row carries credentials or a password" 0 \
  "$(meta_file '[.cloudSync.rows[] | select(has("credentials") or has("encryption_password") or has("encryption_salt") or has("pre_script") or has("post_script"))] | length')"
check "nor a job log excerpt" 0 \
  "$(meta_file '[.cloudSync.rows[] | select(.job | type == "object" and has("logs_excerpt"))] | length')"
check "no replication row carries ssh_credentials or an encryption key" 0 \
  "$(meta_file '[.replication.rows[] | select(has("ssh_credentials") or has("encryption_key"))] | length')"
check "nor a job log excerpt or exception" 0 \
  "$(meta_file '[.replication.rows[] | select(.job | type == "object" and (has("logs_excerpt") or has("exception")))] | length')"
check "no secret reaches the meta file" 0 \
  "$(grep -c -e 'FAKE-SECRET' -e 'FAKE-PW' -e 'FAKE-SALT' -e 'SECRET-LOGS' -e 'SECRET-STACK' "$XDG_STATE_HOME/omarchy/truenas/meta.json" || true)"
check "nor the state file" 0 \
  "$(grep -c -e 'FAKE-SECRET' -e 'SECRET-LOGS' "$STATE" || true)"
teardown

test_case "the meta cache keeps the consumed share fields and drops the blobs"
setup; single_instance_config
# Poison every share and network row with the fields the cache must not keep,
# under a sentinel no other text contains, so a stray write is unmistakable.
jq -c '[ .[] | .audit = { enable: true, watch_list: ["FAKE-AUDIT"], ignore_list: [] }
         | .options = { aapl_name_mangling: true, hostsallow: ["FAKE-OPT"],
                        hostsdeny: [] } ]' \
  "$ROOT/tests/fixtures/shares-smb.json" >"$WORK/smb-poison.json"
jq -c '[ .[] | .hosts = ["FAKE-HOST"]
         | .networks = ["FAKE-NET"] | .security = ["FAKE-SEC"] ]' \
  "$ROOT/tests/fixtures/shares-nfs.json" >"$WORK/nfs-poison.json"
jq -c '[ .[] | .groups = [{ portal: 1, auth: 9 }]
         | .iscsi_parameters = { QueuedCommands: 32 } ]' \
  "$ROOT/tests/fixtures/iscsi-target.json" >"$WORK/iscsi-poison.json"
jq -c '[ .[] | .state.link_address = "FAKE-MAC-1"
         | .state.permanent_link_address = "FAKE-MAC-2"
         | .state.hardware_link_address = "FAKE-MAC-3" ]' \
  "$ROOT/tests/fixtures/interfaces.json" >"$WORK/network-poison.json"
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
respond_add "/api/v2.0/pool/scrub" 0 200 "$ROOT/tests/fixtures/scrubs.json"
respond_add "/api/v2.0/pool" 0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service" 0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app" 0 200 "$ROOT/tests/fixtures/apps.json"
respond_add "/api/v2.0/replication" 0 200 "$ROOT/tests/fixtures/replication.json"
respond_add "/api/v2.0/cloudsync" 0 200 "$ROOT/tests/fixtures/cloudsync.json"
respond_add "/api/v2.0/sharing/smb" 0 200 "$WORK/smb-poison.json"
respond_add "/api/v2.0/sharing/nfs" 0 200 "$WORK/nfs-poison.json"
respond_add "/api/v2.0/iscsi/target" 0 200 "$WORK/iscsi-poison.json"
respond_add "/api/v2.0/interface" 0 200 "$WORK/network-poison.json"
poll
check "the SMB rows are cached" 3 "$(meta_file '.smb.rows | length')"
check "no cached SMB row carries an audit or options blob" 0 \
  "$(meta_file '[.smb.rows[] | select(has("audit") or has("options"))] | length')"
check "the consumed SMB purpose survives" DEFAULT_SHARE \
  "$(meta_file '.smb.rows[] | select(.name=="default") | .purpose')"
check "the NFS rows are cached" 1 "$(meta_file '.nfs.rows | length')"
check "no cached NFS row carries hosts, networks or security" 0 \
  "$(meta_file '[.nfs.rows[] | select(has("hosts") or has("networks") or has("security"))] | length')"
check "the consumed NFS ro flag survives under its wire name" false \
  "$(meta_file '.nfs.rows[0].ro')"
check "the iSCSI rows are cached" 2 "$(meta_file '.iscsi.rows | length')"
check "no cached iSCSI row carries groups or iscsi_parameters" 0 \
  "$(meta_file '[.iscsi.rows[] | select(has("groups") or has("iscsi_parameters"))] | length')"
check "the consumed iSCSI alias survives" bulk \
  "$(meta_file '.iscsi.rows[] | select(.id==1) | .alias')"
check "the network row is cached" 1 "$(meta_file '.network.rows | length')"
check "no cached interface carries a MAC" 0 \
  "$(meta_file '[.network.rows[] | select(.state | type == "object" and (has("link_address") or has("permanent_link_address") or has("hardware_link_address")))] | length')"
check "the link state survives the cache" LINK_STATE_UP \
  "$(meta_file '.network.rows[0].state.link_state')"
check "and the negotiated media subtype" "1000Mb/s Twisted Pair" \
  "$(meta_file '.network.rows[0].state.active_media_subtype')"
check "the cached alias keeps its netmask" 24 \
  "$(meta_file '.network.rows[0].state.aliases[0].netmask')"
check "and drops the broadcast" false \
  "$(meta_file '.network.rows[0].state.aliases[0] | has("broadcast")')"
check "no poisoned field reaches the meta file" 0 \
  "$(grep -c -e 'FAKE-AUDIT' -e 'FAKE-OPT' -e 'FAKE-HOST' -e 'FAKE-NET' -e 'FAKE-SEC' -e 'FAKE-MAC' "$XDG_STATE_HOME/omarchy/truenas/meta.json" || true)"
check "nor the state file" 0 \
  "$(grep -c -e 'FAKE-AUDIT' -e 'FAKE-HOST' -e 'FAKE-MAC' "$STATE" || true)"
check "the filtered share rows still normalize" 3 "$(state '.shares.smb | length')"
check "and the filtered interface still normalizes" 1 "$(state '.network | length')"
teardown
