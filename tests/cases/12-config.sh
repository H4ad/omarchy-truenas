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

# `jq -e` exits non-zero for `false`, `null` and a bare number, all valid JSON a
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
