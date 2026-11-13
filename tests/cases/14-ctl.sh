# shellcheck shell=bash
# Task 7: truenasctl. The terminal surface of the plugin, and the proof that the
# key only ever travels on stdin: never in argv, never in any output.
#
# The harness has no dashboard, so `open` is given an xdg-open stub on PATH that
# records the URL it was handed. `poll` runs the real poller against the stubs.

ctl() { "$ROOT/bin/truenasctl" "$@"; }

# A single-instance config with TLS verification on, which is what the login and
# test cases start from. baseUrl is the shaped-in dummy, never reached: curl is
# stubbed.
plain_config() {
  cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "schema": 1, "pollSeconds": 30, "timeoutSeconds": 8, "insecureTLS": false,
  "instances": [ { "id": "nas", "label": "NAS", "baseUrl": "https://nas.example" } ] }
JSON
}

# ------------------------------------------------------------------- login
test_case "login stores the key on stdin and prints nothing that carries it"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
out=$(printf 'secret-key-123\n' | ctl login https://nas.example)
login_rc=$?
check "exit ok" 0 "$login_rc"
check "config written" 1 "$([[ -f $TRUENAS_CONFIG_FILE ]] && echo 1 || echo 0)"
check "credentials are mode 600" 600 "$(stat -c '%a' "$TRUENAS_CREDENTIALS_FILE")"
check "the key is stored under the bare name" 1 \
  "$(grep -cx 'TRUENAS_API_KEY=secret-key-123' "$TRUENAS_CREDENTIALS_FILE")"
check "the key never appears in stdout" 0 "$(grep -c 'secret-key-123' <<<"$out")"
check "the base url is configured" https://nas.example \
  "$(jq -r '.instances[0].baseUrl' "$TRUENAS_CONFIG_FILE")"
teardown

test_case "a second login updates the base url without duplicating"
setup
: >"$TRUENAS_CREDENTIALS_FILE"
printf 'k1\n' | ctl login https://nas.example >/dev/null 2>&1
printf 'k2\n' | ctl login https://other.example >/dev/null 2>&1
check "one instance, not two" 1 "$(jq '.instances | length' "$TRUENAS_CONFIG_FILE")"
check "the base url moved" https://other.example \
  "$(jq -r '.instances[0].baseUrl' "$TRUENAS_CONFIG_FILE")"
check "the new key replaced the old" 1 \
  "$(grep -cx 'TRUENAS_API_KEY=k2' "$TRUENAS_CREDENTIALS_FILE")"
check "the old key is gone" 0 "$(grep -c 'k1' "$TRUENAS_CREDENTIALS_FILE")"
teardown

test_case "login preserves per-instance settings and other instances"
setup
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "schema": 1, "pollSeconds": 30, "timeoutSeconds": 8, "insecureTLS": false,
  "instances": [
    { "id": "prod", "label": "Production", "baseUrl": "https://old.example",
      "tag": "prod", "apiKeyFile": "~/.config/truenas/key",
      "apiKeyCommand": "pass show truenas/prod" },
    { "id": "lab", "label": "Lab", "baseUrl": "https://lab.example" } ] }
JSON
rm -f "$TRUENAS_CREDENTIALS_FILE"
printf 'new-key\n' | ctl login https://new.example >/dev/null 2>&1
check "the base url moved" https://new.example \
  "$(jq -r '.instances[0].baseUrl' "$TRUENAS_CONFIG_FILE")"
check "the id is preserved" prod "$(jq -r '.instances[0].id' "$TRUENAS_CONFIG_FILE")"
check "the label is preserved" Production \
  "$(jq -r '.instances[0].label' "$TRUENAS_CONFIG_FILE")"
check "apiKeyCommand is preserved" "pass show truenas/prod" \
  "$(jq -r '.instances[0].apiKeyCommand' "$TRUENAS_CONFIG_FILE")"
check "apiKeyFile is preserved" "~/.config/truenas/key" \
  "$(jq -r '.instances[0].apiKeyFile' "$TRUENAS_CONFIG_FILE")"
check "tag is preserved" prod "$(jq -r '.instances[0].tag' "$TRUENAS_CONFIG_FILE")"
check "the second instance survives" https://lab.example \
  "$(jq -r '.instances[1].baseUrl' "$TRUENAS_CONFIG_FILE")"
check "two instances, not one" 2 "$(jq '.instances | length' "$TRUENAS_CONFIG_FILE")"
teardown

test_case "login seeds defaults when no instance exists yet"
setup
rm -f "$TRUENAS_CONFIG_FILE" "$TRUENAS_CREDENTIALS_FILE"
printf 'fresh-key\n' | ctl login https://nas.example >/dev/null 2>&1
check "one instance" 1 "$(jq '.instances | length' "$TRUENAS_CONFIG_FILE")"
check "the default id" nas "$(jq -r '.instances[0].id' "$TRUENAS_CONFIG_FILE")"
check "the default label" NAS "$(jq -r '.instances[0].label' "$TRUENAS_CONFIG_FILE")"
check "the url" https://nas.example "$(jq -r '.instances[0].baseUrl' "$TRUENAS_CONFIG_FILE")"
teardown

test_case "login stores no key when the config cannot be written"
setup
printf 'TRUENAS_API_KEY=old-key\n' >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
printf 'x\n' >"$WORK/blocker"
export TRUENAS_CONFIG_FILE="$WORK/blocker/config.json"
login_rc=0
printf 'new-key\n' | ctl login https://nas.example >/dev/null 2>&1 || login_rc=$?
check "login fails" 1 "$login_rc"
check "the old key is untouched" 1 \
  "$(grep -cx 'TRUENAS_API_KEY=old-key' "$TRUENAS_CREDENTIALS_FILE")"
check "the new key was never stored" 0 "$(grep -c 'new-key' "$TRUENAS_CREDENTIALS_FILE")"
teardown

test_case "login refuses a url without a scheme and --insecure is recorded"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
check "a bare host is refused" 1 \
  "$(printf 'k\n' | ctl login nas.example >/dev/null 2>&1; echo $?)"
check "nothing was written" 0 "$([[ -f $TRUENAS_CONFIG_FILE ]] && echo 1 || echo 0)"
printf 'k\n' | ctl login https://nas.example --insecure >/dev/null 2>&1
check "insecureTLS true" true "$(jq -r '.insecureTLS' "$TRUENAS_CONFIG_FILE")"
teardown

test_case "logout removes only the credentials file"
setup
plain_config
printf 'TRUENAS_API_KEY=k\n' >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
ctl logout >/dev/null 2>&1
check "credentials gone" 0 "$([[ -e $TRUENAS_CREDENTIALS_FILE ]] && echo 1 || echo 0)"
check "the config is untouched" 1 "$([[ -f $TRUENAS_CONFIG_FILE ]] && echo 1 || echo 0)"
teardown

# ------------------------------------------------------------- config list
test_case "config list reports keySet without the key"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
printf 'topsecret-value\n' | ctl login https://nas.example --insecure >/dev/null 2>&1
out=$(ctl config list)
check "keySet true" true "$(jq -r '.keySet' <<<"$out")"
check "insecureTLS true" true "$(jq -r '.insecureTLS' <<<"$out")"
check "pollSeconds default" 30 "$(jq -r '.pollSeconds' <<<"$out")"
check "redact default off" off "$(jq -r '.redact' <<<"$out")"
check "notify is an object" object "$(jq -r '.notify | type' <<<"$out")"
check "the instance base" https://nas.example "$(jq -r '.instance.baseUrl' <<<"$out")"
check "the base url is not repeated at the top level" false "$(jq 'has("baseUrl")' <<<"$out")"
check "the key is nowhere in the listing" 0 "$(grep -c 'topsecret-value' <<<"$out")"
teardown

test_case "config set writes one scalar and refuses a bad one"
setup
single_instance_config
ctl config set insecureTLS false >/dev/null
check "insecureTLS off" false "$(jq -r '.insecureTLS' "$TRUENAS_CONFIG_FILE")"
ctl config set redact names >/dev/null
check "redact set" names "$(jq -r '.redact' "$TRUENAS_CONFIG_FILE")"
check "an unknown redact level is refused" 1 \
  "$(ctl config set redact verbose >/dev/null 2>&1; echo $?)"
check "the refusal left redact alone" names \
  "$(jq -r '.redact' "$TRUENAS_CONFIG_FILE")"
ctl config set pollSeconds 60 >/dev/null
check "pollSeconds set" 60 "$(jq -r '.pollSeconds' "$TRUENAS_CONFIG_FILE")"
check "a non-number pollSeconds is refused" 1 \
  "$(ctl config set pollSeconds soon >/dev/null 2>&1; echo $?)"
check "an out-of-range pollSeconds is refused" 1 \
  "$(ctl config set pollSeconds 4294967296 >/dev/null 2>&1; echo $?)"
check "the refusal left pollSeconds alone" 60 \
  "$(jq -r '.pollSeconds' "$TRUENAS_CONFIG_FILE")"
check "the ceiling itself is accepted" 0 \
  "$(ctl config set pollSeconds 86400 >/dev/null 2>&1; echo $?)"
ctl config set pollSeconds 60 >/dev/null
check "an out-of-range timeoutSeconds is refused" 1 \
  "$(ctl config set timeoutSeconds 99999 >/dev/null 2>&1; echo $?)"
check "an unknown key is refused" 1 \
  "$(ctl config set bananas 1 >/dev/null 2>&1; echo $?)"
teardown

test_case "expect writes one task key, dedupes, and refuses junk"
setup
single_instance_config
check "on succeeds" 0 "$(ctl expect snapshotTasks:4 on >/dev/null 2>&1; echo $?)"
check "the key is stored" '["snapshotTasks:4"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"
ctl expect replication:1 on >/dev/null
ctl expect snapshotTasks:4 on >/dev/null
check "a duplicate is not stored twice" \
  '["replication:1","snapshotTasks:4"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"
check "the rest of the config survives" 1 \
  "$(jq -r '.instances | length' "$TRUENAS_CONFIG_FILE")"
check "off removes only that key" '["replication:1"]' \
  "$(ctl expect snapshotTasks:4 off >/dev/null; jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"
check "an unknown section is refused" 1 \
  "$(ctl expect cloudSync:1 on >/dev/null 2>&1; echo $?)"
check "a zero id is refused" 1 \
  "$(ctl expect snapshotTasks:0 on >/dev/null 2>&1; echo $?)"
check "a negative id is refused" 1 \
  "$(ctl expect replication:-1 on >/dev/null 2>&1; echo $?)"
check "a non-id is refused" 1 \
  "$(ctl expect snapshotTasks:four on >/dev/null 2>&1; echo $?)"
check "a bad on/off word is refused" 1 \
  "$(ctl expect snapshotTasks:4 maybe >/dev/null 2>&1; echo $?)"
check "the refusals left the list alone" '["replication:1"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"
check "no argument prints usage" 0 "$(ctl expect >/dev/null 2>&1; echo $?)"
teardown

test_case "config set refuses expectOutput and config list shows the raw array"
setup
single_instance_config
check "config set is refused" 1 \
  "$(ctl config set expectOutput '["snapshotTasks:4"]' >/dev/null 2>&1; echo $?)"
check "the refusal names the writer" 1 \
  "$(ctl config set expectOutput x 2>&1 | grep -c 'truenasctl expect')"
jq '.expectOutput = ["snapshotTasks:4","junk"]' "$TRUENAS_CONFIG_FILE" >"$WORK/c.json"
mv "$WORK/c.json" "$TRUENAS_CONFIG_FILE"
check "list shows the raw array" '["snapshotTasks:4","junk"]' \
  "$(ctl config list | jq -c '.expectOutput')"
teardown

test_case "expect prune refuses a missing state, a warned section and a stale state"
setup
single_instance_config
ctl expect snapshotTasks:4 on >/dev/null
check "no state is refused" 1 "$(ctl expect prune >/dev/null 2>&1; echo $?)"
check "the key survives" '["snapshotTasks:4"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"

mkdir -p "$(dirname "$STATE")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$STATE" <<JSON
{ "schema": 1, "updatedAt": "$now", "pollSeconds": 30,
  "connection": { "ok": true },
  "snapshotTasks": [ { "id": 5 } ],
  "warnings": [ { "section": "snapshotTasks", "error": "timeout", "message": "x" } ] }
JSON
check "a warned section is refused" 1 "$(ctl expect prune >/dev/null 2>&1; echo $?)"
check "the refusal names the section" 1 \
  "$(ctl expect prune 2>&1 | grep -c 'snapshotTasks section did not answer')"
check "the key survives" '["snapshotTasks:4"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"

stale=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
jq --arg s "$stale" '.updatedAt = $s | .warnings = []' "$STATE" >"$WORK/s.json"
mv "$WORK/s.json" "$STATE"
check "a stale state is refused" 1 "$(ctl expect prune >/dev/null 2>&1; echo $?)"
check "the refusal names the age" 1 \
  "$(ctl expect prune 2>&1 | grep -c 'older than two polls')"

jq 'del(.snapshotTasks)' "$STATE" >"$WORK/s.json"
mv "$WORK/s.json" "$STATE"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg s "$now" '.updatedAt = $s' "$STATE" >"$WORK/s.json"
mv "$WORK/s.json" "$STATE"
check "an absent section is refused" 1 "$(ctl expect prune >/dev/null 2>&1; echo $?)"
check "the refusal names the absent section" 1 \
  "$(ctl expect prune 2>&1 | grep -c 'snapshotTasks section is not in the state')"
teardown

test_case "expect prune drops dead and junk keys from a fresh state"
setup
single_instance_config
jq '.expectOutput = ["replication:1","snapshotTasks:4","snapshotTasks:5","junk"]' \
  "$TRUENAS_CONFIG_FILE" >"$WORK/c.json"
mv "$WORK/c.json" "$TRUENAS_CONFIG_FILE"
mkdir -p "$(dirname "$STATE")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$STATE" <<JSON
{ "schema": 1, "updatedAt": "$now", "pollSeconds": 30,
  "connection": { "ok": true },
  "replication": [ { "id": 1 } ],
  "snapshotTasks": [ { "id": 5 } ],
  "warnings": [] }
JSON
out=$(ctl expect prune)
check "prune succeeds" 0 "$(ctl expect prune >/dev/null 2>&1; echo $?)"
check "only the live keys remain" '["replication:1","snapshotTasks:5"]' \
  "$(jq -c '.expectOutput' "$TRUENAS_CONFIG_FILE")"
check "the dead key is named" 1 "$(grep -c 'pruned snapshotTasks:4' <<<"$out")"
check "the junk key is named" 1 "$(grep -c 'pruned junk' <<<"$out")"
check "a second prune is a no-op" "nothing to prune" "$(ctl expect prune)"
teardown

test_case "config set-key replaces the credential and refuses an argument"
setup
printf 'fresh-key\n' | ctl config set-key >/dev/null
check "stored" 1 "$(grep -cx 'TRUENAS_API_KEY=fresh-key' "$TRUENAS_CREDENTIALS_FILE")"
check "still mode 600" 600 "$(stat -c '%a' "$TRUENAS_CREDENTIALS_FILE")"
check "a positional key is refused" 1 \
  "$(printf 'x\n' | ctl config set-key leaked >/dev/null 2>&1; echo $?)"
teardown

# ------------------------------------------------------------------- test
test_case "test names a self-signed certificate and the insecureTLS fix"
setup
plain_config
respond "/api/v2.0/system/info" 60 0 ""
out=$(ctl test 2>&1)
check "fails" 1 "$(ctl test >/dev/null 2>&1; echo $?)"
check "names insecureTLS" 1 "$(grep -c 'insecureTLS' <<<"$out")"
check "calls it self-signed" 1 "$(grep -ci 'self-signed' <<<"$out")"
check "does not claim unreachable" 0 "$(grep -c 'unreachable' <<<"$out")"
teardown

test_case "test separates a rejected key from no key at all"
setup
plain_config
respond "/api/v2.0/system/info" 0 401 "$ROOT/tests/fixtures/err-401.json"
out=$(ctl test 2>&1)
check "key rejected" 1 "$(grep -c 'key rejected' <<<"$out")"
rm -f "$TRUENAS_CREDENTIALS_FILE"
out=$(ctl test 2>&1)
check "no key is its own message" 1 "$(grep -c 'no API key is set' <<<"$out")"
check "and is not the rejection message" 0 "$(grep -c 'key rejected' <<<"$out")"
teardown

test_case "test names a credentials-permission problem rather than a missing key"
setup
plain_config
respond "/api/v2.0/system/info" 0 401 "$ROOT/tests/fixtures/err-401.json"
chmod 644 "$TRUENAS_CREDENTIALS_FILE"
out=$(ctl test 2>&1)
check "fails" 1 "$(ctl test >/dev/null 2>&1; echo $?)"
check "names the credentials file" 1 "$(grep -c "$TRUENAS_CREDENTIALS_FILE" <<<"$out")"
check "says it is readable by others" 1 "$(grep -c 'readable by others' <<<"$out")"
check "suggests chmod 600" 1 "$(grep -c 'chmod 600' <<<"$out")"
check "does not claim no key is set" 0 "$(grep -c 'no API key is set' <<<"$out")"
teardown

test_case "test names forbidden, not found and not JSON distinctly"
setup
plain_config
respond "/api/v2.0/system/info" 0 403 "$ROOT/tests/fixtures/err-500.json"
out=$(ctl test 2>&1)
check "forbidden (403)" 1 "$(grep -c 'forbidden (403)' <<<"$out")"
respond "/api/v2.0/system/info" 0 404 "$ROOT/tests/fixtures/err-500.json"
out=$(ctl test 2>&1)
check "not found (404)" 1 "$(grep -c 'not found (404)' <<<"$out")"
printf '<html><body>the dashboard</body></html>\n' >"$WORK/html"
respond "/api/v2.0/system/info" 0 200 "$WORK/html"
out=$(ctl test 2>&1)
check "a 200 HTML body is not JSON" 1 "$(grep -c 'not JSON' <<<"$out")"
teardown

test_case "test calls a timeout a timeout"
setup
plain_config
respond "/api/v2.0/system/info" 28 0 ""
out=$(ctl test 2>&1)
check "fails" 1 "$(ctl test >/dev/null 2>&1; echo $?)"
check "timed out" 1 "$(grep -c 'timed out' <<<"$out")"
teardown

test_case "test reports the base url, dialect and version on success"
setup
plain_config
respond "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
out=$(ctl test 2>&1)
check "succeeds" 0 "$(ctl test >/dev/null 2>&1; echo $?)"
check "names the base url" 1 "$(grep -c 'https://nas.example' <<<"$out")"
check "names the dialect" 1 "$(grep -c 'rest-v2.0' <<<"$out")"
check "prints the version" 1 "$(grep -c '25.04.2' <<<"$out")"
teardown

# ----------------------------------------------------------------- status
test_case "status on a missing state says so rather than printing zeros"
setup
rm -rf "$XDG_STATE_HOME"
out=$(ctl status 2>&1)
check "fails" 1 "$(ctl status >/dev/null 2>&1; echo $?)"
check "says there is no state" 1 "$(grep -ci 'no state' <<<"$out")"
check "and invents no alert count" 0 "$(grep -c 'alerts:' <<<"$out")"
teardown

test_case "status reports what the bar is showing"
setup
single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-mixed.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
out=$(ctl status)
check "connection ok" 1 "$(grep -c '^connection: ok' <<<"$out")"
check "the version" 1 "$(grep -c '25.04.2' <<<"$out")"
check "the pool count" "$(state '.pools | length')" \
  "$(sed -n 's/^pools: \([0-9]*\).*/\1/p' <<<"$out")"
check "the alert count" "$(state '.counts.total')" \
  "$(sed -n 's/^alerts: \([0-9]*\).*/\1/p' <<<"$out")"
teardown

test_case "alerts and pools read the state, not the NAS"
setup
single_instance_config
respond     "/api/v2.0/alert/list"  0 200 "$ROOT/tests/fixtures/alerts-mixed.json"
respond_add "/api/v2.0/pool"        0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
out=$(ctl alerts)
check "a CRITICAL line" 1 "$(grep -c '^CRITICAL  ' <<<"$out")"
check "the dismissed alert is not listed" 0 "$(grep -c 'sdb' <<<"$out")"
out=$(ctl pools)
check "storage with its capacity" 1 "$(grep -c 'storage.*ONLINE.*71' <<<"$out")"
teardown

test_case "status and alerts call an offline state unknown, not zero"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": false, "error": "unreachable", "message": "connection refused" },
  "system": null, "counts": null, "alerts": null, "pools": null, "warnings": [] }
JSON
out=$(ctl status)
check "status still runs" 0 "$(ctl status >/dev/null 2>&1; echo $?)"
check "pools are unknown" 1 "$(grep -c '^pools: unknown' <<<"$out")"
check "alerts are unknown" 1 "$(grep -c '^alerts: unknown' <<<"$out")"
check "the reason is named" 1 "$(grep -q 'connection refused' <<<"$out" && echo 1 || echo 0)"
check "no alert zero is printed" 0 "$(grep -c 'alerts: 0 active' <<<"$out")"
check "no pool zero is printed" 0 "$(grep -c '^pools: 0 ' <<<"$out")"
out=$(ctl alerts)
check "alerts says unknown" 1 "$(grep -c '^alerts unknown:' <<<"$out")"
check "alerts names the reason" 1 "$(grep -q 'connection refused' <<<"$out" && echo 1 || echo 0)"
check "alerts does not claim no active alerts" 0 "$(grep -c 'no active alerts' <<<"$out")"
teardown

test_case "alerts says a failed alert section did not answer"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [],
  "warnings": [ { "section": "alert", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl alerts)
check "says the section did not answer" 1 \
  "$(grep -c 'the alert section did not answer' <<<"$out")"
check "says unknown" 1 "$(grep -c '^alerts unknown:' <<<"$out")"
check "does not claim no active alerts" 0 "$(grep -c 'no active alerts' <<<"$out")"
out=$(ctl status)
check "status marks only the alert half unknown" 1 \
  "$(grep -c '^alerts: unknown' <<<"$out")"
check "status prints the pool count" 1 \
  "$(grep -c '^pools: 0 (worst none)' <<<"$out")"
teardown

# ------------------------------------------------------------------- disks
# `disks` reads state.json like `pools` does, but a temperature or a size the
# poller could not learn is a word, never a zero, and a failed disk section is
# its own sentence rather than an empty table.
test_case "disks prints one row per disk with its temperature, never a zero"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [],
  "disks": [
    { "name": "nvme0n1", "model": "NVMe_SSD_2T", "type": "SSD",
      "size": 2000398934016, "pool": "storage", "bus": "UNKNOWN",
      "tempC": 61.0, "tempCriticalC": 60.0, "tempState": "critical" },
    { "name": "sda", "model": "SATA_HDD_500G", "type": "HDD",
      "size": 500107862016, "pool": "boot-pool", "bus": "ATA",
      "tempC": 38.0, "tempCriticalC": 60.0, "tempState": "ok" },
    { "name": "sdb", "model": "SATA_HDD_500G", "type": "HDD",
      "size": 500107862016, "pool": "boot-pool", "bus": "ATA",
      "tempC": "n/a", "tempCriticalC": 60.0, "tempState": "unknown" },
    { "name": "sdc", "model": "SATA_HDD_4T", "type": "HDD",
      "size": null, "pool": "Backup", "bus": "ATA",
      "tempC": null, "tempCriticalC": null, "tempState": "unknown" }
  ],
  "warnings": [] }
JSON
out=$(ctl disks)
check "disks runs" 0 "$(ctl disks >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^NAME.*TYPE.*SIZE.*POOL.*TEMP' <<<"$out")"
check "one row per disk" 4 "$(grep -c '^\(nvme0n1\|sda\|sdb\|sdc\)' <<<"$out")"
check "a cool disk shows its rounded temperature" 1 \
  "$(grep -c '^sda.*38 °C' <<<"$out")"
check "the hot disk renders its temperature" 1 \
  "$(grep -c '^nvme0n1.*61 °C' <<<"$out")"
check "the pool is on the row" 1 \
  "$(grep -c '^sda.*boot-pool' <<<"$out")"
check "the size is human" 1 "$(grep -c '^sda.*465.8 GiB' <<<"$out")"
check "an unknown temperature is the word unknown" 1 \
  "$(grep -c '^sdc.*unknown' <<<"$out")"
check "a non-numeric temperature is the word unknown" 1 \
  "$(grep -c '^sdb.*unknown' <<<"$out")"
check "an unknown size is the word unknown" 1 \
  "$(grep -c '^sdc.*unknown.*unknown' <<<"$out")"
check "no invented zero temperature" 0 "$(grep -cE '(^| )0 °C' <<<"$out")"
check "no invented zero size" 0 "$(grep -cE '(^| )0 B' <<<"$out")"
teardown

test_case "disks names a failed disk section instead of an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [],
  "warnings": [ { "section": "disk", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl disks)
check "disks still runs" 0 "$(ctl disks >/dev/null 2>&1; echo $?)"
check "says unknown" 1 "$(grep -c '^disks unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the disk section did not answer' <<<"$out")"
check "does not draw a header over an empty table" 0 "$(grep -c '^NAME' <<<"$out")"
check "invents no temperature" 0 "$(grep -cE '(^| )0 °C' <<<"$out")"
teardown

test_case "disks trusts no row when the temperatures did not answer"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [],
  "disks": [
    { "name": "sda", "model": "SATA_HDD_500G", "type": "HDD",
      "size": 500107862016, "pool": "boot-pool", "bus": "ATA",
      "tempC": null, "tempCriticalC": null, "tempState": "unknown" }
  ],
  "warnings": [ { "section": "diskTemp", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl disks)
check "says unknown" 1 "$(grep -c '^disks unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the diskTemp section did not answer' <<<"$out")"
check "prints no rows it cannot vouch for" 0 "$(grep -c '^sda' <<<"$out")"
teardown

test_case "disks calls a failed normalize unknown"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [],
  "warnings": [ { "section": "normalize", "error": "parse", "message": "" } ] }
JSON
out=$(ctl disks)
check "says unknown" 1 "$(grep -c '^disks unknown:' <<<"$out")"
check "names the normalize failure" 1 \
  "$(grep -c 'the response could not be normalized' <<<"$out")"
teardown

# ------------------------------------------------------------ services/apps
# `services` and `apps` read state.json like `pools` and `disks`. A flag the
# poller did not learn is `unknown`, a version it did not learn is `unknown`, a
# name it did not learn is `unknown`, and a missing, non-array or failed section
# is its own sentence rather than an empty table.
test_case "services prints one row per service with yes or no enabled"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "apps": [],
  "services": [
    { "id": 4, "service": "cifs", "state": "RUNNING", "enable": true },
    { "id": 5, "service": "ftp",  "state": "STOPPED", "enable": false },
    { "id": 11, "service": "snmp", "state": "" },
    { "id": 12, "state": "STOPPED", "enable": false }
  ],
  "warnings": [] }
JSON
out=$(ctl services)
check "services runs" 0 "$(ctl services >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^SERVICE  STATE  ENABLED$' <<<"$out")"
check "one row per service" 4 "$(grep -c '^\(cifs\|ftp\|snmp\|unknown\) ' <<<"$out")"
check "a running enabled service is yes" 1 \
  "$(grep -c '^cifs  RUNNING  yes$' <<<"$out")"
check "a stopped disabled service is no" 1 \
  "$(grep -c '^ftp  STOPPED  no$' <<<"$out")"
check "a missing enable is unknown, not no" 1 \
  "$(grep -c '^snmp  .*  unknown$' <<<"$out")"
check "a missing service name is unknown" 1 \
  "$(grep -c '^unknown  STOPPED  no$' <<<"$out")"
check "no row invents yes for a missing enable" 0 "$(grep -c '^snmp.*yes' <<<"$out")"
teardown

test_case "apps prints name, state, version and update flag"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "services": [],
  "apps": [
    { "name": "appc", "title": "appc", "state": "RUNNING",
      "version": "16.0.4-rootless_1.2.39", "upgradeAvailable": false },
    { "name": "appb", "title": "appb", "state": "RUNNING",
      "version": "1.4.2", "upgradeAvailable": true },
    { "name": "appd", "title": "appd", "state": "STOPPED",
      "version": "", "upgradeAvailable": false },
    { "name": "ghost", "state": "RUNNING", "version": "2.0.0" },
    { "state": "STOPPED", "version": "3.1.0", "upgradeAvailable": false }
  ],
  "warnings": [] }
JSON
out=$(ctl apps)
check "apps runs" 0 "$(ctl apps >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^APP  STATE  VERSION  UPDATE$' <<<"$out")"
check "one row per app" 5 "$(grep -c '^\(appc\|appb\|appd\|ghost\|unknown\) ' <<<"$out")"
check "the APP column is the name" 1 "$(grep -c '^appc  RUNNING' <<<"$out")"
check "a known version is printed" 1 \
  "$(grep -c '^appc  RUNNING  16.0.4-rootless_1.2.39  no$' <<<"$out")"
check "an available update is yes" 1 \
  "$(grep -c '^appb  RUNNING  1.4.2  yes$' <<<"$out")"
check "a missing version is unknown" 1 \
  "$(grep -c '^appd  STOPPED  unknown  no$' <<<"$out")"
check "a missing upgradeAvailable is unknown, not no" 1 \
  "$(grep -c '^ghost  RUNNING  2.0.0  unknown$' <<<"$out")"
check "a missing app name is unknown" 1 \
  "$(grep -c '^unknown  STOPPED  3.1.0  no$' <<<"$out")"
check "no row invents an update" 0 "$(grep -c '^appc.*yes' <<<"$out")"
teardown

test_case "services and apps on an empty list print just the header"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "services": [], "apps": [],
  "warnings": [] }
JSON
out=$(ctl services)
check "services runs" 0 "$(ctl services >/dev/null 2>&1; echo $?)"
check "services is exactly the header" 1 "$(wc -l <<<"$out")"
check "services prints the header" 1 \
  "$(grep -c '^SERVICE  STATE  ENABLED$' <<<"$out")"
check "services invents no row" 0 "$(grep -c '^\(cifs\|ftp\|snmp\)' <<<"$out")"
out=$(ctl apps)
check "apps runs" 0 "$(ctl apps >/dev/null 2>&1; echo $?)"
check "apps is exactly the header" 1 "$(wc -l <<<"$out")"
check "apps prints the header" 1 \
  "$(grep -c '^APP  STATE  VERSION  UPDATE$' <<<"$out")"
teardown

test_case "services names a failed service section instead of an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "services": [], "apps": [],
  "warnings": [ { "section": "service", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl services)
check "services still runs" 0 "$(ctl services >/dev/null 2>&1; echo $?)"
check "says unknown" 1 "$(grep -c '^services unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the service section did not answer' <<<"$out")"
check "does not draw a header over an empty table" 0 "$(grep -c '^SERVICE' <<<"$out")"
out=$(ctl apps)
check "the app half is unaffected" 0 "$(grep -c '^apps unknown:' <<<"$out")"
check "apps still prints its header" 1 "$(grep -c '^APP  STATE' <<<"$out")"
teardown

test_case "apps names a failed app section instead of an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "services": [], "apps": [],
  "warnings": [ { "section": "app", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl apps)
check "apps still runs" 0 "$(ctl apps >/dev/null 2>&1; echo $?)"
check "says unknown" 1 "$(grep -c '^apps unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the app section did not answer' <<<"$out")"
check "does not draw a header over an empty table" 0 "$(grep -c '^APP' <<<"$out")"
out=$(ctl services)
check "the service half is unaffected" 0 "$(grep -c '^services unknown:' <<<"$out")"
check "services still prints its header" 1 "$(grep -c '^SERVICE  STATE' <<<"$out")"
teardown

test_case "services and apps call an absent key unknown, never an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [],
  "warnings": [] }
JSON
out=$(ctl services)
check "services runs" 0 "$(ctl services >/dev/null 2>&1; echo $?)"
check "services says unknown" 1 "$(grep -c '^services unknown:' <<<"$out")"
check "services names the absent section" 1 \
  "$(grep -c 'the service section did not answer' <<<"$out")"
check "services draws no header" 0 "$(grep -c '^SERVICE' <<<"$out")"
out=$(ctl apps)
check "apps runs" 0 "$(ctl apps >/dev/null 2>&1; echo $?)"
check "apps says unknown" 1 "$(grep -c '^apps unknown:' <<<"$out")"
check "apps names the absent section" 1 \
  "$(grep -c 'the app section did not answer' <<<"$out")"
check "apps draws no header" 0 "$(grep -c '^APP' <<<"$out")"
teardown

test_case "services and apps call a non-array section unknown, never a jq error"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "updatedAt": "2026-09-13T00:00:00Z", "pollSeconds": 30,
  "connection": { "ok": true, "error": null, "message": null },
  "system": { "hostname": "nas" },
  "counts": { "critical": 0, "error": 0, "warning": 0, "notice": 0, "info": 0, "total": 0 },
  "alerts": [], "pools": [], "disks": [], "services": {}, "apps": "not a list",
  "warnings": [] }
JSON
out=$(ctl services 2>&1)
check "services runs" 0 "$(ctl services >/dev/null 2>&1; echo $?)"
check "services says unknown" 1 "$(grep -c '^services unknown:' <<<"$out")"
check "services names the section" 1 \
  "$(grep -c 'the service section did not answer' <<<"$out")"
check "services prints no jq error" 0 "$(grep -ci 'jq: error' <<<"$out")"
check "services draws no header" 0 "$(grep -c '^SERVICE' <<<"$out")"
out=$(ctl apps 2>&1)
check "apps runs" 0 "$(ctl apps >/dev/null 2>&1; echo $?)"
check "apps says unknown" 1 "$(grep -c '^apps unknown:' <<<"$out")"
check "apps names the section" 1 \
  "$(grep -c 'the app section did not answer' <<<"$out")"
check "apps prints no jq error" 0 "$(grep -ci 'jq: error' <<<"$out")"
check "apps draws no header" 0 "$(grep -c '^APP' <<<"$out")"
teardown

# ------------------------------------------------------------ open and purge
test_case "open builds a url under the base and never launches a real browser"
setup
single_instance_config
cat >"$WORK/xdg-open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${XDG_OPEN_LOG:-/dev/null}"
SH
chmod +x "$WORK/xdg-open"
export XDG_OPEN_LOG="$WORK/opened.log"
: >"$XDG_OPEN_LOG"
export PATH="$WORK:$PATH"
wait_for_open() { local i=0; while [[ ! -s $XDG_OPEN_LOG && $i -lt 200 ]]; do sleep 0.02; i=$((i+1)); done; }
ctl open pools
wait_for_open
check "the pools page is under the configured base" \
  "https://nas.example:4433/ui/storage" "$(cat "$XDG_OPEN_LOG")"
: >"$XDG_OPEN_LOG"
ctl open
wait_for_open
check "a bare open goes to the dashboard" \
  "https://nas.example:4433/ui/dashboard" "$(cat "$XDG_OPEN_LOG")"
teardown

test_case "purge removes config, credentials and the state directory"
setup
single_instance_config
printf 'k\n' | ctl login https://nas.example >/dev/null 2>&1
mkdir -p "$XDG_STATE_HOME/omarchy/truenas"
printf '{}\n' >"$STATE"
printf 'yes\n' | ctl purge >/dev/null
check "config gone" 0 "$([[ -e $TRUENAS_CONFIG_FILE ]] && echo 1 || echo 0)"
check "credentials gone" 0 "$([[ -e $TRUENAS_CREDENTIALS_FILE ]] && echo 1 || echo 0)"
check "state directory gone" 0 "$([[ -d $XDG_STATE_HOME/omarchy/truenas ]] && echo 1 || echo 0)"
teardown

# --------------------------------------------------------------- protection
# The four protection tables read state.json, print `unknown` for a value the
# poller did not learn, and print the section's failure sentence rather than an
# empty table.
test_case "replication prints name, direction, state and last run"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "replication": [
    { "id": 1, "name": "storage-to-backup", "direction": "PUSH",
      "state": { "state": "FINISHED" },
      "job": { "state": "SUCCESS", "timeFinished": "2026-09-14T03:05:18Z" } },
    { "id": 2, "name": "backup-to-offsite", "direction": "PULL",
      "state": { "state": "PENDING" }, "job": null },
    { "id": 3, "name": "", "direction": "", "state": null, "job": null }
  ], "warnings": [] }
JSON
out=$(ctl replication)
check "replication runs" 0 "$(ctl replication >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^NAME  DIRECTION  STATE  LAST RUN$' <<<"$out")"
check "one row per task" 3 \
  "$(grep -c '^\(storage-to-backup\|backup-to-offsite\|unknown\) ' <<<"$out")"
check "the job state wins" 1 \
  "$(grep -c '^storage-to-backup  PUSH  SUCCESS  2026-09-14T03:05:18Z$' <<<"$out")"
check "the task state is the fallback" 1 \
  "$(grep -c '^backup-to-offsite  PULL  PENDING  unknown$' <<<"$out")"
check "a blank row is unknown, never blank" 1 \
  "$(grep -c '^unknown  unknown  unknown  unknown$' <<<"$out")"
teardown

test_case "cloudsync prints name, direction, state and last run"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "cloudSync": [
    { "id": 3, "name": "clouda", "direction": "PUSH",
      "job": { "state": "SUCCESS", "timeFinished": "2026-09-14T02:00:00Z" } },
    { "id": 4, "name": "b2", "direction": "PULL", "job": null }
  ], "warnings": [] }
JSON
out=$(ctl cloudsync)
check "cloudsync runs" 0 "$(ctl cloudsync >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^NAME  DIRECTION  STATE  LAST RUN$' <<<"$out")"
check "a successful job shows its state and finish" 1 \
  "$(grep -c '^clouda  PUSH  SUCCESS  2026-09-14T02:00:00Z$' <<<"$out")"
check "a jobless task is unknown" 1 \
  "$(grep -c '^b2  PULL  unknown  unknown$' <<<"$out")"
teardown

test_case "snapshots prints dataset, state and last snapshot"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "snapshotTasks": [
    { "id": 1, "dataset": "storage",
      "state": { "state": "FINISHED", "lastSnapshot": "storage@auto-hourly-1" } },
    { "id": 6, "dataset": "Backup",
      "state": { "state": "PENDING", "lastSnapshot": null } },
    { "id": 7, "dataset": "", "state": null }
  ], "warnings": [] }
JSON
out=$(ctl snapshots)
check "snapshots runs" 0 "$(ctl snapshots >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^DATASET  STATE  LAST SNAPSHOT$' <<<"$out")"
check "a finished task shows its snapshot" 1 \
  "$(grep -c '^storage  FINISHED  storage@auto-hourly-1$' <<<"$out")"
check "a pending task has no snapshot, never a blank" 1 \
  "$(grep -c '^Backup  PENDING  unknown$' <<<"$out")"
check "a blank row is unknown" 1 \
  "$(grep -c '^unknown  unknown  unknown$' <<<"$out")"
teardown

test_case "scrubs prints pool, enabled, threshold and schedule"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "scrubs": [
    { "id": 1, "pool": "storage", "threshold": 35, "enabled": true,
      "schedule": { "minute": "00", "hour": "00", "dow": "7" } },
    { "id": 2, "pool": "Backup", "threshold": 35, "enabled": false,
      "schedule": null }
  ], "warnings": [] }
JSON
out=$(ctl scrubs)
check "scrubs runs" 0 "$(ctl scrubs >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^POOL  ENABLED  THRESHOLD  SCHEDULE$' <<<"$out")"
check "an enabled task shows yes and its schedule" 1 \
  "$(grep -c '^storage  yes  35  7 00 00$' <<<"$out")"
check "a disabled task shows no and an unknown schedule" 1 \
  "$(grep -c '^Backup  no  35  unknown$' <<<"$out")"
teardown

test_case "protection verbs on an empty list print just the header"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "replication": [], "cloudSync": [], "snapshotTasks": [], "scrubs": [],
  "warnings": [] }
JSON
out=$(ctl replication)
check "replication is exactly the header" 1 "$(wc -l <<<"$out")"
check "replication prints the header" 1 \
  "$(grep -c '^NAME  DIRECTION  STATE  LAST RUN$' <<<"$out")"
out=$(ctl cloudsync)
check "cloudsync is exactly the header" 1 "$(wc -l <<<"$out")"
out=$(ctl snapshots)
check "snapshots is exactly the header" 1 "$(wc -l <<<"$out")"
check "snapshots prints the header" 1 \
  "$(grep -c '^DATASET  STATE  LAST SNAPSHOT$' <<<"$out")"
out=$(ctl scrubs)
check "scrubs is exactly the header" 1 "$(wc -l <<<"$out")"
check "scrubs prints the header" 1 \
  "$(grep -c '^POOL  ENABLED  THRESHOLD  SCHEDULE$' <<<"$out")"
teardown

test_case "protection verbs name a failed section instead of an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "replication": [], "cloudSync": [], "snapshotTasks": [], "scrubs": [],
  "warnings": [ { "section": "replication", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl replication)
check "replication still runs" 0 "$(ctl replication >/dev/null 2>&1; echo $?)"
check "says unknown" 1 "$(grep -c '^replication unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the replication section did not answer' <<<"$out")"
check "draws no header over an empty table" 0 "$(grep -c '^NAME' <<<"$out")"
out=$(ctl cloudsync)
check "the cloud sync half is unaffected" 1 \
  "$(grep -c '^NAME  DIRECTION  STATE  LAST RUN$' <<<"$out")"
teardown

test_case "protection verbs call an absent section unknown, never an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true }, "warnings": [] }
JSON
out=$(ctl snapshots)
check "snapshots runs" 0 "$(ctl snapshots >/dev/null 2>&1; echo $?)"
check "snapshots says unknown" 1 "$(grep -c '^snapshots unknown:' <<<"$out")"
check "snapshots names the absent section" 1 \
  "$(grep -c 'the snapshotTasks section did not answer' <<<"$out")"
check "snapshots draws no header" 0 "$(grep -c '^DATASET' <<<"$out")"
out=$(ctl scrubs 2>&1)
check "scrubs runs" 0 "$(ctl scrubs >/dev/null 2>&1; echo $?)"
check "scrubs says unknown" 1 "$(grep -c '^scrubs unknown:' <<<"$out")"
check "scrubs prints no jq error" 0 "$(grep -ci 'jq: error' <<<"$out")"
teardown

test_case "shares prints one row per share, grouped by type"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "shares": {
    "smb": [
      { "id": 1, "name": "default", "path": "/mnt/storage/default",
        "enabled": true, "readonly": false },
      { "id": 2, "name": "media", "path": "/mnt/storage/plex",
        "enabled": false, "readonly": true }
    ],
    "nfs": [
      { "id": 1, "path": "/mnt/storage/default", "enabled": true, "readonly": false }
    ],
    "iscsi": [ { "id": 1, "name": "iqn.2005-10.org.freenas.ctl:target0" } ]
  },
  "warnings": [] }
JSON
out=$(ctl shares)
check "shares runs" 0 "$(ctl shares >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^TYPE  NAME  PATH  ENABLED  RO$' <<<"$out")"
check "one row per share" 4 \
  "$(grep -c '^\(smb\|nfs\|iscsi\)  ' <<<"$out")"
check "an enabled writable SMB share is yes no" 1 \
  "$(grep -c '^smb  default  /mnt/storage/default  yes  no$' <<<"$out")"
check "a disabled read-only SMB share is no yes" 1 \
  "$(grep -c '^smb  media  /mnt/storage/plex  no  yes$' <<<"$out")"
check "NFS has no name, so that cell is a dash" 1 \
  "$(grep -c '^nfs  -  /mnt/storage/default  yes  no$' <<<"$out")"
check "iSCSI has no path or flags, so those cells are dashes" 1 \
  "$(grep -c '^iscsi  iqn.2005-10.org.freenas.ctl:target0  -  -  -$' <<<"$out")"
teardown

test_case "shares names a failed type instead of printing its rows"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "shares": {
    "smb": [ { "id": 1, "name": "default", "path": "/mnt/storage/default",
               "enabled": true, "readonly": false } ],
    "nfs": [ { "id": 1, "path": "/mnt/storage/default", "enabled": true, "readonly": false } ],
    "iscsi": [ { "id": 1, "name": "iqn.2005-10.org.freenas.ctl:target0" } ]
  },
  "warnings": [ { "section": "smb", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl shares)
check "shares still runs" 0 "$(ctl shares >/dev/null 2>&1; echo $?)"
check "says the smb type is unknown" 1 \
  "$(grep -c '^smb shares unknown: the smb section did not answer$' <<<"$out")"
check "the smb rows are omitted" 0 "$(grep -c '^smb  ' <<<"$out")"
check "the header still prints" 1 "$(grep -c '^TYPE  NAME' <<<"$out")"
check "the NFS rows still print" 1 "$(grep -c '^nfs  ' <<<"$out")"
check "the iSCSI rows still print" 1 "$(grep -c '^iscsi  ' <<<"$out")"
teardown

test_case "shares calls an absent shares object unknown for every type"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true }, "warnings": [] }
JSON
out=$(ctl shares 2>&1)
check "shares runs" 0 "$(ctl shares >/dev/null 2>&1; echo $?)"
check "smb is named" 1 \
  "$(grep -c '^smb shares unknown: the smb section did not answer$' <<<"$out")"
check "nfs is named" 1 \
  "$(grep -c '^nfs shares unknown: the nfs section did not answer$' <<<"$out")"
check "iscsi is named" 1 \
  "$(grep -c '^iscsi shares unknown: the iscsi section did not answer$' <<<"$out")"
check "the header still prints" 1 "$(grep -c '^TYPE  NAME' <<<"$out")"
check "no data row is invented" 0 "$(grep -c '^\(smb\|nfs\|iscsi\)  [a-z-]' <<<"$out")"
check "shares prints no jq error" 0 "$(grep -ci 'jq: error' <<<"$out")"
teardown

test_case "network prints interface link, media and addresses"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true },
  "network": [
    { "name": "enp4s0", "type": "PHYSICAL", "linkState": "LINK_STATE_UP",
      "mediaType": "Ethernet", "mediaSubtype": "1000Mb/s Twisted Pair",
      "addresses": [ { "type": "INET", "address": "192.0.2.10", "netmask": 24 },
                     { "type": "INET6", "address": "2001:db8::10", "netmask": 64 } ] },
    { "name": "br0", "type": "BRIDGE", "linkState": "LINK_STATE_DOWN",
      "mediaType": "Ethernet", "mediaSubtype": "", "addresses": [] }
  ],
  "warnings": [] }
JSON
out=$(ctl network)
check "network runs" 0 "$(ctl network >/dev/null 2>&1; echo $?)"
check "the header names every column" 1 \
  "$(grep -c '^NAME  TYPE  LINK  MEDIA  ADDRESSES$' <<<"$out")"
check "an up interface prints its negotiated media and addresses" 1 \
  "$(grep -c '^enp4s0  PHYSICAL  up  1000Mb/s Twisted Pair  192.0.2.10/24,2001:db8::10/64$' <<<"$out")"
check "a down interface falls back to the media type" 1 \
  "$(grep -c '^br0  BRIDGE  down  Ethernet  -$' <<<"$out")"
teardown

test_case "network names a failed interface section instead of an empty table"
setup
mkdir -p "$(dirname "$STATE")"
cat >"$STATE" <<'JSON'
{ "schema": 1, "connection": { "ok": true }, "network": [],
  "warnings": [ { "section": "network", "error": "timeout", "message": "" } ] }
JSON
out=$(ctl network)
check "network still runs" 0 "$(ctl network >/dev/null 2>&1; echo $?)"
check "says unknown" 1 "$(grep -c '^network unknown:' <<<"$out")"
check "names the failed section" 1 \
  "$(grep -c 'the network section did not answer' <<<"$out")"
check "draws no header over an empty table" 0 "$(grep -c '^NAME' <<<"$out")"
teardown

# ------------------------------------------------------- control sequences
# Alert text, pool names, hostnames and error messages are all shaped by whoever
# controls the NAS, and `jq -r` decodes a `\u001b` back into a real ESC byte. A
# terminal that receives one can be made to rewrite its title, overwrite the
# clipboard (OSC 52) or spoof output. The state every read verb prints is
# stripped of C0 control bytes at the one gate it passes through, and the live
# body `test` prints is stripped on the way out.
test_case "control sequences off the wire never reach the terminal"
setup
single_instance_config
cat >"$WORK/alerts-esc.json" <<'JSON'
[ { "uuid": "esc-1", "source": "ZFS", "klass": "PoolStatus",
    "args": { "pool": "storage" },
    "datetime": { "$date": 1787322480000 },
    "dismissed": false,
    "text": "beacon \u001b]52;c;cGF5bG9hZA==\u0007 here",
    "formatted": "beacon \u001b]52;c;cGF5bG9hZA==\u0007 here",
    "level": "CRITICAL", "dismissable": true } ]
JSON
cat >"$WORK/pools-esc.json" <<'JSON'
[ { "name": "storage\u001b[2J", "status": "ONLINE", "size": 100, "allocated": 10,
    "healthy": true } ]
JSON
cat >"$WORK/system-esc.json" <<'JSON'
{ "version": "25.04.2\u001b[2J", "hostname": "nas\u001b]0;pwned\u0007",
  "uptime_seconds": 1, "cores": 1, "physmem": 1, "loadavg": [0, 0, 0] }
JSON
respond     "/api/v2.0/alert/list"  0 200 "$WORK/alerts-esc.json"
respond_add "/api/v2.0/pool"        0 200 "$WORK/pools-esc.json"
respond_add "/api/v2.0/system/info" 0 200 "$WORK/system-esc.json"
poll
check "state.json carries no ESC" 0 "$(grep -c $'\x1b' "$STATE")"
check "the alert text survives without the sequence" 1 \
  "$(ctl alerts | grep -c 'beacon .* here')"
check "alerts prints no ESC" 0 "$(ctl alerts | grep -c $'\x1b' || true)"
check "pools prints no ESC" 0 "$(ctl pools | grep -c $'\x1b' || true)"
out=$(ctl test 2>&1)
check "test succeeds against the body" 0 "$(ctl test >/dev/null 2>&1; echo $?)"
check "test prints no ESC from a live body" 0 "$(grep -c $'\x1b' <<<"$out" || true)"
teardown
