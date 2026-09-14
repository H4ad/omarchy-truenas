# shellcheck shell=bash
# Task 16: bin/truenas-api. The alert, service and app writes the view can
# make, and the proof that the key travels the way it does everywhere else: on
# stdin to curl, never in argv, and so never in the method, payload or request
# logs. The stub curls are in tests/stubs/curl; `api` is defined in tests/lib.sh.

alert_uuid="11111111-2222-3333-4444-555555555555"

# A distinctive key, so a leak is unmistakable in any of the three logs.
secret_key="super-secret-key-xyz"

test_case "dismiss sends one POST with the uuid in the body"
setup; single_instance_config
printf 'TRUENAS_API_KEY=%s\n' "$secret_key" >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
respond "/api/v2.0/alert/dismiss" 0 200 /dev/null
out=$(api dismiss "$alert_uuid")
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the body carries the uuid" 1 "$(grep -c "$alert_uuid" "$STUB_PAYLOAD_LOG")"
check "the body is one uuid object" "$alert_uuid" \
  "$(jq -r '.uuid' "$STUB_PAYLOAD_LOG")"
check "the body is one key" uuid "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
check "the dismiss path was requested" 1 \
  "$(grep -c '/api/v2.0/alert/dismiss' "$STUB_CURL_LOG")"
teardown

# The dismiss route answers a 2xx with the JSON `null` body on success. That is
# not the boolean `false`, so it stays a landed write and never action_failed.
test_case "dismiss with a 2xx null body succeeds and is not action_failed"
setup; single_instance_config
printf 'null\n' >"$WORK/dismiss-null.json"
respond "/api/v2.0/alert/dismiss" 0 200 "$WORK/dismiss-null.json"
out=$(api dismiss "$alert_uuid")
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "is not action_failed" "" "$(jq -r '.error // ""' <<<"$out")"
teardown

test_case "a 400 answers {error, message} and exits non-zero"
setup; single_instance_config
respond "/api/v2.0/alert/dismiss" 0 400 "$ROOT/tests/fixtures/err-500.json"
out=$(api dismiss "$alert_uuid")
rc=$?
check "exit non-zero" 1 "$rc"
check "names the error" internal_error "$(jq -r '.error' <<<"$out")"
check "carries the NAS message" "internal server error" "$(jq -r '.message' <<<"$out")"
teardown

test_case "the key never reaches the method, payload or request logs"
setup; single_instance_config
printf 'TRUENAS_API_KEY=%s\n' "$secret_key" >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
respond "/api/v2.0/alert/dismiss" 0 200 /dev/null
api dismiss "$alert_uuid" >/dev/null 2>&1
check "not in the method log" 0 "$(grep -c "$secret_key" "$STUB_METHOD_LOG")"
check "not in the payload log" 0 "$(grep -c "$secret_key" "$STUB_PAYLOAD_LOG")"
check "not in the curl log" 0 "$(grep -c "$secret_key" "$STUB_CURL_LOG")"
teardown

test_case "a missing key is named no_key without a request"
setup; single_instance_config
rm -f "$TRUENAS_CREDENTIALS_FILE"
out=$(api dismiss "$alert_uuid")
rc=$?
check "exit non-zero" 1 "$rc"
check "error is no_key" no_key "$(jq -r '.error' <<<"$out")"
check "no request was sent" 0 "$(grep -c '/api/v2.0/alert/' "$STUB_CURL_LOG")"
teardown

test_case "restore hits the restore path with the uuid"
setup; single_instance_config
respond "/api/v2.0/alert/restore" 0 200 /dev/null
out=$(api restore "$alert_uuid")
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the restore path was requested" 1 \
  "$(grep -c '/api/v2.0/alert/restore' "$STUB_CURL_LOG")"
check "the dismiss path was not" 0 "$(grep -c '/api/v2.0/alert/dismiss' "$STUB_CURL_LOG")"
check "the body carries the uuid" 1 "$(grep -c "$alert_uuid" "$STUB_PAYLOAD_LOG")"
check "the body is one key" uuid "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

test_case "an unknown verb is a usage error with status 2"
setup
out=$(api nonsense "$alert_uuid" 2>&1)
rc=$?
check "exit 2" 2 "$rc"
check "usage on stderr" 1 "$(grep -c 'truenas-api <verb>' <<<"$out")"
teardown

# The six service/app control verbs. Each one posts a single name to one exact
# route; the NAS answers `true` synchronously for a service and a job id for an
# app, and both are a 2xx, so the caller sees the same {"ok":true} either way.
api_base="https://nas.example:4433"

# The NAS answers a service write with `true` (synchronous), so this one pins the
# JSON-2xx branch: the body is neither empty nor an object, and still success.
test_case "service-start posts the service name to the start route"
setup; single_instance_config
printf 'true\n' >"$WORK/service-true.json"
respond "/api/v2.0/service/start" 0 200 "$WORK/service-true.json"
out=$(api service-start cifs)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/service/start" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is service" cifs "$(jq -r '.service' "$STUB_PAYLOAD_LOG")"
check "the body is one key" service "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

# The NAS can accept the request with a 2xx and still answer the JSON boolean
# `false`, which means the service did not change. That is a failed action, not a
# landed write, so the verb fails with action_failed and does not echo the body.
test_case "service-start with a 2xx body false is a failed action"
setup; single_instance_config
printf 'false\n' >"$WORK/service-false.json"
respond "/api/v2.0/service/start" 0 200 "$WORK/service-false.json"
out=$(api service-start ups)
rc=$?
check "exit non-zero" 1 "$rc"
check "names the error" action_failed "$(jq -r '.error' <<<"$out")"
check "explains the action did not take effect" \
  "the NAS reported the action did not take effect" "$(jq -r '.message' <<<"$out")"
check "does not print the raw body" 0 "$(grep -c '^false$' <<<"$out")"
teardown

test_case "service-stop posts the service name to the stop route"
setup; single_instance_config
respond "/api/v2.0/service/stop" 0 200 /dev/null
out=$(api service-stop cifs)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/service/stop" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is service" cifs "$(jq -r '.service' "$STUB_PAYLOAD_LOG")"
check "the body is one key" service "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

test_case "service-restart posts the service name to the restart route"
setup; single_instance_config
respond "/api/v2.0/service/restart" 0 200 /dev/null
out=$(api service-restart cifs)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/service/restart" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is service" cifs "$(jq -r '.service' "$STUB_PAYLOAD_LOG")"
check "the body is one key" service "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

# An app write answers a job id number (asynchronous). Same JSON-2xx branch.
test_case "app-start posts app_name to the app start route"
setup; single_instance_config
printf '12345\n' >"$WORK/app-job.json"
respond "/api/v2.0/app/start" 0 200 "$WORK/app-job.json"
out=$(api app-start appc)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/app/start" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is app_name" appc "$(jq -r '.app_name' "$STUB_PAYLOAD_LOG")"
check "the body is one key" app_name "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

test_case "app-stop posts app_name to the app stop route"
setup; single_instance_config
respond "/api/v2.0/app/stop" 0 200 /dev/null
out=$(api app-stop appc)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/app/stop" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is app_name" appc "$(jq -r '.app_name' "$STUB_PAYLOAD_LOG")"
check "the body is one key" app_name "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

test_case "app-redeploy posts app_name to the redeploy route"
setup; single_instance_config
respond "/api/v2.0/app/redeploy" 0 200 /dev/null
out=$(api app-redeploy appc)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/app/redeploy" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body key is app_name" appc "$(jq -r '.app_name' "$STUB_PAYLOAD_LOG")"
check "the body is one key" app_name "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

# The NAS answers an unknown service with the name as a top-level message, not
# under .error, which is the shape the shared reader does not know about. The
# verb still has to carry it, or the panel shows a silent failure.
test_case "a 404 for an unknown service carries the NAS message"
setup; single_instance_config
printf '{"message":"nosuchservice"}\n' >"$WORK/notfound.json"
respond "/api/v2.0/service/restart" 0 404 "$WORK/notfound.json"
out=$(api service-restart nosuchservice)
rc=$?
check "exit non-zero" 1 "$rc"
check "names the error" not_found "$(jq -r '.error' <<<"$out")"
check "carries the NAS message" nosuchservice "$(jq -r '.message' <<<"$out")"
teardown

test_case "a missing argument is a usage error with status 2"
setup
out=$(api service-start 2>&1)
rc=$?
check "exit 2" 2 "$rc"
check "names the missing argument" 1 \
  "$(grep -c 'a service-start needs a service name' <<<"$out")"
check "usage on stderr" 1 "$(grep -c 'truenas-api <verb>' <<<"$out")"
teardown

test_case "an extra positional is a usage error with status 2"
setup
out=$(api service-start cifs extra 2>&1)
rc=$?
check "exit 2" 2 "$rc"
check "explains the extra argument" 1 "$(grep -c 'takes one argument' <<<"$out")"
check "usage on stderr" 1 "$(grep -c 'truenas-api <verb>' <<<"$out")"
teardown

# The usage list and the dispatch table are two places the same eight verbs
# live. This fails if a verb is documented and never dispatched.
test_case "every verb in the usage text is dispatched by the case"
setup
known=$(api 2>&1)
for verb_name in $(printf '%s\n' "$known" | sed -n 's/^  \([a-z][a-z-]*\) <.*/\1/p'); do
  api "$verb_name" placeholder >/dev/null 2>&1
  rc=$?
  check "$verb_name is dispatched" 1 "$(( rc == 2 ? 0 : 1 ))"
done
teardown

# A 2xx is not success on its own: a route that does not exist answers 200 with
# the frontend's HTML, and calling that a landed write is the one lie that
# matters. It stays a failure.
test_case "a 2xx with a non-JSON body is a failure, not a silent ok"
setup; single_instance_config
printf '<html></html>\n' >"$WORK/notjson.html"
respond "/api/v2.0/service/start" 0 200 "$WORK/notjson.html"
out=$(api service-start cifs)
rc=$?
check "exit non-zero" 1 "$rc"
check "names the error" not_json "$(jq -r '.error' <<<"$out")"
teardown

test_case "the key never reaches the logs for a service or app write"
setup; single_instance_config
printf 'TRUENAS_API_KEY=%s\n' "$secret_key" >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
respond "/api/v2.0/service/start" 0 200 /dev/null
api service-start cifs >/dev/null 2>&1
respond "/api/v2.0/app/redeploy" 0 200 /dev/null
api app-redeploy appc >/dev/null 2>&1
check "not in the method log" 0 "$(grep -c "$secret_key" "$STUB_METHOD_LOG")"
check "not in the payload log" 0 "$(grep -c "$secret_key" "$STUB_PAYLOAD_LOG")"
check "not in the curl log" 0 "$(grep -c "$secret_key" "$STUB_CURL_LOG")"
teardown

# The four protection run verbs. replication-run needs the bare integer body the
# route expects, not the one-key object; cloudsync-sync and snapshot-run carry
# the id in the path and send no body; scrub-start sends a name and an action.
test_case "replication-run posts the bare integer id"
setup; single_instance_config
printf '1077\n' >"$WORK/job.json"
respond "/api/v2.0/replication/run" 0 200 "$WORK/job.json"
out=$(api replication-run 1)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/replication/run" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body is the bare integer, not an object" 1 "$(jq -r '.' "$STUB_PAYLOAD_LOG")"
check "the body is a number" number "$(jq -r '. | type' "$STUB_PAYLOAD_LOG")"
teardown

test_case "cloudsync-sync puts the id in the path and sends no body"
setup; single_instance_config
printf '1078\n' >"$WORK/job.json"
respond "/api/v2.0/cloudsync/id/7/sync" 0 200 "$WORK/job.json"
out=$(api cloudsync-sync 7)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the method was POST" 1 "$(grep -c 'POST' "$STUB_METHOD_LOG")"
check "the exact route" "$api_base/api/v2.0/cloudsync/id/7/sync" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "no body was sent" 0 "$(wc -c <"$STUB_PAYLOAD_LOG")"
teardown

test_case "snapshot-run puts the id in the path and accepts a null body"
setup; single_instance_config
printf 'null\n' >"$WORK/snap-null.json"
respond "/api/v2.0/pool/snapshottask/id/6/run" 0 200 "$WORK/snap-null.json"
out=$(api snapshot-run 6)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the exact route" "$api_base/api/v2.0/pool/snapshottask/id/6/run" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "no body was sent" 0 "$(wc -c <"$STUB_PAYLOAD_LOG")"
check "a null body is not action_failed" "" "$(jq -r '.error // ""' <<<"$out")"
teardown

test_case "scrub-start posts the pool name and the START action"
setup; single_instance_config
printf '1083\n' >"$WORK/job.json"
respond "/api/v2.0/pool/scrub/scrub" 0 200 "$WORK/job.json"
out=$(api scrub-start storage)
rc=$?
check "exit ok" 0 "$rc"
check "answers ok" true "$(jq -r '.ok' <<<"$out")"
check "the exact route" "$api_base/api/v2.0/pool/scrub/scrub" \
  "$(awk 'NR == 1 { print $1 }' "$STUB_CURL_LOG")"
check "the body names the pool" storage "$(jq -r '.name' "$STUB_PAYLOAD_LOG")"
check "the body starts the scrub" START "$(jq -r '.action' "$STUB_PAYLOAD_LOG")"
check "the body is two keys" "action,name" "$(jq -r 'keys | join(",")' "$STUB_PAYLOAD_LOG")"
teardown

test_case "a non-numeric protection id is a usage error with status 2"
setup; single_instance_config
for verb_name in replication-run cloudsync-sync snapshot-run; do
  out=$(api "$verb_name" not-a-number 2>&1)
  rc=$?
  check "$verb_name rejects a non-numeric id" 2 "$rc"
  check "$verb_name explains the numeric id" 1 \
    "$(grep -c "needs a numeric id" <<<"$out")"
done
check "no request was sent" 0 "$(requests)"
teardown

test_case "a 404 from a protection run carries the NAS message"
setup; single_instance_config
printf '{"message":"pool not found"}\n' >"$WORK/notfound.json"
respond "/api/v2.0/pool/scrub/scrub" 0 404 "$WORK/notfound.json"
out=$(api scrub-start nope)
rc=$?
check "exit non-zero" 1 "$rc"
check "names the error" not_found "$(jq -r '.error' <<<"$out")"
check "carries the NAS message" "pool not found" "$(jq -r '.message' <<<"$out")"
teardown

test_case "the key never reaches the logs for a protection write"
setup; single_instance_config
printf 'TRUENAS_API_KEY=%s\n' "$secret_key" >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
respond "/api/v2.0/replication/run" 0 200 /dev/null
api replication-run 1 >/dev/null 2>&1
check "not in the method log" 0 "$(grep -c "$secret_key" "$STUB_METHOD_LOG")"
check "not in the payload log" 0 "$(grep -c "$secret_key" "$STUB_PAYLOAD_LOG")"
check "not in the curl log" 0 "$(grep -c "$secret_key" "$STUB_CURL_LOG")"
teardown
