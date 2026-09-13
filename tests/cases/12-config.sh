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
