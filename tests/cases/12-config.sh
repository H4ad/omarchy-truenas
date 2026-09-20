# shellcheck shell=bash
source "$ROOT/bin/truenas-lib.sh"

test_case "a key in the credentials file resolves"
setup
check "resolves" "ok:test-key" "$(tn_resolve_key nas '' '')"
teardown

test_case "a world-readable credentials file is refused"
setup
chmod 644 "$TRUENAS_CREDENTIALS_FILE"
check "refused" "err:credentials_permissions" "$(tn_resolve_key nas '' '')"
teardown

test_case "a credential assignment with no value yields no_key"
setup
printf 'TRUENAS_API_KEY=\n' >"$TRUENAS_CREDENTIALS_FILE"
chmod 600 "$TRUENAS_CREDENTIALS_FILE"
check "empty is not a key" "err:no_key" "$(tn_resolve_key nas '' '')"
printf 'TRUENAS_API_KEY=   \n' >"$TRUENAS_CREDENTIALS_FILE"
check "whitespace is not a key" "err:no_key" "$(tn_resolve_key nas '' '')"
teardown

test_case "a missing credentials file yields no_key"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
check "no key" "err:no_key" "$(tn_resolve_key nas '' '')"
teardown

test_case "apiKeyCommand wins and never touches a file"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
check "command key" "ok:cmd-key" "$(tn_resolve_key nas '' "printf 'cmd-key\n'")"
teardown

test_case "a failing apiKeyCommand reports key_command_failed"
setup
check "failed" "err:key_command_failed" "$(tn_resolve_key nas '' 'false')"
teardown

test_case "insecureTLS controls -k"
setup
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": true, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "on" "-k" "$(tn_insecure_args)"
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": false, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "off" "" "$(tn_insecure_args)"
teardown

test_case "tn_load_config reports a missing file as unconfigured"
setup
rm -f "$TRUENAS_CONFIG_FILE"
check "unconfigured" "unconfigured" "$(tn_load_config | jq -r '.configError')"
teardown

test_case "tn_load_config rejects valid JSON that is not an object"
setup
printf '[]\n' >"$TRUENAS_CONFIG_FILE"
check "array" "config_not_json" "$(tn_load_config | jq -r '.configError')"
printf '"x"\n' >"$TRUENAS_CONFIG_FILE"
check "string" "config_not_json" "$(tn_load_config | jq -r '.configError')"
printf '123\n' >"$TRUENAS_CONFIG_FILE"
check "number" "config_not_json" "$(tn_load_config | jq -r '.configError')"
teardown

test_case "tn_write_json refuses invalid JSON and leaves the target alone"
setup
printf '{"a":1}\n' >"$WORK/target.json"
write_rc=0
printf 'not json' | tn_write_json "$WORK/target.json" || write_rc=$?
check "exit 1" "1" "$write_rc"
check "target untouched" '{"a":1}' "$(cat "$WORK/target.json")"
teardown

test_case "tn_write_json fails when the target directory cannot be created"
setup
printf 'x\n' >"$WORK/blocker"
write_rc=0
printf '{"a":1}\n' | tn_write_json "$WORK/blocker/state.json" || write_rc=$?
check "exit 1" "1" "$write_rc"
teardown

test_case "a key with a quote and a backslash survives header writing"
setup
export STUB_CURL_HEADER_LOG="$WORK/header.log"
printf 'ok\n' >"$WORK/body"
respond "/api/v2.0/system/info" 0 200 "$WORK/body"
tn_http_request GET "https://nas.example" "/api/v2.0/system/info" 'abc"de\fg' 5 >/dev/null
check "header intact" 'Authorization: Bearer abc"de\fg' "$(cat "$STUB_CURL_HEADER_LOG")"
teardown

test_case "tn_http_request turns insecureTLS into a curl -k"
setup
export STUB_INSECURE_LOG="$WORK/insecure.log"
printf 'ok\n' >"$WORK/body"
respond "/api/v2.0/system/info" 0 200 "$WORK/body"
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": true, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
tn_http_request GET "https://nas.example" "/api/v2.0/system/info" test-key 5 >/dev/null
check "curl was told to skip verification" 1 "$(grep -c '^k$' "$STUB_INSECURE_LOG")"
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": false, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
  tn_http_request GET "https://nas.example" "/api/v2.0/system/info" test-key 5 >/dev/null
  check "and only when the config asks" 1 "$(grep -c '^k$' "$STUB_INSECURE_LOG")"
  teardown

# `jq -e` exits non-zero for the valid JSON values `false` and `null`, which a
# 2xx can carry. The classifier must read those from the status code, and only a
# body that is not JSON at all stays not_json.
test_case "tn_classify accepts a 2xx body of false, null or a number"
setup
printf 'false\n' >"$WORK/false.json"
TN_BODY=$WORK/false.json; TN_CODE=200; TN_CURL_RC=0
check "false is a 2xx success" "" "$(tn_classify)"
printf 'null\n' >"$WORK/null.json"
TN_BODY=$WORK/null.json
check "null is a 2xx success" "" "$(tn_classify)"
printf '12345\n' >"$WORK/job.json"
TN_BODY=$WORK/job.json
check "a job id is a 2xx success" "" "$(tn_classify)"
teardown

test_case "tn_classify keeps not_json for a 200 with an HTML body"
setup
printf '<html></html>\n' >"$WORK/notjson.html"
TN_BODY=$WORK/notjson.html; TN_CODE=200; TN_CURL_RC=0
check "HTML is not_json" not_json "$(tn_classify)"
teardown

# `jq -e` reported no valid result for an empty body, so a non-2xx with no body
# used to read not_json. `jq .` accepts the empty input and the status code names
# the failure instead.
test_case "tn_classify reads an empty non-2xx body from the status code"
setup
: >"$WORK/empty.json"
TN_BODY=$WORK/empty.json; TN_CODE=400; TN_CURL_RC=0
check "an empty 400 is http_400, not not_json" http_400 "$(tn_classify)"
teardown

# A 422 validation body carries the message one level down under an array key
# instead of at `.message` or `.error.message`, so the flat reads find nothing
# and used to render an empty sentence.
test_case "tn_error_message surfaces a keyed message on a 422 body"
setup
printf '{"null":[{"message":"PeriodicSnapshotTask 999999 does not exist"}]}\n' \
  >"$WORK/keyed-null.json"
TN_BODY=$WORK/keyed-null.json
check "the keyed message is read" \
  "PeriodicSnapshotTask 999999 does not exist" "$(tn_error_message)"
printf '{"data":[{"message":"bad input","errno":22}]}\n' >"$WORK/keyed-data.json"
TN_BODY=$WORK/keyed-data.json
check "a data array message is read" "bad input" "$(tn_error_message)"
printf '{"error":{"message":"older shape"}}\n' >"$WORK/keyed-old.json"
TN_BODY=$WORK/keyed-old.json
check "the existing error.message still wins" "older shape" "$(tn_error_message)"
printf '{"message":"top level"}\n' >"$WORK/keyed-top.json"
TN_BODY=$WORK/keyed-top.json
check "the existing top-level message still wins" "top level" "$(tn_error_message)"
printf '{"data":"not an array"}\n' >"$WORK/keyed-scalar.json"
TN_BODY=$WORK/keyed-scalar.json
check "a non-array value is not iterated" "" "$(tn_error_message)"
printf '{"data":[]}\n' >"$WORK/keyed-empty.json"
TN_BODY=$WORK/keyed-empty.json
check "an empty array yields nothing" "" "$(tn_error_message)"
teardown

test_case "tn_load_config clamps pollSeconds and timeoutSeconds at both ends"
setup
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "pollSeconds": 4294967296, "timeoutSeconds": 99999,
  "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "an over-long pollSeconds clamps to a day" 86400 \
  "$(tn_load_config | jq -r '.pollSeconds')"
check "an over-long timeoutSeconds clamps too" 86400 \
  "$(tn_load_config | jq -r '.timeoutSeconds')"
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "pollSeconds": 1, "timeoutSeconds": 0,
  "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "the pollSeconds floor stays" 15 "$(tn_load_config | jq -r '.pollSeconds')"
check "the timeoutSeconds floor stays" 2 "$(tn_load_config | jq -r '.timeoutSeconds')"
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "pollSeconds": "soon", "timeoutSeconds": null,
  "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "a non-number falls back to the default" 30 \
  "$(tn_load_config | jq -r '.pollSeconds')"
teardown

test_case "tn_write_json strips terminal control bytes but keeps tab and newline"
setup
printf '%s' '{"a":"x\u001by","t":"a\tb","n":"a\nb","ok":"caf\u00e9"}' \
  | tn_write_json "$WORK/clean.json"
check "the write succeeds" 0 "$?"
check "the ESC byte is gone" xy "$(jq -r '.a' "$WORK/clean.json")"
check "a tab is kept" "$(printf 'a\tb')" "$(jq -r '.t' "$WORK/clean.json")"
check "a newline is kept" "$(printf 'a\nb')" "$(jq -r '.n' "$WORK/clean.json")"
check "the file holds no raw ESC" 0 "$(grep -c $'\x1b' "$WORK/clean.json")"
check "ordinary text is untouched" "café" "$(jq -r '.ok' "$WORK/clean.json")"
teardown

test_case "tn_load_config validates the redact level"
setup
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "redact": "names", "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "a valid level passes through" names "$(tn_load_config | jq -r '.redact')"
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "redact": "verbose", "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "an unknown level falls back to off" off "$(tn_load_config | jq -r '.redact')"
cat >"$TRUENAS_CONFIG_FILE" <<'JSON'
{ "redact": 3, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "a non-string level falls back to off" off "$(tn_load_config | jq -r '.redact')"
teardown

test_case "tn_sanitize strips the escape byte and leaves the rest"
setup
check "the ESC byte is removed" "ab" "$(printf 'a\x1bb' | tn_sanitize)"
check "a newline survives" "$(printf 'a\nb')" "$(printf 'a\nb' | tn_sanitize)"
check "a tab survives" "$(printf 'a\tb')" "$(printf 'a\tb' | tn_sanitize)"
teardown
