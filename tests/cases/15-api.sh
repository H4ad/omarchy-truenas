# shellcheck shell=bash
# Task 16: bin/truenas-api. The two alert writes the view can make, and the
# proof that the key travels the way it does everywhere else: on stdin to curl,
# never in argv, and so never in the method, payload or request logs. The stub
# curls are in tests/stubs/curl; `api` is defined in tests/lib.sh.

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
check "the dismiss path was requested" 1 \
  "$(grep -c '/api/v2.0/alert/dismiss' "$STUB_CURL_LOG")"
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
teardown

test_case "an unknown verb is a usage error with status 2"
setup
out=$(api nonsense "$alert_uuid" 2>&1)
rc=$?
check "exit 2" 2 "$rc"
check "usage on stderr" 1 "$(grep -c 'truenas-api <verb>' <<<"$out")"
teardown
