# Annotates the four protection sections with a schedule-derived overdue
# signal. Input: nothing (run with jq -n). Inputs: --slurpfile payload (one
# normalize.jq output), --slurpfile seen (seen.json), --arg now, --argjson
# graceSeconds, and one 0/1 flag per section whose answer is worth trusting.
#
# Output: { payload, protection, decisions }.
#
# `payload` is the input with every protection row carrying `scheduled`,
# `gapSeconds`, `lastRunKnown`, `lastRunAt`, `firstSeenAt` and `overdue`.
# `protection` is the next seen.overdue map, keyed `<section>:<id>`, and
# `decisions` names the rows that just became overdue or recovered.
#
# The gap is a bound, not a next-run calculation. That is deliberate: it needs
# no NAS timezone, and a DST change or a short month cannot make a healthy task
# look late. The grace covers a run that takes longer than usual, so a daily
# task alarms about 30 hours after its last finish, not at the stroke of
# midnight. A replication task with no schedule of its own is judged on the
# periodic snapshot schedules that trigger it, and a scrub task's threshold
# widens the bound because TrueNAS will not start a scrub before it.

# An ISO timestamp as epoch seconds. The normalizer emits `...Z` strings, but a
# route that passes a wire string through can hand us fractional seconds or a
# numeric offset, so both are accepted rather than read as "never run".
def to_epoch:
  if type != "string" then null
  else
    (sub("\\.[0-9]+"; "")) as $s
    | if ($s | endswith("Z")) then
        (try ($s | fromdateiso8601) catch null)
      else
        ($s | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<off>[+-][0-9]{2}:[0-9]{2})?$")) as $m
        | if $m == null then null
          else
            (try (($m.base + "Z") | fromdateiso8601) catch null) as $utc
            | if $utc == null then null
              elif $m.off == null then $utc
              else
                (($m.off[1:3] | tonumber) * 3600
                 + ($m.off[4:6] | tonumber) * 60) as $delta
                | if $m.off[0:1] == "+" then $utc - $delta else $utc + $delta end
              end
          end
      end
  end;

# The later of two ISO timestamps as epoch seconds, or null when neither parses.
def later_epoch($a; $b):
  [ ($a | to_epoch), ($b | to_epoch) ]
  | map(select(. != null))
  | if length == 0 then null else max end;

# The longest gap the cron fields allow between two scheduled runs.
#   month fixed              a yearly task, 366 days
#   day-of-month fixed       a monthly task; 62 days because the 31st skips
#                            February entirely
#   day-of-week fixed        a weekly task
#   hour fixed               a daily task
#   minute fixed             an hourly task
#   both wild                every minute
def gap_seconds:
  if type != "object" then null
  else
    (.month  // "*") as $month
    | (.dom   // "*") as $dom
    | (.dow   // "*") as $dow
    | (.hour  // "*") as $hour
    | (.minute // "*") as $minute
    | if   $month != "*"               then 31622400
      elif $dom != "*" and $dow != "*" then 604800
      elif $dom != "*"                 then 5356800
      elif $dow != "*"                 then 604800
      elif $hour != "*"                then 86400
      elif $minute != "*"              then 3600
      else 60
      end
  end;

def is_running($state):
  (((($state // "") | tostring) | ascii_upcase) == "RUNNING");

# The schedules a task can fire on. A replication task can carry its own
# schedule, the schedules of the periodic snapshot tasks that trigger it, or
# both. Any trigger firing is a run, so the tightest schedule is the bound.
def schedules_of($row):
  (if ($row.schedule | type) == "object" then [$row.schedule] else [] end)
  + (($row.periodicSnapshotSchedules // [])
     | if type == "array" then map(select(type == "object")) else [] end);

# One annotated row. `$scheduled` says the task runs on its own, `$schedules`
# is the non-empty list it can fire on, `$gap_floor` widens the bound (a scrub
# task's threshold is a minimum age before a run is even allowed), `$last` is
# the last finished run in epoch seconds (null when there is none),
# `$lastKnown` is false only when the source of the last run did not answer, and
# `$running` exempts an in-flight job from the age test. `$seen` is
# seen.overdue, keyed `<section>:<id>`; a task's first sighting starts its grace
# for a task that has never run, so a task created a minute ago does not alarm
# before its first run.
def annotated($seen; $kind; $now; $grace; $scheduled; $schedules; $gap_floor; $last; $lastKnown; $running):
  ($kind + ":" + (.id | tostring)) as $key
  | (($seen[$key].firstSeenAt // null) | to_epoch) as $first_seen
  | (if $first_seen == null then ($now | to_epoch) else $first_seen end) as $first
  | (if $last == null then $first else $last end) as $basis
  | ([ $schedules[] | gap_seconds ] | min) as $schedule_gap
  | (if $schedule_gap == null then null
     elif $gap_floor > $schedule_gap then $gap_floor
     else $schedule_gap end) as $gap
  | . + {
      scheduled: $scheduled,
      gapSeconds: $gap,
      lastRunKnown: $lastKnown,
      lastRunAt: (if $last == null then null else ($last | todate) end),
      firstSeenAt: ($first | todate),
      overdue: (if ($scheduled and $lastKnown and ($running | not) and $gap != null)
                then (($now | to_epoch) - $basis) > ($gap + $grace)
                else false end)
    };

($payload[0]) as $p
| ($seen[0].overdue // {}) as $s
| ($replicationOk == 1) as $rep_ok
| ($cloudSyncOk == 1) as $cs_ok
| ($snapshotTasksOk == 1) as $snap_ok
| ($scrubsOk == 1) as $scrub_ok

| [ $p.replication[]?
    | . as $row
    | $row
    | annotated($s; "replication"; $now; $graceSeconds;
        (($row.enabled == true) and ($row.auto == true)
         and ((schedules_of($row) | length) > 0));
        (schedules_of($row));
        0;
        (later_epoch($row.job.timeFinished; $row.state.datetime));
        true;
        is_running($row.job.state)) ] as $replication

| [ $p.cloudSync[]?
    | . as $row
    | $row
    | annotated($s; "cloudSync"; $now; $graceSeconds;
        (($row.enabled == true) and ((schedules_of($row) | length) > 0));
        (schedules_of($row));
        0;
        (later_epoch($row.job.timeFinished; null));
        true;
        is_running($row.job.state)) ] as $cloudSync

| [ $p.snapshotTasks[]?
    | . as $row
    | $row
    | annotated($s; "snapshotTasks"; $now; $graceSeconds;
        (($row.enabled == true) and ((schedules_of($row) | length) > 0));
        (schedules_of($row));
        0;
        ($row.state.datetime | to_epoch);
        true;
        false) ] as $snapshotTasks

| ($p.pools // []) as $pools
| [ $p.scrubs[]?
    | . as $row
    | ($pools | map(select((.name // "") == ($row.pool // ""))) | .[0] // null) as $pool
    | ($pool.scan // null) as $scan
    | ($pool != null) as $found
    | (($scan != null)
       and ((($scan.function // "") | ascii_upcase) == "SCRUB")) as $is_scrub
    # A pool that answered with no scan has never been scrubbed. A pool whose
    # only scan is a RESILVER has lost the scrub timestamp, so that is unknown,
    # not never run, and must not age into a false overdue.
    | (if $is_scrub then ($scan.endTime | to_epoch) else null end) as $last
    | $row
    | annotated($s; "scrubs"; $now; $graceSeconds;
        (($row.enabled == true) and ((schedules_of($row) | length) > 0));
        (schedules_of($row));
        (if ($row.threshold | type) == "number"
         then ($row.threshold * 86400) else 0 end);
        $last;
        ($found and ($scan == null or $is_scrub));
        ($found and $scan != null
         and ((($scan.state // "") | ascii_upcase) == "SCANNING"))) ] as $scrubs

| [ ($replication[] | { kind: "replication", key: ("replication:" + (.id | tostring)), row: . }),
    ($cloudSync[]   | { kind: "cloudSync",   key: ("cloudSync:"   + (.id | tostring)), row: . }),
    ($snapshotTasks[] | { kind: "snapshotTasks", key: ("snapshotTasks:" + (.id | tostring)), row: . }),
    ($scrubs[]      | { kind: "scrubs",      key: ("scrubs:"      + (.id | tostring)), row: . }) ] as $rows

| [ $rows[]
    | select((.kind == "replication"    and $rep_ok)
             or (.kind == "cloudSync"   and $cs_ok)
             or (.kind == "snapshotTasks" and $snap_ok)
             or (.kind == "scrubs"      and $scrub_ok)) ] as $allowed

| (reduce $allowed[] as $r ({};
    .[$r.key] = {
      # A task that is not scheduled restarts its never-run grace when it is
      # enabled again, rather than inheriting the age of the disabled spell.
      firstSeenAt: (if $r.row.scheduled then $r.row.firstSeenAt else $now end),
      lastRunAt: $r.row.lastRunAt,
      overdue: ($r.row.overdue == true),
      lastNotifiedAt: (
        if (($r.row.overdue == true) and ($s[$r.key].overdue != true))
           or (($r.row.overdue != true) and ($s[$r.key].overdue == true))
        then $now
        else ($s[$r.key].lastNotifiedAt // $now) end)
    })) as $entries

# A section that did not answer keeps its previous entries: a blip must not
# read as every task recovering, and it must not restart the never-run grace.
| ($s | with_entries(select(
    (((.key | startswith("replication:"))   and ($rep_ok | not))
     or ((.key | startswith("cloudSync:"))  and ($cs_ok | not))
     or ((.key | startswith("snapshotTasks:")) and ($snap_ok | not))
     or ((.key | startswith("scrubs:"))     and ($scrub_ok | not)))))) as $stale

| {
    payload: ($p + {
      replication: $replication,
      cloudSync: $cloudSync,
      snapshotTasks: $snapshotTasks,
      scrubs: $scrubs
    }),
    protection: ($entries + $stale),
    decisions: {
      overdue: [ $allowed[]
                 | select(.row.overdue == true and ($s[.key].overdue != true))
                 | { kind: .kind, key: .key } ],
      recovered: [ $allowed[]
                   | select(.row.overdue != true and ($s[.key].overdue == true)
                            and (.row.lastRunAt != null)
                            and (.row.lastRunAt != ($s[.key].lastRunAt // null)))
                   | { kind: .kind, key: .key } ]
    }
  }
