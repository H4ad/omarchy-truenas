# shellcheck shell=bash
# Shared helpers for truenas-poll, truenas-api and truenasctl. Sourced, never
# executed.

TN_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/truenas"
TN_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/truenas"
TN_CONFIG_FILE="${TRUENAS_CONFIG_FILE:-$TN_CONFIG_HOME/config.json}"
TN_CREDENTIALS_FILE="${TRUENAS_CREDENTIALS_FILE:-$TN_CONFIG_HOME/credentials}"
TN_STATE_FILE="$TN_STATE_HOME/state.json"
TN_SEEN_FILE="$TN_STATE_HOME/seen.json"
TN_META_FILE="$TN_STATE_HOME/meta.json"
TN_HISTORY_FILE="$TN_STATE_HOME/history.json"
TN_PLUGIN_DIR="${TN_PLUGIN_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"

tn_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
tn_warn() { printf 'truenas: %s\n' "$*" >&2; }

tn_have() { command -v "$1" >/dev/null 2>&1; }

# Write stdin to $1 through a temp file in the same directory, so a reader with
# an inotify watch never sees a half-written document.
#
# A directory this creates is created at 700 rather than at whatever the umask
# says, because the credentials file lives in one of them and a default umask of
# 022 leaves it listable by everyone. The mode is set only on a directory that
# was not there, so a mode somebody chose on purpose is never overwritten.
tn_write_atomic() {
  local target=$1 dir tmp
  dir=$(dirname "$target")
  [[ -d $dir ]] || mkdir -p -m 700 "$dir" || return 1
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  if cat >"$tmp"; then
    chmod 600 "$tmp"
    mv -f "$tmp" "$target"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Reads a JSON file, falling back to $2 when it is missing, empty, or unparsable.
# `jq . empty-file` exits 0 and prints nothing, so a bare command substitution
# silently yields an empty string and every later --argjson fails on it.
tn_read_json() {
  local file=$1 fallback=${2:-\{\}} text
  [[ -s $file ]] || { printf '%s' "$fallback"; return 0; }
  text=$(jq -c '.' "$file" 2>/dev/null) || text=""
  [[ -n $text && $text != "null" ]] || text=$fallback
  printf '%s' "$text"
}

# Strips the C0 control bytes a terminal interprets (ESC and friends), keeping
# tab, newline and carriage return. Every byte that came off the wire is
# untrusted terminal input: a NAS that puts an OSC 52 or a title-change sequence
# in an alert, a pool name or an error message would otherwise get it printed
# raw by `jq -r`. Use at the edge of any live body that is printed rather than
# stored; tn_write_json sanitizes the stored copies.
tn_sanitize() {
  tr -d '\000-\010\013\014\016-\037\177'
}

# Writes stdin to $1 only when it parses as JSON, so a failed producer cannot
# replace good state with an empty file. Every string value is stripped of C0/DEL
# control characters first, on the same reasoning as tn_sanitize: this is the one
# gate every state/history/seen file passes through, so nothing a compromised NAS
# emits can survive to be decoded by `jq -r` at the operator's terminal.
tn_write_json() {
  local target=$1 tmp clean
  tmp=$(mktemp "${TMPDIR:-/tmp}/truenas-write.XXXXXX")
  clean=$(mktemp "${TMPDIR:-/tmp}/truenas-clean.XXXXXX")
  cat >"$tmp"
  if [[ -s $tmp ]] && jq -e . "$tmp" >/dev/null 2>&1; then
    if ! jq 'walk(if type == "string"
                    then gsub("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]"; "")
                    else . end)' "$tmp" >"$clean" 2>/dev/null; then
      rm -f "$tmp" "$clean"
      tn_warn "refusing to write invalid JSON to $target"
      return 1
    fi
    if tn_write_atomic "$target" <"$clean"; then
      rm -f "$tmp" "$clean"
      return 0
    fi
    rm -f "$tmp" "$clean"
    tn_warn "could not write $target"
    return 1
  fi
  rm -f "$tmp" "$clean"
  tn_warn "refusing to write invalid JSON to $target"
  return 1
}

# Emits the config with defaults filled in, or a synthetic config carrying
# `configError` so callers have one code path for "no config" and "bad config".
# `insecureTLS` is echoed with its type checked rather than through `// false`:
# the `//` operator treats an explicit false as absent, and false is the whole
# point of the field.
tn_load_config() {
  # The env override is consulted at call time, not just at source time: a case
  # file sources this library before its setup() exports the paths, and a poll
  # inherits a path chosen by the caller. TN_CONFIG_FILE stays the compiled-in
  # default for the no-override path.
  local cfg=${TRUENAS_CONFIG_FILE:-$TN_CONFIG_FILE}
  if [[ ! -f $cfg ]]; then
    printf '{"configError":"unconfigured","instances":[]}\n'
    return 0
  fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    printf '{"configError":"config_not_json","instances":[]}\n'
    return 0
  fi
  jq '
    {
      schema:          (.schema // 1),
      # Clamped at both ends. The floor is the API rate limit; the ceiling keeps
      # `pollSeconds * 1000` inside a 32-bit int in the QML Timer, so a
      # hand-edited or out-of-range value cannot wrap to a zero/negative interval
      # and turn the repeating Timer into a tight poll loop.
      pollSeconds:     ((.pollSeconds // 30) | if type == "number" then (if . < 15 then 15 elif . > 86400 then 86400 else . end) else 30 end),
      timeoutSeconds:  ((.timeoutSeconds // 8) | if type == "number" then (if . < 2 then 2 elif . > 86400 then 86400 else . end) else 8 end),
      insecureTLS:     (if (.insecureTLS | type) == "boolean" then .insecureTLS else false end),
      notify: {
        levels:                        (.notify.levels // ["critical","error","warning"]),
        # `//` treats an explicit false as absent, and false is the whole point
        # of these three fields, so each is echoed only when it is a boolean.
        resolved:                      (if (.notify.resolved | type) == "boolean" then .notify.resolved else true end),
        nodata:                        (if (.notify.nodata | type) == "boolean" then .notify.nodata else false end),
        renotifyMinutes:               (.notify.renotifyMinutes // 0),
        batchThreshold:                (.notify.batchThreshold // 3),
        stickyCritical:                (if (.notify.stickyCritical | type) == "boolean" then .notify.stickyCritical else false end),
        connectionFailuresBeforeToast: (.notify.connectionFailuresBeforeToast // 3),
        metaMaxAgeSeconds:             (.notify.metaMaxAgeSeconds // 300),
        instances:                     (.notify.instances // null),
        pausedUntil:                   (.notify.pausedUntil // null)
      },
      instances: [
        (.instances // [])[]
        # The // operator treats false the same as absent, so (.enabled // true)
        # is true for an instance explicitly turned off.
        | select((.enabled != false) and ((.baseUrl // "") | length > 0))
        | {
            id:            (.id // "default"),
            label:         (.label // (.id // "TrueNAS")),
            baseUrl:       (.baseUrl | sub("/+$"; "")),
            tag:           (.tag // null),
            apiKeyFile:    (.apiKeyFile // null),
            apiKeyCommand: (.apiKeyCommand // null)
          }
      ]
    }
  ' "$cfg"
}

# Reads one KEY=value out of a credentials file without sourcing it, so a
# credentials file cannot execute code.
tn_creds_lookup() {
  local file=$1 name=$2 line
  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    line=${line%%$'\r'}
    [[ $line == "$name="* ]] || continue
    printf '%s' "${line#"$name="}"
    return 0
  done <"$file"
  return 1
}

tn_creds_mode_ok() {
  local file=$1 mode
  [[ -f $file ]] || return 0
  mode=$(stat -c '%a' "$file" 2>/dev/null) || return 0
  [[ ${#mode} -le 3 && ${mode: -2} == "00" ]]
}

# Resolves the key for one instance. Prints `ok:<key>` or `err:<reason>`, because
# callers read it through a command substitution and a variable set in there
# would not survive the subshell. Order: apiKeyCommand, apiKeyFile, the
# per-instance name in the shared credentials file, then the bare name. The
# per-instance name is kept ahead of the bare one so a future multi-NAS config
# needs no change here.
tn_resolve_key() {
  local id=$1 key_file=$2 key_cmd=$3 upper key
  upper=$(printf '%s' "$id" | tr '[:lower:]-' '[:upper:]_')

  if [[ -n $key_cmd && $key_cmd != null ]]; then
    # `bash -c` rather than `eval`: apiKeyCommand is a shell command by design,
    # but eval would run it with every function and variable this library has
    # defined already in scope, so a command could read or shadow them. A fresh
    # shell can still do anything the user can do, which is the documented cost
    # of the field, and nothing that depends on being inside this one.
    if key=$(bash -c "$key_cmd" 2>/dev/null) && [[ -n ${key//[[:space:]]/} ]]; then
      key=${key%%$'\n'*}
      # A key that reaches curl with a trailing CR sends a header nobody meant
      # to send. Password managers that print CRLF are the usual source.
      printf 'ok:%s' "${key%$'\r'}"
      return 0
    fi
    printf 'err:key_command_failed'
    return 1
  fi

  local file=${TRUENAS_CREDENTIALS_FILE:-$TN_CREDENTIALS_FILE}
  [[ -n $key_file && $key_file != null ]] && file=${key_file/#\~/$HOME}

  if [[ ! -f $file ]]; then
    printf 'err:no_key'
    return 1
  fi
  if ! tn_creds_mode_ok "$file"; then
    printf 'err:credentials_permissions'
    return 1
  fi
  # An assignment with nothing after the `=` (a hand-edited TRUENAS_API_KEY=)
  # is not a key: treat it as absent and keep looking, so the poll never sends
  # `Authorization: Bearer ` and mistakes the 401 for a rejected key.
  if key=$(tn_creds_lookup "$file" "TRUENAS_API_KEY_$upper") && [[ -n ${key//[[:space:]]/} ]]; then
    printf 'ok:%s' "$key"
    return 0
  fi
  if key=$(tn_creds_lookup "$file" "TRUENAS_API_KEY") && [[ -n ${key//[[:space:]]/} ]]; then
    printf 'ok:%s' "$key"
    return 0
  fi
  # A bare key with no assignment, one line, is accepted too.
  key=$(head -n1 "$file")
  if [[ -n ${key//[[:space:]]/} && $key != *=* ]]; then
    printf 'ok:%s' "$key"
    return 0
  fi
  printf 'err:no_key'
  return 1
}

# Prints `-k` when the config asks curl to skip certificate verification, and
# nothing otherwise. It reads TN_CONFIG_FILE itself because callers reach it
# before tn_load_config on some paths. A missing, empty, or unparsable file, or
# a non-boolean value, means "verify": only an explicit true turns it off.
tn_insecure_args() {
  local cfg=${TRUENAS_CONFIG_FILE:-$TN_CONFIG_FILE}
  [[ -s $cfg ]] || return 0
  local insecure
  insecure=$(jq -r 'if (.insecureTLS | type) == "boolean" then .insecureTLS else false end' \
    "$cfg" 2>/dev/null) || return 0
  [[ $insecure == true ]] && printf '%s' '-k'
  return 0
}

# The API generation in use. REST `/api/v2.0` is deprecated from TrueNAS 25.04,
# so every call goes through tn_http_request and this names the dialect a poll
# used. The meta cadence now caches system state, but dialect probing has not
# shipped, so this is still the fixed rest-v2.0 rather than a cached value.
tn_dialect() { printf '%s' 'rest-v2.0'; }

# Request $2 from base $1. The key goes in on stdin as a curl config file so it
# never appears in argv, where every process of this user could read it.
# Sets TN_CODE, TN_TIME_MS, TN_CURL_RC and leaves the body in $TN_BODY.
tn_http_request() {
  local method=$1 base=$2 path=$3 key=$4 timeout=$5 payload=${6:-} out escaped
  TN_BODY=$(mktemp "${TMPDIR:-/tmp}/truenas-body.XXXXXX")
  local args=(-sS --config - --max-time "$timeout" -X "$method"
              -o "$TN_BODY" -w '%{http_code} %{time_total}')
  # tn_insecure_args is consulted here rather than by each caller, so no path
  # can send a request without it and forget -k: the config decides once.
  local insecure
  insecure=$(tn_insecure_args)
  [[ -n $insecure ]] && args+=("$insecure")
  if [[ -n $payload ]]; then
    args+=(-H "content-type: application/json" --data-binary "@$payload")
  fi
  # curl processes backslash escapes inside a quoted config value, so a key
  # holding a `"` is truncated there and a key holding a `\` is rewritten, both
  # silently: the request goes out with the wrong key and comes back 401.
  # Leaving the value unquoted is not the fix, because curl then stops at the
  # first space and drops the header entirely.
  escaped=${key//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$escaped" | curl "${args[@]}" "$base$path" 2>/dev/null)
  TN_CURL_RC=$?
  TN_CODE=${out%% *}
  local secs=${out##* }
  if [[ -n $secs && $secs != "$out" ]]; then
    TN_TIME_MS=$(awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }')
  else
    TN_TIME_MS=0
  fi
  [[ $TN_CODE =~ ^[0-9]+$ ]] || TN_CODE=0
  return 0
}

tn_http_get() { tn_http_request GET "$1" "$2" "$3" "$4"; }

# Turns the last tn_http_get into one stable error code, or nothing when the
# call was good.
tn_classify() {
  local body=$TN_BODY code=$TN_CODE rc=$TN_CURL_RC
  if ((rc != 0)); then
    case $rc in
      28) printf 'timeout' ;;
      *)  printf 'unreachable' ;;
    esac
    return 0
  fi
  # A status that names the failure on its own is read before the body, so an
  # empty-body 401 or 404 still classifies instead of falling through to a JSON
  # complaint, and a 202 carrying a body is not mistaken for a non-2xx.
  case $code in
    401) printf 'unauthenticated'; return 0 ;;
    403) printf 'forbidden'; return 0 ;;
    404) printf 'not_found'; return 0 ;;
    5??) printf 'server_error'; return 0 ;;
  esac
  # A successful DELETE answers with no body at all, which is not a failure.
  if [[ ! -s $body ]]; then
    case $code in
      200|201|202|204) printf '' ; return 0 ;;
    esac
  fi
  # No -e: `jq -e` exits non-zero for the valid JSON values `false` and `null`,
  # which a 2xx can legitimately carry. Every valid JSON value classifies from
  # the status code below; only a body that is not JSON at all is not_json.
  if ! jq . "$body" >/dev/null 2>&1; then
    # A route that does not exist on the frontend answers 200 with HTML. Trusting
    # the status code here would report a healthy instance with zero alerts,
    # which is the one lie that matters.
    printf 'not_json'
    return 0
  fi
  local kind
  kind=$(jq -r '.error.code // .error.type // ""' "$body" 2>/dev/null)
  case $code in
    200|201|202|204) printf '' ;;
    *)   [[ -n $kind ]] && printf '%s' "$kind" || printf 'http_%s' "$code" ;;
  esac
}

tn_error_message() {
  # The top-level `.message` is read too: the service control routes answer an
  # unknown name with `{"message":"<name>"}` and no `.error` at all.
  #
  # A model-layer validation failure answers 422 with the message buried one
  # level down under an array key, e.g.
  # `{"null":[{"message":"PeriodicSnapshotTask 999999 does not exist"}]}` or
  # `{"data":[{"message":"...","errno":22}]}`. When the three flat reads find
  # nothing, walk the first array-valued key and take its first object's
  # `.message`. The array guard keeps a scalar value (or an empty array) from
  # being iterated, and the string guard keeps a non-string from being printed.
  #
  # The type guard at the end keeps a non-string (a number, an array) from being
  # dumped as a bare value by -r, which would print JSON in the middle of a
  # sentence.
  jq -r '
    def keyed_message:
      if type == "object" then
        [ to_entries[]
          | select(.value | type == "array")
          | .value[]
          | select(type == "object")
          | .message
          | select(type == "string" and length > 0) ][0] // ""
      else "" end;
    (.error.message // .error.type // .message // keyed_message // "")
    | if type == "string" then . else tostring end' "$TN_BODY" 2>/dev/null \
    | tn_sanitize
}

tn_curl_rc_message() {
  case ${1:-0} in
    6)  printf 'could not resolve host' ;;
    7)  printf 'connection refused' ;;
    28) printf 'timed out' ;;
    35) printf 'TLS handshake failed' ;;
    60) printf 'certificate not trusted' ;;
    0)  printf '' ;;
    *)  printf 'curl exit %s' "$1" ;;
  esac
}
