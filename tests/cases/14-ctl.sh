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
ctl config set pollSeconds 60 >/dev/null
check "pollSeconds set" 60 "$(jq -r '.pollSeconds' "$TRUENAS_CONFIG_FILE")"
check "a non-number pollSeconds is refused" 1 \
  "$(ctl config set pollSeconds soon >/dev/null 2>&1; echo $?)"
check "an unknown key is refused" 1 \
  "$(ctl config set bananas 1 >/dev/null 2>&1; echo $?)"
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
