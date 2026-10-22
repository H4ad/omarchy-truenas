# shellcheck shell=bash
# Task 4: the poll reads alerts, system and pools into state.json.

# alert/list and pool are read every poll; system/info is slow-moving and is
# cached after the first poll (Task 6, tests/cases/13-meta.sh). Every case here
# starts from an empty state dir, so the first poll still fetches all three. The
# other endpoints are canned here rather than repeated in each case.
all_healthy() {
  local iscsi=${1:-"$ROOT/tests/fixtures/iscsi-target.json"}
  local replication=${2:-"$ROOT/tests/fixtures/replication.json"}
  respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  # The specific pool sub-routes come before /api/v2.0/pool: the stub matches on
  # a substring, so a scrub request would otherwise be served the pool list.
  respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
  respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
  respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
  respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
  respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
  respond_add "/api/v2.0/replication" 0 200 "$replication"
  respond_add "/api/v2.0/cloudsync"   0 200 "$ROOT/tests/fixtures/cloudsync.json"
  respond_add "/api/v2.0/sharing/smb" 0 200 "$ROOT/tests/fixtures/shares-smb.json"
  respond_add "/api/v2.0/sharing/nfs" 0 200 "$ROOT/tests/fixtures/shares-nfs.json"
  respond_add "/api/v2.0/iscsi/target" 0 200 "$iscsi"
  respond_add "/api/v2.0/interface"   0 200 "$ROOT/tests/fixtures/interfaces.json"
}

# The same map with one protection route failing. The failing route is written
# first so the substring match cannot serve it from a broader entry.
protection_route_fails() {
  local route=$1
  respond     "$route" 0 500 "$ROOT/tests/fixtures/err-500.json"
  respond_add "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
  respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
  respond_add "/api/v2.0/pool"              0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info"       0 200 "$ROOT/tests/fixtures/system-info.json"
  respond_add "/api/v2.0/disk/details"      0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  respond_add "/api/v2.0/service"           0 200 "$ROOT/tests/fixtures/services.json"
  respond_add "/api/v2.0/app"               0 200 "$ROOT/tests/fixtures/apps.json"
  respond_add "/api/v2.0/replication"       0 200 "$ROOT/tests/fixtures/replication.json"
  respond_add "/api/v2.0/cloudsync"         0 200 "$ROOT/tests/fixtures/cloudsync.json"
  respond_add "/api/v2.0/sharing/smb"       0 200 "$ROOT/tests/fixtures/shares-smb.json"
  respond_add "/api/v2.0/sharing/nfs"       0 200 "$ROOT/tests/fixtures/shares-nfs.json"
  respond_add "/api/v2.0/iscsi/target"      0 200 "$ROOT/tests/fixtures/iscsi-target.json"
  respond_add "/api/v2.0/interface"         0 200 "$ROOT/tests/fixtures/interfaces.json"
}

# The same map with one share or network route failing, so the isolation between
# the four new sections can be driven one at a time.
share_route_fails() {
  local route=$1
  respond     "$route" 0 500 "$ROOT/tests/fixtures/err-500.json"
  respond_add "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
  respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
  respond_add "/api/v2.0/pool/scrub"        0 200 "$ROOT/tests/fixtures/scrubs.json"
  respond_add "/api/v2.0/pool"              0 200 "$ROOT/tests/fixtures/pools-healthy.json"
  respond_add "/api/v2.0/system/info"       0 200 "$ROOT/tests/fixtures/system-info.json"
  respond_add "/api/v2.0/disk/details"      0 200 "$ROOT/tests/fixtures/disks.json"
  respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  respond_add "/api/v2.0/service"           0 200 "$ROOT/tests/fixtures/services.json"
  respond_add "/api/v2.0/app"               0 200 "$ROOT/tests/fixtures/apps.json"
  respond_add "/api/v2.0/replication"       0 200 "$ROOT/tests/fixtures/replication.json"
  respond_add "/api/v2.0/cloudsync"         0 200 "$ROOT/tests/fixtures/cloudsync.json"
  respond_add "/api/v2.0/sharing/smb"       0 200 "$ROOT/tests/fixtures/shares-smb.json"
  respond_add "/api/v2.0/sharing/nfs"       0 200 "$ROOT/tests/fixtures/shares-nfs.json"
  respond_add "/api/v2.0/iscsi/target"      0 200 "$ROOT/tests/fixtures/iscsi-target.json"
  respond_add "/api/v2.0/interface"         0 200 "$ROOT/tests/fixtures/interfaces.json"
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
check "two replication tasks" 2 "$(state '.replication | length')"
check "replication sorted by name" "backup-to-offsite,storage-to-backup" \
  "$(state '.replication | map(.name) | join(",")')"
check "the nested task state is an object, not a string" object \
  "$(state '.replication[] | select(.id==1) | .state | type')"
check "the state datetime is ISO, never an object" string \
  "$(state '.replication[] | select(.id==1) | .state.datetime | type')"
check "the last snapshot is carried" "storage/vm-root@auto-daily-2026-09-14_00-05" \
  "$(state '.replication[] | select(.id==1) | .state.lastSnapshot')"
check "a PENDING task has no last snapshot, never empty text" null \
  "$(state '.replication[] | select(.id==2) | .state.lastSnapshot')"
check "the job state is carried" SUCCESS \
  "$(state '.replication[] | select(.id==1) | .job.state')"
check "no replication secret reaches a row" 0 \
  "$(state '[.replication[] | select(has("ssh_credentials") or has("encryption_key"))] | length')"
check "an auto task has a null schedule" null \
  "$(state '.replication[] | select(.id==1) | .schedule')"
check "a scheduled task keeps its window" "03:00" \
  "$(state '.replication[] | select(.id==2) | .schedule.begin')"
check "cloud sync is empty, not fabricated" "[]" "$(state '.cloudSync')"
check "three snapshot tasks" 3 "$(state '.snapshotTasks | length')"
check "snapshot tasks sorted by dataset" "Backup,boot-pool,storage" \
  "$(state '.snapshotTasks | map(.dataset) | join(",")')"
check "the naming schema is carried" "auto-hourly-%Y-%m-%d_%H-%M" \
  "$(state '.snapshotTasks[] | select(.id==1) | .namingSchema')"
check "a pending snapshot task has no datetime" null \
  "$(state '.snapshotTasks[] | select(.id==6) | .state.datetime')"
check "the scrub rows are sorted by pool" "Backup,storage" \
  "$(state '.scrubs | map(.pool) | join(",")')"
check "the scrub row keeps the numeric pool id apart from the name" 1 \
  "$(state '.scrubs[] | select(.pool=="storage") | .poolId')"
check "the scrub row carries no run state" false \
  "$(state '.scrubs[] | select(.pool=="storage") | has("state")')"
check "the scrub threshold is a number" 35 "$(state '.scrubs[0].threshold')"
check "the details request is a POST" 2 "$(grep -o 'POST' "$STUB_METHOD_LOG" | wc -l)"
check "with the USED type" 1 "$(grep -c '"type":"USED"' "$STUB_PAYLOAD_LOG" || true)"
check "and temperatures asked per disk, with thresholds" 1 \
  "$(grep -c '"name":\["nvme0n1","sda","sdb","sdc","sdd"\],"include_thresholds":true' "$STUB_PAYLOAD_LOG" || true)"
check "three SMB shares" 3 "$(state '.shares.smb | length')"
check "SMB sorted by name" "backup,default,media" \
  "$(state '.shares.smb | map(.name) | join(",")')"
check "a disabled share is false" false \
  "$(state '.shares.smb[] | select(.name=="media") | .enabled')"
check "a read-only share is true" true \
  "$(state '.shares.smb[] | select(.name=="media") | .readonly')"
check "locked defaults false" false \
  "$(state '.shares.smb[] | select(.name=="default") | .locked')"
check "the purpose is carried" DEFAULT_SHARE \
  "$(state '.shares.smb[] | select(.name=="default") | .purpose')"
check "the comment is carried" backups \
  "$(state '.shares.smb[] | select(.name=="backup") | .comment')"
check "no SMB audit or options blob reaches a row" 0 \
  "$(state '[.shares.smb[] | select(has("audit") or has("options"))] | length')"
check "one NFS export" 1 "$(state '.shares.nfs | length')"
check "the NFS read-only flag is renamed" false "$(state '.shares.nfs[0].readonly')"
check "and the wire ro key is gone" false "$(state '.shares.nfs[0] | has("ro")')"
check "an NFS export carries no name" false "$(state '.shares.nfs[0] | has("name")')"
check "no NFS hosts, networks or security list reaches a row" 0 \
  "$(state '[.shares.nfs[] | select(has("hosts") or has("networks") or has("security"))] | length')"
check "two synthetic iSCSI targets" 2 "$(state '.shares.iscsi | length')"
check "iSCSI sorted by name" \
  "iqn.2005-10.org.freenas.ctl:target0,iqn.2005-10.org.freenas.ctl:target1" \
  "$(state '.shares.iscsi | map(.name) | join(",")')"
check "an iSCSI alias is carried" bulk "$(state '.shares.iscsi[0].alias')"
check "the iSCSI mode is carried" ISCSI "$(state '.shares.iscsi[0].mode')"
check "no iscsi groups or parameters reach a row" 0 \
  "$(state '[.shares.iscsi[] | select(has("groups") or has("iscsi_parameters"))] | length')"
check "one interface" 1 "$(state '.network | length')"
check "the link state is the raw enum" LINK_STATE_UP "$(state '.network[0].linkState')"
check "the media subtype is the negotiated speed" "1000Mb/s Twisted Pair" \
  "$(state '.network[0].mediaSubtype')"
check "the media type is carried" Ethernet "$(state '.network[0].mediaType')"
check "two runtime addresses" 2 "$(state '.network[0].addresses | length')"
check "the IPv4 address keeps its CIDR prefix" "192.0.2.10/24" \
  "$(state '.network[0].addresses[0] | "\(.address)/\(.netmask)"')"
check "the link-local IPv6 is kept" "2001:db8::10/64" \
  "$(state '.network[0].addresses[1] | "\(.address)/\(.netmask)"')"
check "no broadcast survives" false \
  "$(state '.network[0].addresses | any(has("broadcast"))')"
check "no MAC reaches an interface row" 0 \
  "$(state '[.network[] | select(has("link_address") or has("permanent_link_address") or has("hardware_link_address"))] | length')"
check "no warnings on a clean poll" 0 "$(state '.warnings | length')"
teardown

test_case "a scheduled task with an old run is overdue, a never-run one is not yet"
setup; single_instance_config
all_healthy
poll
check "the hourly snapshot with an old run is overdue" true \
  "$(state '.snapshotTasks[] | select(.id==1) | .overdue')"
check "its schedule bound is one hour" 3600 \
  "$(state '.snapshotTasks[] | select(.id==1) | .gapSeconds')"
check "the last run is an ISO string" string \
  "$(state '.snapshotTasks[] | select(.id==1) | .lastRunAt | type')"
check "the first sighting is recorded" string \
  "$(state '.snapshotTasks[] | select(.id==1) | .firstSeenAt | type')"
check "a never-run snapshot starts its grace, so it is not overdue" false \
  "$(state '.snapshotTasks[] | select(.id==6) | .overdue')"
check "a disabled task is not scheduled" false \
  "$(state '.snapshotTasks[] | select(.id==7) | .scheduled')"
check "a replication task with no schedule is not scheduled" false \
  "$(state '.replication[] | select(.id==1) | .scheduled')"
check "a manual-only replication task is not scheduled" false \
  "$(state '.replication[] | select(.id==2) | .scheduled')"
check "the weekly scrub with an old scan is overdue" true \
  "$(state '.scrubs[] | select(.pool=="storage") | .overdue')"
check "a scrub whose pool did not answer is not judged" false \
  "$(state '.scrubs[] | select(.pool=="Backup") | .lastRunKnown')"
check "and it is not overdue" false \
  "$(state '.scrubs[] | select(.pool=="Backup") | .overdue')"

# A never-run task becomes overdue only after its first-seen grace. Age the
# entry the first poll wrote, then poll again: the daily schedule's bound plus
# the grace has passed, so it must flip.
jq '(.overdue["snapshotTasks:6"].firstSeenAt) = "2020-01-01T00:00:00Z"' \
  "$(seen_file)" >"$WORK/seen-aged.json" && mv "$WORK/seen-aged.json" "$(seen_file)"
poll
check "after its grace the never-run task is overdue" true \
  "$(state '.snapshotTasks[] | select(.id==6) | .overdue')"
check "and seen records the transition" true \
  "$(seen '.overdue["snapshotTasks:6"].overdue')"
teardown

test_case "a replication task driven by a snapshot schedule is still judged"
setup; single_instance_config
jq -c 'map(if .id == 1 then
    .auto = true | .schedule = null
    | .periodic_snapshot_tasks = [{ schedule: {
        minute: "5", hour: "0", dom: "*", month: "*", dow: "*" } }]
  else . end)' "$ROOT/tests/fixtures/replication.json" >"$WORK/rep-linked.json"
all_healthy "" "$WORK/rep-linked.json"
poll
check "the trigger schedule is carried" 1 \
  "$(state '.replication[] | select(.id==1) | .periodicSnapshotSchedules | length')"
check "the task counts as scheduled without its own cron" true \
  "$(state '.replication[] | select(.id==1) | .scheduled')"
check "its bound is the trigger's daily gap" 86400 \
  "$(state '.replication[] | select(.id==1) | .gapSeconds')"
check "and an old run is overdue" true \
  "$(state '.replication[] | select(.id==1) | .overdue')"
teardown

test_case "the overdue derivation follows the schedule, not a fixed age"
setup
now=2026-10-20T00:00:00Z
now_epoch=$(date -u -d "$now" +%s)
ago() { date -u -d "@$((now_epoch - $1))" +%Y-%m-%dT%H:%M:%SZ; }
printf '{}\n' >"$WORK/seen-empty.json"
jq -n --arg daily_late "$(ago 111600)" --arg daily_early "$(ago 104400)" \
      --arg weekly_late "$(ago 691200)" --arg weekly_early "$(ago 604800)" \
      --arg monthly_early "$(ago 3456000)" --arg hourly_late "$(ago 28800)" \
      --arg minute_late "$(ago 25260)" '
  {
    pools: [
      { name: "storage", scan: { function: "SCRUB", state: "FINISHED",
                                 endTime: $weekly_late } },
      { name: "backup", scan: { function: "RESILVER", state: "FINISHED",
                                endTime: $weekly_late } }
    ],
    replication: [
      { id: 1, enabled: true, auto: true,
        schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "*" },
        state: null, job: { state: "RUNNING", timeFinished: null } }
    ],
    cloudSync: [],
    snapshotTasks: [
      { id: 1, enabled: true, schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "*" },
        state: { datetime: $daily_late } },
      { id: 2, enabled: true, schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "*" },
        state: { datetime: $daily_early } },
      { id: 3, enabled: true, schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "7" },
        state: { datetime: $weekly_early } },
      { id: 4, enabled: true, schedule: { minute: "0", hour: "0", dom: "1", month: "*", dow: "*" },
        state: { datetime: $monthly_early } },
      { id: 5, enabled: true, schedule: { minute: "0", hour: "*", dom: "*", month: "*", dow: "*" },
        state: { datetime: $hourly_late } },
      { id: 6, enabled: true, schedule: { minute: "*", hour: "*", dom: "*", month: "*", dow: "*" },
        state: { datetime: $minute_late } },
      { id: 7, enabled: false, schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "*" },
        state: { datetime: $daily_late } },
      { id: 8, enabled: true, schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "*" },
        state: { datetime: null } }
    ],
    scrubs: [
      { id: 1, pool: "storage", enabled: true,
        schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "7" } },
      { id: 2, pool: "missing", enabled: true,
        schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "7" } },
      { id: 3, pool: "backup", enabled: true,
        schedule: { minute: "0", hour: "0", dom: "*", month: "*", dow: "7" } }
    ]
  }' >"$WORK/protection-payload.json"
printf '%s\n' '{"overdue":{"snapshotTasks:8":{"firstSeenAt":"2026-10-18T00:00:00Z"}}}' \
  >"$WORK/seen-never.json"
jq -n -f "$ROOT/share/protection-overdue.jq" \
  --slurpfile payload "$WORK/protection-payload.json" \
  --slurpfile seen "$WORK/seen-never.json" \
  --arg now "$now" --argjson graceSeconds 21600 \
  --argjson replicationOk 1 --argjson cloudSyncOk 1 \
  --argjson snapshotTasksOk 1 --argjson scrubsOk 1 \
  >"$WORK/protection-out.json"
overdue() { jq -r --argjson id "$2" ".payload.$1[] | select(.id==\$id) | .overdue" "$WORK/protection-out.json"; }
check "a daily task 31h late is overdue" true "$(overdue snapshotTasks 1)"
check "a daily task 29h late is not" false "$(overdue snapshotTasks 2)"
check "a weekly task 7d late is still inside its grace" false "$(overdue snapshotTasks 3)"
check "a monthly task 40d late is inside the 62d bound" false "$(overdue snapshotTasks 4)"
check "an hourly task 8h late is overdue" true "$(overdue snapshotTasks 5)"
check "a minute task 7h late is overdue" true "$(overdue snapshotTasks 6)"
check "a disabled task is never overdue" false "$(overdue snapshotTasks 7)"
check "a never-run task past its first-seen grace is overdue" true "$(overdue snapshotTasks 8)"
check "a running job is exempt from the age test" false "$(overdue replication 1)"
check "an old scrub is overdue" true "$(overdue scrubs 1)"
check "a scrub for a missing pool is not judged" false "$(overdue scrubs 2)"
check "its last run is unknown, not never run" false \
  "$(jq -r '.payload.scrubs[] | select(.id==2) | .lastRunKnown' "$WORK/protection-out.json")"
check "a scrub hidden by a resilver is not judged overdue" false "$(overdue scrubs 3)"
check "and its last run is unknown" false \
  "$(jq -r '.payload.scrubs[] | select(.id==3) | .lastRunKnown' "$WORK/protection-out.json")"
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

test_case "a failed protection fetch leaves that section empty with a warning"
for pair in "replication:/api/v2.0/replication" \
            "cloudSync:/api/v2.0/cloudsync" \
            "snapshotTasks:/api/v2.0/pool/snapshottask" \
            "scrubs:/api/v2.0/pool/scrub"; do
  section=${pair%%:*}; route=${pair#*:}
  setup; single_instance_config
  protection_route_fails "$route"
  poll
  check "$section is empty, not fabricated rows" "[]" "$(state ".$section")"
  check "a warning names the $section section" "$section" \
    "$(state ".warnings[] | select(.section==\"$section\") | .section")"
  check "the $section failure leaves the pools rendering" 2 \
    "$(state '.pools | length')"
  teardown
done

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
check "fifteen requests on a cold poll" 15 "$(requests)"
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

test_case "a failed SMB fetch leaves smb empty while the other shares render"
setup; single_instance_config
share_route_fails "/api/v2.0/sharing/smb"
poll
check "smb is empty, not fabricated rows" "[]" "$(state '.shares.smb')"
check "a warning names the smb section" smb \
  "$(state '.warnings[] | select(.section=="smb") | .section')"
check "the NFS export still renders" 1 "$(state '.shares.nfs | length')"
check "the iSCSI targets still render" 2 "$(state '.shares.iscsi | length')"
check "the interface still renders" 1 "$(state '.network | length')"
teardown

test_case "a failed interface fetch leaves network empty while the shares render"
setup; single_instance_config
share_route_fails "/api/v2.0/interface"
poll
check "network is empty, not fabricated rows" "[]" "$(state '.network')"
check "a warning names the network section" network \
  "$(state '.warnings[] | select(.section=="network") | .section')"
check "the SMB shares still render" 3 "$(state '.shares.smb | length')"
check "the NFS export still renders" 1 "$(state '.shares.nfs | length')"
teardown

test_case "an empty iSCSI target list is a real zero with no warning"
setup; single_instance_config
# The live box has zero iSCSI targets, so the route answers [] and that is a
# real zero, not a failed section.
printf '[]\n' >"$WORK/iscsi-empty.json"
all_healthy "$WORK/iscsi-empty.json"
poll
check "iscsi is an empty list" "[]" "$(state '.shares.iscsi')"
check "and no warning names it" 0 \
  "$(state '[.warnings[] | select(.section=="iscsi")] | length')"
teardown

test_case "a 200 with a non-object share row fails the section, not fabricates a card"
setup; single_instance_config
printf '[{}, null]\n' >"$WORK/bad-shares.json"
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"       0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/sharing/smb" 0 200 "$WORK/bad-shares.json"
poll
check "smb is empty, not a nameless card" "[]" "$(state '.shares.smb')"
check "and a warning names the smb section" smb \
  "$(state '.warnings[] | select(.section=="smb") | .section')"
teardown

test_case "a successful poll appends the fullest pool's capacity"
setup; single_instance_config
all_healthy
poll
check "one sample" 1 "$(history '.capacityPct | length')"
check "the fullest pool's percent" 71 "$(history '.capacityPct[0]')"
check "and a timestamp beside it" 1 \
  "$(history '[.at[]? | select(test("^[0-9]{4}-"))] | length')"
poll
check "the next poll appends too" 2 "$(history '.capacityPct | length')"
check "newest last" "71,71" "$(history '.capacityPct | join(",")')"
teardown

test_case "an unknown capacity records a null gap, never a fake zero"
setup; single_instance_config
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"       0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "the poll still wrote state" 1 "$(state '.schema')"
check "one sample" 1 "$(history '.capacityPct | length')"
check "the gap is null, not a fake zero" null "$(history '.capacityPct[0]')"
teardown

test_case "the history is capped at sixty, oldest dropped"
setup; single_instance_config
mkdir -p "$(dirname "$HISTORY")"
jq -n '{capacityPct: [range(1; 61)], at: [range(60) | "2026-01-01T00:00:00Z"]}' >"$HISTORY"
all_healthy
poll
check "still sixty samples" 60 "$(history '.capacityPct | length')"
check "the oldest is gone" 2 "$(history '.capacityPct[0]')"
check "the newest is this poll's" 71 "$(history '.capacityPct[59]')"
check "the timestamps stay paired" 60 "$(history '.at | length')"
teardown

test_case "a failed poll leaves the history untouched"
setup; single_instance_config
mkdir -p "$(dirname "$HISTORY")"
printf '{"capacityPct":[42],"at":["2026-01-01T00:00:00Z"]}\n' >"$HISTORY"
cp "$HISTORY" "$WORK/history.before"
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "the poll failed" false "$(state '.connection.ok')"
check "the history file is unchanged" "$(cat "$WORK/history.before")" "$(cat "$HISTORY")"
check "no sample was appended" 1 "$(history '.capacityPct | length')"
check "and the value is untouched" 42 "$(history '.capacityPct[0]')"
teardown

test_case "a failed first poll never creates a history file"
setup; single_instance_config
respond "/api/v2.0/alert/list" 7 0 /dev/null
poll
check "no history file was created" false \
  "$(test -e "$HISTORY" && echo true || echo false)"
teardown

# The map for an output-check poll lives in tests/lib.sh with the other
# fixtures, so 11-notify.sh can use it too.
test_case "a cold poll annotates a due task unknown and a warm poll probes it once"
setup; single_instance_config
output_check_on '["snapshotTasks:1"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
rows=$(probe_tree storage auto-hourly-2026-09-14_01-00 0 0 "$WORK/rows.json")
output_probe_map "$snaps" "$rows"

poll
check "the cold poll spent fifteen" 15 "$(requests)"
check "and probed nothing" 0 "$(snapshot_queries)"
check "the due row is unknown" unknown \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "and does not invent no-data" false \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"

: >"$STUB_CURL_LOG"
"$ROOT/bin/truenas-poll" --quiet --force-meta
check "a forced meta poll still spends fifteen" 15 "$(requests)"
check "and never probes" 0 "$(snapshot_queries)"

: >"$STUB_CURL_LOG"
poll
check "a warm poll is two plus one probe" 3 "$(requests)"
check "with one snapshot query" 1 "$(snapshot_queries)"
check "the empty run is empty" empty \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "and is no-data" true \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"
check "with the zero it read" 0 \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.written')"

: >"$STUB_CURL_LOG"
poll
check "the same run is not probed again" 2 "$(requests)"
check "and no snapshot query is made" 0 "$(snapshot_queries)"
teardown

test_case "a recursive probe sums the children, so a zero parent is not empty"
setup; single_instance_config
output_check_on '["snapshotTasks:1"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
rows=$(probe_tree storage auto-hourly-2026-09-14_01-00 0 3.26G "$WORK/rows.json")
output_probe_map "$snaps" "$rows"
poll
: >"$STUB_CURL_LOG"
poll
check "one name-wide query" 1 "$(grep -c 'snapshot_name=auto-hourly-2026-09-14_01-00' "$STUB_CURL_LOG")"
check "the parent zero plus the child is a number" 3500398346 \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.written')"
check "the run is ok" ok \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "and is not no-data" false \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"
teardown

test_case "a non-recursive task asks for the exact snapshot name"
setup; single_instance_config
output_check_on '["snapshotTasks:7"]'
snaps=$(snap_due 7 false true "$WORK/snaps.json")
cat >"$WORK/rows.json" <<'JSON'
[ { "dataset": "boot-pool", "name": "boot-pool@auto-hourly-2026-09-14_01-00",
    "snapshot_name": "auto-hourly-2026-09-14_01-00",
    "properties": { "written": { "value": "512K" }, "used": { "value": "0B" } } } ]
JSON
output_probe_map "$snaps" "$WORK/rows.json"
poll
: >"$STUB_CURL_LOG"
poll
check "the query is the full name, not the bare snapshot" 1 \
  "$(grep -c 'name=boot-pool%40auto-hourly-2026-09-14_01-00' "$STUB_CURL_LOG")"
check "no name-wide query is made" 0 \
  "$(grep -c 'snapshot_name=' "$STUB_CURL_LOG")"
check "the size string parses to bytes" 524288 \
  "$(state '.snapshotTasks[] | select(.id==7) | .output.written')"
teardown

test_case "one query serves two tasks that share a run name"
setup; single_instance_config
output_check_on '["snapshotTasks:1","snapshotTasks:2"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
jq '. + [ .[0] | .id = 2 | .dataset = "storage2"
           | .state.last_snapshot = "storage2@auto-hourly-2026-09-14_01-00" ]' \
  "$WORK/snaps.json" >"$WORK/snaps2.json"
cat >"$WORK/rows.json" <<'JSON'
[ { "dataset": "storage", "name": "storage@auto-hourly-2026-09-14_01-00",
    "snapshot_name": "auto-hourly-2026-09-14_01-00",
    "properties": { "written": { "value": "1K" } } },
  { "dataset": "storage2", "name": "storage2@auto-hourly-2026-09-14_01-00",
    "snapshot_name": "auto-hourly-2026-09-14_01-00",
    "properties": { "written": { "value": "2K" } } } ]
JSON
output_probe_map "$WORK/snaps2.json" "$WORK/rows.json"
poll
: >"$STUB_CURL_LOG"
poll
check "two tasks share one query" 1 "$(snapshot_queries)"
check "the first task reads its own dataset" 1024 \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.written')"
check "the second task reads its own" 2048 \
  "$(state '.snapshotTasks[] | select(.id==2) | .output.written')"
teardown

test_case "the cap rotates: three due tasks, one probe per warm poll"
setup; single_instance_config
output_check_on '["snapshotTasks:1","snapshotTasks:2","snapshotTasks:3"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
jq '. + [ .[0] | .id = 2 | .dataset = "d2"
           | .state.last_snapshot = "d2@auto-b" ]
        + [ .[0] | .id = 3 | .dataset = "d3"
           | .state.last_snapshot = "d3@auto-c" ]' "$WORK/snaps.json" >"$WORK/snaps3.json"
cat >"$WORK/rows.json" <<'JSON'
[ { "dataset": "storage", "name": "storage@auto-hourly-2026-09-14_01-00",
    "snapshot_name": "auto-hourly-2026-09-14_01-00",
    "properties": { "written": { "value": "1K" } } },
  { "dataset": "d2", "name": "d2@auto-b", "snapshot_name": "auto-b",
    "properties": { "written": { "value": "1K" } } },
  { "dataset": "d3", "name": "d3@auto-c", "snapshot_name": "auto-c",
    "properties": { "written": { "value": "1K" } } } ]
JSON
output_probe_map "$WORK/snaps3.json" "$WORK/rows.json"
poll
for round in 1 2 3; do
  : >"$STUB_CURL_LOG"
  poll
  check "round $round spends one probe" 1 "$(snapshot_queries)"
done
check "all three tasks got an answer" 3 \
  "$(state '[.snapshotTasks[] | select(.id <= 3) | .output.state] | length')"
check "and all are ok" "ok,ok,ok" \
  "$(state '[.snapshotTasks[] | select(.id <= 3) | .output.state] | join(",")')"
teardown

test_case "a failed snapshot query keeps the previous no-data and retries"
setup; single_instance_config
output_check_on '["snapshotTasks:1"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
rows=$(probe_tree storage auto-hourly-2026-09-14_01-00 0 0 "$WORK/rows.json")
output_probe_map "$snaps" "$rows"
poll
: >"$STUB_CURL_LOG"
poll
check "the first answer is no-data" true \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"

# Move the run to a new name, then fail the query for it.
stamp=$(date -u -d '30 seconds' +%Y-%m-%dT%H:%M:%SZ)
jq --arg s "$stamp" \
  'map(if .id == 1 then .state.datetime = $s
         | .state.last_snapshot = "storage@auto-hourly-2026-09-14_01-30"
       else . end)' "$WORK/snaps.json" >"$WORK/snaps2.json"
output_probe_map "$WORK/snaps2.json" "$rows"
respond_first "/api/v2.0/pool/snapshot?snapshot_name=auto-hourly-2026-09-14_01-30" \
  0 500 "$ROOT/tests/fixtures/err-500.json"
run_before=$(seen '.output["snapshotTasks:1"].lastRunAt')
# The task body lives in the meta cache; a forced poll is what makes the new
# run visible. It never probes, so the warm poll after it is the first attempt.
"$ROOT/bin/truenas-poll" --quiet --force-meta
: >"$STUB_CURL_LOG"
poll
check "the row is unknown, not healthy" unknown \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "the previous no-data survives" true \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"
check "the section is named in warnings" snapshotRows \
  "$(state '.warnings[] | select(.section=="snapshotRows") | .section')"
check "the seen badge survives" true "$(seen '.output["snapshotTasks:1"].noData')"

# The failure advanced lastProbeAt, so the next poll retries rather than
# treating the run as answered.
before=$(seen '.output["snapshotTasks:1"].lastProbeAt')
sleep 1
poll
after=$(seen '.output["snapshotTasks:1"].lastProbeAt')
check "a failed probe advances lastProbeAt" true \
  "$([[ $after > $before ]] && echo true || echo false)"
check "but not lastRunAt" "$run_before" \
  "$(seen '.output["snapshotTasks:1"].lastRunAt')"
teardown

test_case "an unparseable written value is presence-only ok"
setup; single_instance_config
output_check_on '["snapshotTasks:1"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
cat >"$WORK/rows.json" <<'JSON'
[ { "dataset": "storage", "name": "storage@auto-hourly-2026-09-14_01-00",
    "snapshot_name": "auto-hourly-2026-09-14_01-00",
    "properties": { "written": { "value": "lots" } } } ]
JSON
output_probe_map "$snaps" "$WORK/rows.json"
poll
: >"$STUB_CURL_LOG"
poll
check "the snapshot is present" ok \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "with no written number" null \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.written // null')"
check "and no no-data badge" false \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"
teardown

test_case "a successful run with no lastSnapshot is missing without a query"
setup; single_instance_config
output_check_on '["snapshotTasks:1"]'
snaps=$(snap_due 1 true true "$WORK/snaps.json")
jq 'map(if .id == 1 then .state.last_snapshot = null else . end)' \
  "$WORK/snaps.json" >"$WORK/snaps2.json"
rows=$(probe_tree storage auto-hourly-2026-09-14_01-00 0 0 "$WORK/rows.json")
output_probe_map "$WORK/snaps2.json" "$rows"
poll
: >"$STUB_CURL_LOG"
poll
check "no snapshot query is made" 0 "$(snapshot_queries)"
check "the row is missing" missing \
  "$(state '.snapshotTasks[] | select(.id==1) | .output.state')"
check "and is no-data" true \
  "$(state '.snapshotTasks[] | select(.id==1) | .noData')"
teardown
