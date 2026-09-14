# Normalizes the TrueNAS REST v2.0 bodies a poll reads into the stable shape
# state.json carries. Input: --slurpfile system, --slurpfile alerts,
# --slurpfile pools, --slurpfile disks, --slurpfile diskTemps, --slurpfile
# services and --slurpfile apps, each holding one response body (or null when
# that request failed), plus --arg now.
# `connection` is built by the poll, not here, because it is about the poll's
# own reachability rather than the NAS's contents.

# A number written with a trailing zero (`38.0`) survives jq 1.7+ exactly as
# the wire wrote it, so two builds answering the same temperature would read as
# different text. `+ 0` canonicalizes it; null is zero in jq's arithmetic, so
# absence is passed through before the addition.
def num: (tonumber? // null) | if . == null then null else . + 0 end;

# TrueNAS writes a datetime as an ISO string on some routes and as Mongo's
# {"$date": <epoch_ms>} on others. Both become an ISO string, or null; a raw
# object must never reach a QML binding that expects a date.
def to_iso:
  if type == "string" then .
  elif type == "object" and has("$date") then
    ((."$date" | num) as $ms
     | if $ms == null then null else ($ms / 1000 | floor) end)
    | if . == null then null else strftime("%Y-%m-%dT%H:%M:%SZ") end
  else null end;

# Case-insensitive bucket. An unknown level is a notice, never dropped: a level
# somebody's TrueNAS build grew that this list has not heard of is still an
# alert, and silently dropping it is the one lie that matters.
def level_of:
  (.level // "" | tostring | ascii_upcase) as $l
  | if   $l == "CRITICAL" or $l == "ALERT" or $l == "EMERGENCY" then "critical"
    elif $l == "ERROR"                                         then "error"
    elif $l == "WARNING"                                       then "warning"
    elif $l == "INFO"                                          then "info"
    else "notice"
    end;

def alert_norm:
  {
    uuid:        (.uuid // .id // ""),
    level:       level_of,
    text:        (.formatted // .text // ""),
    formatted:   (.formatted // .text // ""),
    node:        (.node // ""),
    datetime:    ((.datetime? // null) | to_iso),
    dismissed:   (.dismissed == true),
    dismissable: (.dismissable != false)
  };

# scan.start_time/end_time follow the datetime rule. A pool with no scan data
# carries null, never a fabricated FINISHED.
def scan_norm:
  if type != "object" then null
  else {
    function:   (.function // null),
    state:      (.state // null),
    percentage: ((.percentage? // null) | num),
    errors:     ((.errors? // null) | num),
    startTime:  ((.start_time? // null) | to_iso),
    endTime:    ((.end_time? // null) | to_iso)
  } end;

# A vdev error category totals only when every data vdev reports it as a
# number. One vdev whose field is absent makes that total unknown, not a
# smaller number.
def vdev_sum($field):
  [ .[] | .[$field]? | num ] as $vals
  | if ($vals | length) == length
       and ([$vals[] | select(. == null)] | length) == 0
    then ($vals | add)
    else null end;

# The pool's own error_count, when a build carries one, else the sum of every
# data vdev's stats. Absent on both counts is null, not three zeroes.
def vdev_errors:
  if ((.error_count? // null) | type) == "object" then
    { read:     ((.error_count.read? // null)     | num),
      write:    ((.error_count.write? // null)    | num),
      checksum: ((.error_count.checksum? // null) | num) }
  else
    ([ ((.topology? // {}).data? // [])[]? | (.stats? // {}) ]) as $stats
    | if ($stats | length) == 0 then null
      else {
        read:     ($stats | vdev_sum("read_errors")),
        write:    ($stats | vdev_sum("write_errors")),
        checksum: ($stats | vdev_sum("checksum_errors"))
      } end
  end;

def used_pct:
  ((.size? // null) | num) as $size
  | ((.allocated? // null) | num) as $alloc
  | if $size != null and $size > 0 and $alloc != null
      # One decimal, and null rather than 0 for an unknown size, because a bar
      # drawn at 0% reads as "empty", which is a claim the poll cannot make.
      then ((($alloc / $size) * 100 * 10 | round) / 10)
      else null end;

def pool_norm:
  {
    name:          (.name // ""),
    status:        (.status // ""),
    healthy:       (if has("healthy") then (.healthy == true)
                    else (.status == "ONLINE") end),
    size:          ((.size? // null)      | num),
    allocated:     ((.allocated? // null) | num),
    free:          ((.free? // null)      | num),
    usedPct:       used_pct,
    fragmentation: ((.fragmentation? // null) | num),
    scan:          ((.scan? // null) | scan_norm),
    vdevErrors:    vdev_errors
  };

def system_norm:
  {
    hostname:      (.hostname // ""),
    version:       (.version // ""),
    # An absent or non-numeric field is unknown, never 0: "up 0s" is a claim
    # the poll cannot make. A real numeric 0 survives tonumber.
    uptimeSeconds: ((.uptime_seconds? // null) | num),
    cores:         ((.cores?          // null) | num),
    physmem:       ((.physmem?        // null) | num),
    loadavg:       ((.loadavg? // null)
                    | if type == "array" then map(num) else null end)
  };

# disk/temperatures answers `[tempC, criticalC]` when thresholds were asked
# for, and a bare number for a disk that reports none. Both become that pair;
# an absent entry is [null, null], never [0, 0].
def temp_pair:
  if type == "array" then
    [((.[0]? // null) | num), ((.[1]? // null) | num)]
  else [num, null] end;

# The one place tempState is decided. A missing temperature or threshold is
# unknown, never ok, and the warning band starts ten degrees below critical.
def temp_state:
  if .[0] == null or .[1] == null then "unknown"
  elif .[0] >= .[1]              then "critical"
  elif .[0] >= .[1] - 10         then "warning"
  else "ok" end;

# A disk row plus the raw temperatures map. `pool` is "" when the disk is not
# imported; size and temperatures are null when unknown, never 0.
def disk_norm($temps):
  (.name // "") as $name
  | (($temps[$name] // null) | temp_pair) as $t
  | {
      name:          $name,
      model:         (.model // ""),
      type:          (.type // ""),
      size:          ((.size? // null) | num),
      pool:          (.imported_zpool // ""),
      bus:           (.bus // ""),
      tempC:         $t[0],
      tempCriticalC: $t[1],
      tempState:     ($t | temp_state)
    };

def alert_rank:
  { "critical": 0, "error": 1, "warning": 2, "notice": 3, "info": 4 }[.] // 5;

# The service list row. `enable` is true only when the wire says true; a missing
# enable is false, which is what the list means. A missing state is the empty
# string, never a fabricated RUNNING, and an absent id is null, never 0.
def service_norm:
  {
    id:      ((.id? // null) | num),
    service: (.service // ""),
    state:   (.state // ""),
    enable:  (.enable == true)
  };

# The one portal a row links out to. The Web UI entry wins when it is there;
# otherwise the first key sorted, so the pick is stable across builds. An empty
# or missing map is null, never a row with empty text.
def portal_norm:
  if type != "object" or length == 0 then null
  elif has("Web UI") then { label: "Web UI", url: (.["Web UI"] // "") }
  else (to_entries | sort_by(.key) | .[0]) as $e
       | { label: ($e.key // ""), url: ($e.value // "") }
  end;

# The app list row. metadata may be absent or null; title falls back to name,
# version to human_version then version, and every absent string is "", never
# "undefined". containers is a number or null, never 0, and the booleans default
# false only because a missing flag is the wire saying off.
def app_norm:
  ((.metadata? // {}) | if type == "object" then . else {} end) as $m
  | {
      id:               (.id // null),
      name:             (.name // ""),
      title:            (if ($m.title // "") == "" then (.name // "") else $m.title end),
      state:            (.state // ""),
      version:          (if (.human_version // "") == "" then (.version // "") else .human_version end),
      appVersion:       ($m.app_version // ""),
      train:            ($m.train // ""),
      custom:           (.custom_app == true),
      upgradeAvailable: (.upgrade_available == true),
      migrated:         (.migrated == true),
      containers:       ((.active_workloads.containers? // null) | num),
      webui:            ((.portals? // {}) | portal_norm)
    };

($system[0]) as $sys
| ($alerts[0] // []) as $alerts_raw
| ($pools[0]  // []) as $pools_raw
| ($disks[0]  // []) as $disks_raw
| ($diskTemps[0] // {}) as $temps
| ($services[0] // []) as $services_raw
| ($apps[0]     // []) as $apps_raw
| ([ $alerts_raw[]? | alert_norm ]) as $alert_rows
| ([ $pools_raw[]?  | pool_norm  ]) as $pool_rows
| ([ $disks_raw[]?  | disk_norm($temps) ]) as $disk_rows
| ([ $services_raw[]? | service_norm ]) as $service_rows
| ([ $apps_raw[]?     | app_norm     ]) as $app_rows
# Dismissed alerts stay in `alerts`, flagged, because a row that disappears when
# it is dismissed is how a person loses track of what they silenced. They leave
# `counts`, which is what the bar reads, and are counted as `dismissed` there.
| ([ $alert_rows[] | select(.dismissed | not) ]) as $active
| {
    system: (if $sys == null then null else ($sys | system_norm) end),
    counts: {
      critical:  ([ $active[] | select(.level == "critical") ] | length),
      error:     ([ $active[] | select(.level == "error")    ] | length),
      warning:   ([ $active[] | select(.level == "warning")  ] | length),
      notice:    ([ $active[] | select(.level == "notice")   ] | length),
      info:      ([ $active[] | select(.level == "info")     ] | length),
      total:     ($active | length),
      dismissed: ([ $alert_rows[] | select(.dismissed) ] | length)
    },
    alerts: ($alert_rows | sort_by([(.level | alert_rank), (.datetime // "")])),
    pools:  $pool_rows,
    disks:  ($disk_rows | sort_by(.name)),
    # A failed services or apps fetch contributes no rows, so the list is empty
    # and the poll names the section in `warnings`; it never becomes an
    # empty-but-healthy list. Both sorted for stable tests and UI.
    services: ($service_rows | sort_by(.service)),
    apps:     ($app_rows | sort_by(.name))
  }
