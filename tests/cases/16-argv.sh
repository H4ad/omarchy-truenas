# shellcheck shell=bash
# Task 16: no NAS data on a child process command line.
#
# Every argv word this plugin hands to a child is readable by every local user
# through /proc/<pid>/cmdline on an ordinary procfs. So the documents that carry
# NAS text (the payload, the seen history, the meta cache, the warnings list and
# the connection error) reach jq through --slurpfile, --rawfile or stdin, and a
# toast carries only constants, counts and whitelisted state words.
#
# The first case drives one poll that fires every kind of notification at once,
# with fixtures the markers below come from, and then greps both command lines
# for them. The second puts a path in a state field the wire carries as text, to
# prove the toast whitelists it instead of echoing it. A marker found in either
# log is the leak back.

MARKERS=(
  'One or more devices is offline'   # alert text
  'Controller A'                     # alert node
  'storage'                          # pool name
  'storage-to-backup'                # replication task name
  'send failed'                      # replication job error
  'clouda'                           # cloud sync task description
  'quota exceeded'                   # cloud sync job error
  'cifs'                             # service name
  'appc'                             # app name
  'sda'                              # disk name
  '25.04.2'                          # NAS version
  '/mnt/private'                     # a path, used as a state field in case 2
)

# Every marker found in one log, one per line, so a failure names the value that
# leaked instead of saying only that something did.
marker_hits() {
  local log=$1 marker
  for marker in "${MARKERS[@]}"; do
    grep -qF -- "$marker" "$log" && printf '%s\n' "$marker"
  done
  return 0
}

# A jq first on PATH that records every argument vector it is handed and then
# execs the real jq, so a poll under this PATH behaves normally and what jq saw
# is a fact in a log rather than something a case has to infer. setup() makes a
# fresh $WORK, so each case calls this after its own setup.
argv_probe() {
  export STUB_JQ_ARGV_LOG="$WORK/jq-argv.log"
  : >"$STUB_JQ_ARGV_LOG"
  cat >"$WORK/jq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_JQ_ARGV_LOG"
exec /usr/bin/jq "$@"
SH
  chmod +x "$WORK/jq"
}

test_case "no NAS value reaches a child process command line"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
argv_probe

# A quiet baseline first: pool, disk, service, app or task toasts only fire on a
# transition, and the seen file the baseline writes is what the marked poll is
# read against.
rep_job 1 SUCCESS "" "$WORK/rep-success.json"
cs_job SUCCESS "" "$WORK/cs-success.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" \
  "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" \
  "$ROOT/tests/fixtures/services.json" \
  "$ROOT/tests/fixtures/apps.json" \
  "$WORK/rep-success.json" "$WORK/cs-success.json"
: >"$STUB_JQ_ARGV_LOG"
PATH="$WORK:$PATH" poll
check "the baseline is quiet" 0 "$(notifications)"
check "and the baseline leaks nothing either" "" "$(marker_hits "$STUB_JQ_ARGV_LOG")"

# Everything goes wrong in one poll: a critical alert, a degraded pool, two hot
# disks, a stopped service, a crashed app and a failed job on each protection
# kind.
down_service cifs STOPPED "$WORK/services-cifs-stopped.json"
down_app appc CRASHED "$WORK/apps-appc-crashed.json"
rep_job 1 FAILED "send failed" "$WORK/rep-failed.json"
cs_job FAILED "quota exceeded" "$WORK/cs-failed.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-critical.json" \
  "$ROOT/tests/fixtures/pools-degraded.json" \
  "$ROOT/tests/fixtures/disk-temperatures-hot.json" \
  "$WORK/services-cifs-stopped.json" \
  "$WORK/apps-appc-crashed.json" \
  "$WORK/rep-failed.json" "$WORK/cs-failed.json"
: >"$STUB_JQ_ARGV_LOG"
PATH="$WORK:$PATH" poll

check "the jq wrapper really ran the poll" yes \
  "$(grep -q -- '--slurpfile' "$STUB_JQ_ARGV_LOG" && printf yes || printf no)"
check "the alert fired" 1 "$(grep -c 'New critical alert' "$STUB_NOTIFY_LOG" || true)"
check "the pool went DEGRADED" 1 "$(grep -c 'A pool is DEGRADED' "$STUB_NOTIFY_LOG" || true)"
check "the hot disks fired" 2 "$(grep -c 'A disk is hot' "$STUB_NOTIFY_LOG" || true)"
check "the service stopped" 1 "$(grep -c 'A service is STOPPED' "$STUB_NOTIFY_LOG" || true)"
check "the app crashed" 1 "$(grep -c 'An app is CRASHED' "$STUB_NOTIFY_LOG" || true)"
check "replication failed" 1 "$(grep -c 'Replication failed' "$STUB_NOTIFY_LOG" || true)"
check "cloud sync failed" 1 "$(grep -c 'Cloud sync failed' "$STUB_NOTIFY_LOG" || true)"
# The markers have to be live data, not just strings in a fixture: the state
# file, which is the panel's copy, still carries the node and version that the
# two argv greps below are looking for.
holds() { grep -qF -- "$1" "$STATE" && printf yes || printf no; }
check "the alert node is live in the state file" yes "$(holds 'Controller A')"
check "and so is the NAS version" yes "$(holds '25.04.2')"
check "no NAS value is on a jq command line" "" "$(marker_hits "$STUB_JQ_ARGV_LOG")"
check "no NAS value is on a notification command line" "" "$(marker_hits "$STUB_NOTIFY_LOG")"
teardown

test_case "a state field is whitelisted, not echoed into a toast"
setup; single_instance_config '{"metaMaxAgeSeconds":0}'
argv_probe

# The service is RUNNING in the baseline, then reports a path where a state
# belongs. The wire field is the NAS's to fill with text, so the toast must map
# it rather than repeat it.
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" \
  "$ROOT/tests/fixtures/pools-healthy.json"
: >"$STUB_JQ_ARGV_LOG"
PATH="$WORK:$PATH" poll
check "the baseline is quiet" 0 "$(notifications)"

down_service cifs '/mnt/private/report' "$WORK/services-state-text.json"
notify_endpoints "$ROOT/tests/fixtures/alerts-empty.json" \
  "$ROOT/tests/fixtures/pools-healthy.json" \
  "$ROOT/tests/fixtures/disk-temperatures.json" \
  "$WORK/services-state-text.json"
: >"$STUB_JQ_ARGV_LOG"
PATH="$WORK:$PATH" poll

check "the state change toasts" 1 "$(notifications)"
check "with the whitelisted word" 1 \
  "$(grep -c 'A service is not RUNNING' "$STUB_NOTIFY_LOG" || true)"
check "and the wire text stays in the state file" yes \
  "$(grep -qF -- '/mnt/private/report' "$STATE" && printf yes || printf no)"
check "no NAS value is on a jq command line" "" "$(marker_hits "$STUB_JQ_ARGV_LOG")"
check "no NAS value is on a notification command line" "" "$(marker_hits "$STUB_NOTIFY_LOG")"
teardown
