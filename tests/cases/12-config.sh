# shellcheck shell=bash
source "$ROOT/bin/truenas-lib.sh"

test_case "a key in the credentials file resolves"
setup
check "resolves" "ok:test-key" "$(tn_resolve_key nas '' '')"

test_case "a world-readable credentials file is refused"
setup
chmod 644 "$TRUENAS_CREDENTIALS_FILE"
check "refused" "err:credentials_permissions" "$(tn_resolve_key nas '' '')"

test_case "apiKeyCommand wins and never touches a file"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
check "command key" "ok:cmd-key" "$(tn_resolve_key nas '' "printf 'cmd-key\n'")"

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
