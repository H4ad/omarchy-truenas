# shellcheck shell=bash
# Task 5: desktop notifications and seen.json.

# The fixture builders every notification case needs live in lib.sh with the
# other helpers, so 16-argv.sh can use them without depending on this file
# being sourced first.

test_case "a new critical alert toasts once"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "one toast" 1 "$(notifications)"
check "and it names the level" 1 "$(grep -c 'New critical alert' "$STUB_NOTIFY_LOG" || true)"
check "so the alert text stays out of argv" 0 \
  "$(grep -c 'Pool storage state is DEGRADED' "$STUB_NOTIFY_LOG" || true)"
poll
check "the same alert does not toast again" 1 "$(notifications)"
teardown

test_case "clearing an alert toasts its resolution"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "a resolution toast" 1 "$(grep -c 'Alert resolved' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "a pool going DEGRADED toasts, recovering is low"
setup; single_instance_config
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a healthy pool is quiet" 0 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-degraded.json"
poll
check "one worsening toast" 1 "$(notifications)"
check "it names the status, not the pool" 1 \
  "$(grep -c 'A pool is DEGRADED' "$STUB_NOTIFY_LOG" || true)"
check "so the pool name stays out of argv" 0 \
  "$(grep -c 'storage' "$STUB_NOTIFY_LOG" || true)"
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
check "with the summon command as separate argv words" 1 \
  "$(grep -c ' --exec omarchy-shell -q shell summon io.github.h4ad.truenas$' "$STUB_NOTIFY_LOG" || true)"
check "and never the configured base URL" 0 \
  "$(grep -c 'nas.example' "$STUB_NOTIFY_LOG" || true)"
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
check "no resolution toast" 0 "$(grep -c 'Alert resolved' "$STUB_NOTIFY_LOG" || true)"
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

# --- Disk temperatures ------------------------------------------------------
# Every disk case runs with metaMaxAgeSeconds 0, because otherwise the meta
# cache would replay the first poll's temperatures and a second poll could
# never see a disk get hot or cool.

test_case "a cool disk baseline toasts nothing"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "no disk toast" 0 "$(notifications)"
check "all five disks are recorded" 5 "$(seen '.disks | length')"
check "sda is recorded ok" ok "$(seen '.disks.sda.state')"
check "with its temperature" 38 "$(seen '.disks.sda.tempC')"
teardown

test_case "a hot disk toasts once with its threshold and state"
setup; single_instance_config '{"metaMaxAgeSeconds":0,"stickyCritical":true}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the cool baseline is quiet" 0 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "one toast per hot disk" 2 "$(notifications)"
check "the critical disk's temperature and threshold" 1 \
  "$(awk '/A disk is hot/ && /61 °C, critical at 60 °C/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the warning disk's band start" 1 \
  "$(awk '/A disk is hot/ && /51 °C, warning at 50 °C/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "and neither disk name is in argv" 0 \
  "$(grep -c -e 'sda' -e 'sdc' "$STUB_NOTIFY_LOG" || true)"
check "the critical disk carries the critical glyph" 1 \
  "$(awk -v g=$'\uf071' '/A disk is hot/ && /61 °C/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the warning disk carries the alert glyph" 1 \
  "$(awk -v g=$'\uf0f3' '/A disk is hot/ && /51 °C/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the critical disk is critical urgency" 1 \
  "$(awk '/A disk is hot/ && /61 °C/ && /-u critical/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the warning disk is normal urgency" 1 \
  "$(awk '/A disk is hot/ && /51 °C/ && /-u normal/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the hot toast opens the plugin menu" 1 \
  "$(awk '/A disk is hot/ && /61 °C/ && /--exec omarchy-shell -q shell summon io.github.h4ad.truenas/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "sda is recorded critical" critical "$(seen '.disks.sda.state')"
check "sdc is recorded warning" warning "$(seen '.disks.sdc.state')"
check "sdb is still ok" ok "$(seen '.disks.sdb.state')"
teardown

test_case "a disk that stays hot does not toast again"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "the first hot poll toasts" 2 "$(notifications)"
poll
check "the second hot poll is quiet" 2 "$(notifications)"
check "and the state is still recorded" critical "$(seen '.disks.sda.state')"
teardown

test_case "a hot disk that cools toasts at low urgency"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "the hot pair toasted" 2 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "both cooled toasts" 4 "$(notifications)"
check "the cooled disk's temperature" 1 \
  "$(awk '/A disk cooled/ && /38 °C/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "at low urgency" 1 \
  "$(awk '/A disk cooled/ && /38 °C/ && /-u low/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "with the ok glyph" 1 \
  "$(awk -v g=$'\uf00c' '/A disk cooled/ && /38 °C/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "sda is ok again" ok "$(seen '.disks.sda.state')"
teardown

test_case "a failed temperature call leaves seen.disks untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the cool baseline is quiet" 0 "$(notifications)"
before=$(seen '.disks')
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "no disk toast from a failed temperature answer" 0 "$(notifications)"
check "the serialized seen.disks is unchanged" "$before" "$(seen '.disks')"
teardown

test_case "a failed details call leaves seen.disks untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the cool baseline is quiet" 0 "$(notifications)"
before=$(seen '.disks')
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "no disk toast from a failed details answer" 0 "$(notifications)"
check "the serialized seen.disks is unchanged" "$before" "$(seen '.disks')"
teardown

test_case "an unknown disk that reads hot toasts"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
jq -c 'del(.sda)' "$ROOT/tests/fixtures/disk-temperatures.json" >"$WORK/temps-no-sda.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$WORK/temps-no-sda.json"
poll
check "a missing reading is unknown" unknown "$(seen '.disks.sda.state')"
check "and unknown toasts nothing" 0 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "crossing from unknown into critical toasts" 1 \
  "$(awk '/A disk is hot/ && /61 °C/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "sda is recorded critical" critical "$(seen '.disks.sda.state')"
teardown

test_case "a removed disk drops its seen entry"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "five disks are recorded" 5 "$(seen '.disks | length')"
jq -c 'map(select(.name != "sda"))' "$ROOT/tests/fixtures/disks.json" >"$WORK/disks-no-sda.json"
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$WORK/disks-no-sda.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "the removed disk is gone" false "$(seen '.disks | has("sda")')"
check "four disks remain" 4 "$(seen '.disks | length')"
teardown

test_case "a disk that goes unknown does not toast as cooled"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json"
poll
check "the hot pair toasted" 2 "$(notifications)"
jq -c 'del(.sda)' "$ROOT/tests/fixtures/disk-temperatures.json" >"$WORK/temps-no-sda.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$WORK/temps-no-sda.json"
poll
check "sda went unknown" unknown "$(seen '.disks.sda.state')"
check "no cooled toast for the unknown disk" 0 \
  "$(awk '/A disk cooled/ && /38 °C/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "but the warning disk cooled" 3 "$(notifications)"
teardown

# --- Services ---------------------------------------------------------------
# The service and app lists ride the meta cache, so every case here runs with
# metaMaxAgeSeconds 0: without it a second poll reuses the first poll's cached
# rows and a handled transition can never be seen.

test_case "a service going down toasts once and is not replayed"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the running baseline is quiet" 0 "$(notifications)"
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "one down toast" 1 "$(notifications)"
check "the headline names the state, not the service" 1 \
  "$(grep -c 'A service is STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "the body carries the transition" 1 \
  "$(grep -c 'state changed from RUNNING to STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "and the service name stays out of argv" 0 \
  "$(grep -c 'cifs' "$STUB_NOTIFY_LOG" || true)"
check "with the alert glyph" 1 \
  "$(awk -v g=$'\uf0f3' '/A service is STOPPED/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "at normal urgency (warning maps to normal)" 1 \
  "$(awk '/A service is STOPPED/ && /-u normal/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the exec is the plugin menu, not the base" 1 \
  "$(awk '/A service is STOPPED/ && /--exec omarchy-shell -q shell summon io.github.h4ad.truenas/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is recorded" STOPPED "$(seen '.services.cifs.state')"
poll
check "an identical poll does not replay" 1 "$(notifications)"
teardown

test_case "a service that comes back toasts a recovery"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "the down toast fired first" 1 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a recovery toast" 2 "$(notifications)"
check "saying it is running again" 1 \
  "$(grep -c 'A service is running again' "$STUB_NOTIFY_LOG" || true)"
check "at low urgency" 1 \
  "$(awk '/A service is running again/ && /-u low/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "with the ok glyph" 1 \
  "$(awk -v g=$'\uf00c' '/A service is running again/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is RUNNING again" RUNNING "$(seen '.services.cifs.state')"
teardown

test_case "a service first sighted down toasts nothing"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "no toast on a first sighting" 0 "$(notifications)"
check "but the state is recorded" STOPPED "$(seen '.services.cifs.state')"
poll
check "and an identical poll stays quiet" 0 "$(notifications)"
teardown

test_case "a failed service poll leaves seen.services untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the healthy baseline is quiet" 0 "$(notifications)"
before=$(seen '.services')
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 500 "$ROOT/tests/fixtures/err-500.json"
respond_add "/api/v2.0/app"         0 200 "$ROOT/tests/fixtures/apps.json"
poll
check "no service toast from a failed answer" 0 "$(notifications)"
check "the serialized seen.services is unchanged" "$before" "$(seen '.services')"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "and nothing is replayed on the next good poll" 0 "$(notifications)"
teardown

# --- Apps -------------------------------------------------------------------

test_case "an app going down toasts once and is not replayed"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the running baseline is quiet" 0 "$(notifications)"
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-crashed.json"
poll
check "one down toast" 1 "$(notifications)"
check "the headline names the state, not the app" 1 \
  "$(grep -c 'An app is CRASHED' "$STUB_NOTIFY_LOG" || true)"
check "the body carries the transition" 1 \
  "$(grep -c 'state changed from RUNNING to CRASHED' "$STUB_NOTIFY_LOG" || true)"
check "and the app name stays out of argv" 0 \
  "$(grep -c 'appc' "$STUB_NOTIFY_LOG" || true)"
check "with the alert glyph" 1 \
  "$(awk -v g=$'\uf0f3' '/An app is CRASHED/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "at normal urgency (warning maps to normal)" 1 \
  "$(awk '/An app is CRASHED/ && /-u normal/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the exec is the plugin menu, not the base" 1 \
  "$(awk '/An app is CRASHED/ && /--exec omarchy-shell -q shell summon io.github.h4ad.truenas/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is recorded" CRASHED "$(seen '.apps.appc.state')"
poll
check "an identical poll does not replay" 1 "$(notifications)"
teardown

test_case "an app that comes back toasts a recovery"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-crashed.json"
poll
check "the down toast fired first" 1 "$(notifications)"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "a recovery toast" 2 "$(notifications)"
check "saying it is running again" 1 \
  "$(grep -c 'An app is running again' "$STUB_NOTIFY_LOG" || true)"
check "at low urgency" 1 \
  "$(awk '/An app is running again/ && /-u low/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "with the ok glyph" 1 \
  "$(awk -v g=$'\uf00c' '/An app is running again/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is RUNNING again" RUNNING "$(seen '.apps.appc.state')"
teardown

test_case "an app first sighted down toasts nothing"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-crashed.json"
poll
check "no toast on a first sighting" 0 "$(notifications)"
check "but the state is recorded" CRASHED "$(seen '.apps.appc.state')"
poll
check "and an identical poll stays quiet" 0 "$(notifications)"
teardown

test_case "a failed app poll leaves seen.apps untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the healthy baseline is quiet" 0 "$(notifications)"
before=$(seen '.apps')
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service"     0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app"         0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "no app toast from a failed answer" 0 "$(notifications)"
check "the serialized seen.apps is unchanged" "$before" "$(seen '.apps')"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "and nothing is replayed on the next good poll" 0 "$(notifications)"
teardown

test_case "a transitional app state is not down and does not toast"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the running baseline is quiet" 0 "$(notifications)"
down_app appc DEPLOYING "$WORK/apps-appc-deploying.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-deploying.json"
poll
check "a deploying app is not down" 0 "$(notifications)"
check "and the decisive state is carried forward" RUNNING "$(seen '.apps.appc.state')"
check "with down still false" false "$(seen '.apps.appc.down')"
teardown

# --- The decisive state survives a non-decisive poll ------------------------
# A blank or transitional poll must not clobber the last decisive state: the
# transition that follows is read against the state that was there before the
# gap, not against the gap itself. Reading the raw previous observation instead
# produced missed crashes and phantom recoveries.

test_case "a blank service poll does not erase the running state"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the running baseline is quiet" 0 "$(notifications)"
down_service cifs "" "$WORK/services-cifs-blank.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-blank.json"
poll
check "the blank poll toasts nothing" 0 "$(notifications)"
check "and carries RUNNING forward" RUNNING "$(seen '.services.cifs.state')"
check "with down still false" false "$(seen '.services.cifs.down')"
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "the crash after the gap still toasts" 1 "$(notifications)"
check "reading the state from before the gap" 1 \
  "$(grep -c 'state changed from RUNNING to STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "and it is recorded down" true "$(seen '.services.cifs.down')"
teardown

test_case "a blank service poll does not erase the stopped state"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "the down toast fired first" 1 "$(notifications)"
down_service cifs "" "$WORK/services-cifs-blank.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-blank.json"
poll
check "the blank poll toasts nothing new" 1 "$(notifications)"
check "and carries STOPPED forward" STOPPED "$(seen '.services.cifs.state')"
check "with down still true" true "$(seen '.services.cifs.down')"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the recovery after the gap still toasts" 2 "$(notifications)"
check "saying it is running again" 1 \
  "$(grep -c 'A service is running again' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "a service first sighted blank toasts a later down with no empty from"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
down_service cifs "" "$WORK/services-cifs-blank.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-blank.json"
poll
check "the blank first sighting is quiet" 0 "$(notifications)"
check "with no decisive state yet" "" "$(seen '.services.cifs.state')"
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-cifs-stopped.json"
poll
check "the later down toasts" 1 "$(notifications)"
check "with no state to name as the from" 1 \
  "$(grep -c 'state changed to STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "and never an empty from" 0 \
  "$(grep -c 'state changed from  to' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "a deploying app does not erase the running state"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the running baseline is quiet" 0 "$(notifications)"
down_app appc DEPLOYING "$WORK/apps-appc-deploying.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-deploying.json"
poll
check "the transitional poll toasts nothing" 0 "$(notifications)"
check "and carries RUNNING forward" RUNNING "$(seen '.apps.appc.state')"
check "with down still false" false "$(seen '.apps.appc.down')"
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-crashed.json"
poll
check "the crash after the transition still toasts" 1 "$(notifications)"
check "reading the state from before the transition" 1 \
  "$(grep -c 'state changed from RUNNING to CRASHED' "$STUB_NOTIFY_LOG" || true)"
check "and it is recorded down" true "$(seen '.apps.appc.down')"
teardown

test_case "a deploying app does not erase the crashed state"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-crashed.json"
poll
check "the crash toast fired first" 1 "$(notifications)"
down_app appc DEPLOYING "$WORK/apps-appc-deploying.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$ROOT/tests/fixtures/services.json" \
  "$WORK/apps-appc-deploying.json"
poll
check "the transitional poll toasts nothing new" 1 "$(notifications)"
check "and carries CRASHED forward" CRASHED "$(seen '.apps.appc.state')"
check "with down still true" true "$(seen '.apps.appc.down')"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json"
poll
check "the recovery after the transition still toasts" 2 "$(notifications)"
check "saying it is running again" 1 \
  "$(grep -c 'An app is running again' "$STUB_NOTIFY_LOG" || true)"
teardown

test_case "one poll toasts a service down and another up"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
jq -c 'map(if .service == "ssh" then .state = "STOPPED" else . end)' \
  "$ROOT/tests/fixtures/services.json" >"$WORK/services-ssh-stopped.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-ssh-stopped.json"
poll
check "the mixed first sighting is quiet" 0 "$(notifications)"
check "cifs is recorded up" false "$(seen '.services.cifs.down')"
check "ssh is recorded down" true "$(seen '.services.ssh.down')"
jq -c 'map(if .service == "cifs" then .state = "STOPPED"
           elif .service == "ssh" then .state = "RUNNING" else . end)' \
  "$ROOT/tests/fixtures/services.json" >"$WORK/services-two-moves.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" "$WORK/services-two-moves.json"
poll
check "two toasts from one poll" 2 "$(notifications)"
check "the service that went down" 1 \
  "$(grep -c 'state changed from RUNNING to STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "the service that came back" 1 \
  "$(grep -c 'A service is running again' "$STUB_NOTIFY_LOG" || true)"
check "and neither service name is in argv" 0 \
  "$(grep -c -e 'cifs' -e 'ssh' "$STUB_NOTIFY_LOG" || true)"
check "cifs is now down" true "$(seen '.services.cifs.down')"
check "ssh is now up" false "$(seen '.services.ssh.down')"
teardown

# --- Protection (replication and cloud sync) --------------------------------
# Only replication and cloud sync carry a job, so only they toast. Every case
# runs with metaMaxAgeSeconds 0, because the protection rows ride the meta cache
# and a second poll would otherwise reuse the first poll's rows.

test_case "a replication job going FAILED toasts once and is not replayed"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
check "a successful baseline is quiet" 0 "$(notifications)"
check "the job state is recorded" SUCCESS "$(seen '.replication["1"].state')"
check "and it is not failed" false "$(seen '.replication["1"].failed')"
rep_job 1 FAILED "send failed" "$WORK/rep-failed.json"
notify_protection "$WORK/rep-failed.json"
poll
check "one failure toast" 1 "$(notifications)"
check "the headline names the kind, not the task" 1 \
  "$(grep -c 'Replication failed' "$STUB_NOTIFY_LOG" || true)"
check "the body carries the job state, not the error" 1 \
  "$(grep -c 'job state FAILED' "$STUB_NOTIFY_LOG" || true)"
check "and the task name and error stay out of argv" 0 \
  "$(grep -c -e 'storage-to-backup' -e 'send failed' "$STUB_NOTIFY_LOG" || true)"
check "with the alert glyph" 1 \
  "$(awk -v g=$'\uf0f3' '/Replication failed/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "at normal urgency" 1 \
  "$(awk '/Replication failed/ && /-u normal/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the exec is the plugin menu, not the base" 1 \
  "$(awk '/Replication failed/ && /--exec omarchy-shell -q shell summon io.github.h4ad.truenas/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is recorded" FAILED "$(seen '.replication["1"].state')"
check "and it is failed" true "$(seen '.replication["1"].failed')"
poll
check "an identical poll does not replay" 1 "$(notifications)"
teardown

test_case "a replication job that recovers toasts a recovery"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
rep_job 1 FAILED "" "$WORK/rep-failed.json"
notify_protection "$WORK/rep-failed.json"
poll
check "a first sighting that is failed is quiet" 0 "$(notifications)"
check "but it is recorded failed" true "$(seen '.replication["1"].failed')"
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
check "a recovery toast" 1 "$(notifications)"
check "saying it recovered" 1 \
  "$(grep -c 'Replication recovered' "$STUB_NOTIFY_LOG" || true)"
check "at low urgency" 1 \
  "$(awk '/Replication recovered/ && /-u low/ { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "with the ok glyph" 1 \
  "$(awk -v g=$'\uf00c' '/Replication recovered/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
check "the state is SUCCESS again" SUCCESS "$(seen '.replication["1"].state')"
teardown

test_case "replication state warnings are a failure"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
check "the clean baseline is quiet" 0 "$(notifications)"
rep_warn 1 "$WORK/rep-warn.json"
notify_protection "$WORK/rep-warn.json"
poll
check "warnings toast" 1 "$(notifications)"
check "naming the kind" 1 \
  "$(grep -c 'Replication failed' "$STUB_NOTIFY_LOG" || true)"
check "and it is recorded failed" true "$(seen '.replication["1"].failed')"
teardown

test_case "a RUNNING job carries the decisive state forward and a later FAILED still toasts"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
rep_job 1 RUNNING "" "$WORK/rep-running.json"
notify_protection "$WORK/rep-running.json"
poll
check "a running job toasts nothing" 0 "$(notifications)"
check "and carries SUCCESS forward" SUCCESS "$(seen '.replication["1"].state')"
check "with failed still false" false "$(seen '.replication["1"].failed')"
rep_job 1 FAILED "boom" "$WORK/rep-failed.json"
notify_protection "$WORK/rep-failed.json"
poll
check "the failure after the gap still toasts" 1 "$(notifications)"
check "and it is recorded failed" true "$(seen '.replication["1"].failed')"
teardown

test_case "a failed replication poll leaves seen.replication untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
check "the baseline is quiet" 0 "$(notifications)"
before=$(seen '.replication')
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool/snapshottask" 0 200 "$ROOT/tests/fixtures/snapshot-tasks.json"
respond_add "/api/v2.0/pool/scrub" 0 200 "$ROOT/tests/fixtures/scrubs.json"
respond_add "/api/v2.0/pool" 0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
respond_add "/api/v2.0/disk/details" 0 200 "$ROOT/tests/fixtures/disks.json"
respond_add "/api/v2.0/disk/temperatures" 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
respond_add "/api/v2.0/service" 0 200 "$ROOT/tests/fixtures/services.json"
respond_add "/api/v2.0/app" 0 200 "$ROOT/tests/fixtures/apps.json"
respond_add "/api/v2.0/replication" 0 500 "$ROOT/tests/fixtures/err-500.json"
respond_add "/api/v2.0/cloudsync" 0 200 "$ROOT/tests/fixtures/cloudsync.json"
poll
check "no toast from a failed replication answer" 0 "$(notifications)"
check "the serialized seen.replication is unchanged" "$before" "$(seen '.replication')"
notify_protection "$ROOT/tests/fixtures/replication.json"
poll
check "and nothing is replayed on the next good poll" 0 "$(notifications)"
teardown

test_case "a cloud sync job going FAILED toasts and a recovery follows"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
cs_job SUCCESS "" "$WORK/cs-success.json"
notify_protection "$ROOT/tests/fixtures/replication.json" "$WORK/cs-success.json"
poll
check "the successful baseline is quiet" 0 "$(notifications)"
check "the job state is recorded" SUCCESS "$(seen '.cloudSync["3"].state')"
cs_job FAILED "quota exceeded" "$WORK/cs-failed.json"
notify_protection "$ROOT/tests/fixtures/replication.json" "$WORK/cs-failed.json"
poll
check "one failure toast" 1 "$(notifications)"
check "the headline names the kind, not the task" 1 \
  "$(grep -c 'Cloud sync failed' "$STUB_NOTIFY_LOG" || true)"
check "the body carries the job state, not the error" 1 \
  "$(grep -c 'job state FAILED' "$STUB_NOTIFY_LOG" || true)"
check "and the task name and error stay out of argv" 0 \
  "$(grep -c -e 'clouda' -e 'quota exceeded' "$STUB_NOTIFY_LOG" || true)"
check "and it is recorded failed" true "$(seen '.cloudSync["3"].failed')"
notify_protection "$ROOT/tests/fixtures/replication.json" "$WORK/cs-success.json"
poll
check "a recovery toast" 2 "$(notifications)"
check "saying it recovered" 1 \
  "$(grep -c 'Cloud sync recovered' "$STUB_NOTIFY_LOG" || true)"
check "with the ok glyph" 1 \
  "$(awk -v g=$'\uf00c' '/Cloud sync recovered/ && index($0, g) { n++ } END { print n+0 }' "$STUB_NOTIFY_LOG")"
teardown

test_case "a cloud sync task first sighted failed toasts nothing"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
cs_job FAILED "" "$WORK/cs-failed.json"
notify_protection "$ROOT/tests/fixtures/replication.json" "$WORK/cs-failed.json"
poll
check "no toast on a first sighting" 0 "$(notifications)"
check "but it is recorded failed" true "$(seen '.cloudSync["3"].failed')"
poll
check "and an identical poll stays quiet" 0 "$(notifications)"
teardown

test_case "a failed cloud sync poll leaves seen.cloudSync untouched"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
cs_job SUCCESS "" "$WORK/cs-success.json"
notify_protection "$ROOT/tests/fixtures/replication.json" "$WORK/cs-success.json"
poll
check "the baseline is quiet" 0 "$(notifications)"
before=$(seen '.cloudSync')
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
respond_add "/api/v2.0/cloudsync" 0 500 "$ROOT/tests/fixtures/err-500.json"
poll
check "no toast from a failed cloud sync answer" 0 "$(notifications)"
check "the serialized seen.cloudSync is unchanged" "$before" "$(seen '.cloudSync')"
teardown
