# Derives the output check from the probe answer and the previous seen state.
# Input: nothing (run with jq -n). Inputs: --slurpfile payload (the payload
# protection-overdue.jq just annotated), --slurpfile seen (seen.json),
# --slurpfile probe ($WORK/output-probe.json), --argjson expect (the config's
# expectOutput), --arg now, one 0/1 answered flag per protection section, and
# --argjson normalizeOk.
#
# Output: { payload, output, decisions }.
#
# `payload` is the input with each covered, due row carrying `output`
# {state, written, snapshot} and `noData`. `output` is the next seen.output map,
# keyed `<section>:<id>`. `decisions` names the rows that just entered or left
# no-data.
#
# Why this pass exists instead of doing it in the views: the bar, the card and
# the toast must agree. One derivation is what makes that true. The pass runs
# after protection-overdue.jq because that pass supplies `scheduled`,
# `overdue` and `lastRunAt`; a probe answer is meaningless without them.
#
# A row is annotated only when it is due: in expectOutput, covered, scheduled,
# not overdue, and its last run is a terminal success with a timestamp. A due
# row with no answer (cold poll, cap skip, failed probe) is `unknown` and
# carries the previous noData forward, so an unavailable probe never reads as
# healthy.

def up: if type == "string" then ascii_upcase else "" end;

def local_rep:
  ((.direction // "" | up) == "PULL") or ((.transport // "" | up) == "LOCAL");

def covered($kind; $row):
  if $kind == "snapshotTasks" then true
  elif $kind == "replication" then ($row | local_rep)
  else false end;

def effective_state($row):
  if (($row.job.state // "") | type) == "string"
     and ($row.job.state // "") != ""
  then ($row.job.state | up)
  else (($row.state.state // "") | up) end;

def run_ok($row):
  (effective_state($row) == "SUCCESS" or effective_state($row) == "FINISHED")
  and ((($row.state.warnings // [])
        | if type == "array" then length else 0 end) == 0);

def due($row):
  ($row.scheduled == true)
  and ($row.overdue == false)
  and run_ok($row)
  and (($row.lastRunAt // null) != null);

def allows_empty($row):
  if ($row.allowEmpty | type) == "boolean" then $row.allowEmpty else true end;

# What the run produced, or why there is no answer. `answer` is true only when
# the row got an answer for this run, which is what advances lastRunAt.
# `attempt` is the probe attempt time, present on success and failure, absent on
# a cap skip or a run with no lastSnapshot.
def classify($row; $key; $probe; $prev):
  if (($prev.lastRunAt // null) == $row.lastRunAt)
     and ((["ok", "empty", "missing"] | index($prev.reason // "")) != null) then
    # This exact run already has a stored answer. The probe skips it on later
    # polls (lastRunAt matches), so the row must reuse the answer instead of
    # reading as unknown forever.
    { state: $prev.reason, written: ($prev.written // null),
      snapshot: ($prev.snapshot // null), answer: true, attempt: null }
  elif (($row.state.lastSnapshot // null) == null) then
    { state: "missing", written: null, snapshot: null,
      answer: true, attempt: null }
  else
    ($probe[$key] // null) as $pr
    | if $pr == null or (($pr.lastRunAt // null) != $row.lastRunAt) then
        { state: "unknown", written: null, snapshot: null,
          answer: false, attempt: null }
      elif ($pr.ok // false) != true then
        { state: "unknown", written: null, snapshot: null,
          answer: false, attempt: ($pr.attemptedAt // null) }
      elif ($pr.found // false) == true then
        ($pr.written // null) as $w
        | if ($w | type) == "number" and $w > 0 then
            { state: "ok", written: $w, snapshot: ($pr.snapshot // null),
              answer: true, attempt: ($pr.attemptedAt // null) }
          elif ($w | type) == "number" and $w == 0 then
            { state: "empty", written: 0, snapshot: ($pr.snapshot // null),
              answer: true, attempt: ($pr.attemptedAt // null) }
          else
            # Present, but the property was absent or unparseable: presence-only.
            { state: "ok", written: null, snapshot: ($pr.snapshot // null),
              answer: true, attempt: ($pr.attemptedAt // null) }
          end
      else
        # The query answered and the named snapshot is gone. Zettarepl deletes
        # an empty snapshot after the run when the task does not allow empty.
        if allows_empty($row) then
          { state: "missing", written: null, snapshot: ($pr.snapshot // null),
            answer: true, attempt: ($pr.attemptedAt // null) }
        else
          { state: "empty", written: 0, snapshot: ($pr.snapshot // null),
            answer: true, attempt: ($pr.attemptedAt // null) }
        end
      end
  end;

def annotate($row; $key; $probe; $prev):
  if due($row) then
    (classify($row; $key; $probe; $prev)) as $c
    | $row + {
        output: { state: $c.state, written: $c.written, snapshot: $c.snapshot },
        noData: (if $c.answer
                 then ($c.state == "empty" or $c.state == "missing")
                 else (($prev.noData // false) == true) end)
      }
  else $row end;

# The next map for one kind. A disabled or unscheduled task drops its entry;
# an overdue, failed or non-terminal task keeps the previous one; a due task
# either records the answer or keeps the previous noData while advancing only
# lastProbeAt on a failed attempt.
def next_entries($kind; $rows; $prev; $probe; $expect):
  reduce $rows[] as $row ({};
    ($row.id | if . == null then "" else tostring end) as $id
    | if $id == "" then .
      else
        ($kind + ":" + $id) as $key
        | if (($expect | index($key)) == null) or (covered($kind; $row) | not) then .
          else
            ($prev[$key] // null) as $old
            | if $row.scheduled != true then .
              elif due($row) then
                (classify($row; $key; $probe; $old)) as $c
                | if $c.answer then
                    .[$key] = {
                      noData: ($c.state == "empty" or $c.state == "missing"),
                      reason: $c.state,
                      written: $c.written,
                      snapshot: $c.snapshot,
                      lastRunAt: $row.lastRunAt,
                      lastProbeAt: ($c.attempt // ($old.lastProbeAt // null))
                    }
                  elif $c.attempt != null then
                    .[$key] = (($old // {}) + { lastProbeAt: $c.attempt })
                  elif $old != null then
                    .[$key] = $old
                  else . end
              elif $old != null then .[$key] = $old
              else . end
          end
      end);

def drop_kind($map; $kind):
  $map | with_entries(select((.key | startswith($kind + ":")) | not));

($payload[0]) as $p
| ($seen[0].output // {}) as $prev
| ($probe[0] // {}) as $probe
| ($expect // []) as $expect
| ($replicationOk == 1) as $rep_ok
| ($snapshotTasksOk == 1) as $snap_ok
| ($normalizeOk == 1) as $norm_ok

| [ $p.replication[]? as $row
    | ($row.id | if . == null then "" else tostring end) as $id
    | select($id != "")
    | ("replication:" + $id) as $key
    | if (($expect | index($key)) != null) and covered("replication"; $row)
      then annotate($row; $key; $probe; ($prev[$key] // {}))
      else $row end ] as $replication
| [ $p.snapshotTasks[]? as $row
    | ($row.id | if . == null then "" else tostring end) as $id
    | select($id != "")
    | ("snapshotTasks:" + $id) as $key
    | if (($expect | index($key)) != null) and covered("snapshotTasks"; $row)
      then annotate($row; $key; $probe; ($prev[$key] // {}))
      else $row end ] as $snapshotTasks

| (next_entries("replication"; $p.replication; $prev; $probe; $expect)) as $next_rep
| (next_entries("snapshotTasks"; $p.snapshotTasks; $prev; $probe; $expect)) as $next_snap

| ( $prev
    | if ($norm_ok and $rep_ok) then drop_kind(.; "replication") else . end
    | if ($norm_ok and $snap_ok) then drop_kind(.; "snapshotTasks") else . end
    | if ($norm_ok and $rep_ok) then . + $next_rep else . end
    | if ($norm_ok and $snap_ok) then . + $next_snap else . end
  ) as $next

| [ $next | to_entries[]
    | .key as $key
    | .value as $n
    | ($prev[$key] // null) as $o
    | ($o.noData // false) as $was
    | ($n.noData // false) as $is
    | select($was != $is)
    | { kind: ($key | split(":")[0]), key: $key,
        reason: (if $is then ($n.reason // "") else "ok" end) } ] as $changed

| {
    payload: ($p + { replication: $replication, snapshotTasks: $snapshotTasks }),
    output: $next,
    decisions: {
      noData:   [ $changed[] | select(.reason != "ok") ],
      dataBack: [ $changed[] | select(.reason == "ok") ]
    }
  }
