# TrueNAS plugin - milestone 4 protection recon

Date: 2026-09-14
Status: recon complete, ready for the M4 implementation plan
Machine: desk (h4ad)
Box: `https://nas.example:4433`, TrueNAS 25.10.6, self-signed certificate

## Purpose

A factual record of the protection endpoints and the run-now verbs, measured on
the live box before the milestone 4 plan is written. It implements nothing. A
claim below is a live measurement unless it is marked `reference only` or
`not verified`.

## Method

The key stays out of argv, `ps`, logs and this document. Each request ran as:

```bash
KEY=$(sed -n 's/^TRUENAS_API_KEY=//p' /home/h4ad/.config/omarchy/truenas/credentials)
curl -sk -o /tmp/opencode/out.json -w '%{http_code}' \
  --config <(printf 'header = "Authorization: Bearer %s"\n' "$KEY") \
  -H 'Content-Type: application/json' https://nas.example:4433/api/v2.0/<path>
jq . /tmp/opencode/out.json
```

The route list is the OpenAPI document the box serves at
`GET /api/v2.0/openapi.json` (6.3 MB in this build), which is authoritative for
this version. Write verbs were probed with a deliberately invalid id or pool
name, or with no body, so no real job started. The probe jobs that did get
created (1077, 1078, 1083, 1088, 1089, 1090) all failed on validation or on a
missing target, and their errors are quoted below. No scrub, replication, cloud
sync or snapshot task ran.

## Routes on this box

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v2.0/replication` | replication task list |
| POST | `/api/v2.0/replication/run` | run a replication task now |
| GET | `/api/v2.0/cloudsync` | cloud sync task list |
| POST | `/api/v2.0/cloudsync/id/{id}/sync` | run a cloud sync task now |
| GET | `/api/v2.0/pool/snapshottask` | periodic snapshot task list |
| POST | `/api/v2.0/pool/snapshottask/id/{id}/run` | run a snapshot task now |
| GET | `/api/v2.0/pool/scrub` | scrub task list |
| POST | `/api/v2.0/pool/scrub/run` | run a scrub if it is due |
| POST | `/api/v2.0/pool/scrub/scrub` | start, stop or pause a scrub |
| POST | `/api/v2.0/pool/id/{id}/scrub` | start, stop or pause a scrub by pool id |
| GET | `/api/v2.0/pool/snapshot` | snapshot list and count |

The obvious run paths for the two list routes, `/api/v2.0/cloudsync/sync` and
`/api/v2.0/pool/snapshottask/run`, both answer `404`. The run verb for a cloud
sync task is `/cloudsync/id/{id}/sync`, and for a snapshot task it is
`/pool/snapshottask/id/{id}/run`.

## Cross-cutting behaviours

- Dates inside the `state` and `job` objects are Mongo `{$date: epoch_ms}`
  objects. `share/normalize.jq` `to_iso` already accepts both that and ISO
  strings.
- A job method answers HTTP `200` with a bare integer job id. The OpenAPI return
  schema for these routes says `null`, which describes the eventual job result,
  not the wire response. This is the same shape M3 saw on the app writes.
- An unknown instance id is plain text `404: Not Found`; a missing key is plain
  text `401: Unauthorized`. Neither carries a JSON body. (Older builds returned
  `401 Unauthorized` too, as M1 recorded.)
- A body whose shape the route cannot map is JSON `{"message": "<attr> attribute
  expected."}` (for example a scrub run missing `name`). A bare array or bare
  integer where an object is expected is `{"message":"Endpoint accepts multiple
  params, object/dict expected."}`.
- Validation errors come back as `422` with a field-keyed object, for example
  `{"": [{"message": "Too many arguments (expected 1, found 2)", "errno": 22}]}`
  or `{"null": [{"message": "PeriodicSnapshotTask 999999 does not exist",
  "errno": 2}]}`.
- The job object, shared by `core/get_jobs` and the `job` field below, has
  `id, message_ids, method, arguments, transient, description, abortable,
  logs_path, logs_excerpt, progress{percent,description,extra}, result,
  result_encoding_error, error, exception, exc_info, state, time_started,
  time_finished, credentials`. Job `state` examples in the OpenAPI are
  `WAITING`, `RUNNING`, `SUCCESS`, `FAILED`, `ABORTED`. The `state` vocabulary
  for a replication or snapshot task is not enumerated anywhere in the API.
  Live values seen: `FINISHED` and `PENDING`.

## 1. Replication

`GET /api/v2.0/replication` returns an array. One task on this box.

Top-level fields and types (from the live row and the OpenAPI item schema):

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | task id |
| `name` | string | task label |
| `direction` | string | `PUSH` or `PULL` |
| `transport` | string | `LOCAL`, `SSH`, `SSH+NETCAT` |
| `source_datasets` | array of string | |
| `target_dataset` | string | |
| `recursive` | boolean | |
| `enabled` | boolean | |
| `auto` | boolean | true when driven by periodic snapshot tasks |
| `schedule` | object or null | `minute,hour,dom,month,dow,begin,end`, all strings |
| `restrict_schedule` | object or null | same shape |
| `only_matching_schedule` | boolean | |
| `retention_policy` | string | `SOURCE`, `CUSTOM`, `NONE` |
| `lifetime_value` | integer or null | |
| `lifetime_unit` | string or null | `HOUR`, `DAY`, `WEEK`, `MONTH`, `YEAR` |
| `lifetimes` | array | empty on the live row |
| `compression` | string or null | `LZ4`, `PIGZ`, `PLZIP` |
| `speed_limit` | integer or null | |
| `logging_level` | string or null | `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `retries` | integer | |
| `readonly` | string | `SET`, `REQUIRE`, `IGNORE` |
| `hold_pending_snapshots` | boolean | |
| `encryption` | boolean | |
| `ssh_credentials` | object or null | **secret** (keychain entry, may carry `private_key`) |
| `encryption_key` | string or null | **secret** |
| `state` | object | `{state, datetime, warnings[], last_snapshot}` |
| `job` | object or null | the last job, full job shape |
| `periodic_snapshot_tasks` | array | embedded snapshot tasks |

Sanitized sample:

```jsonc
[{
  "id": 1,
  "name": "storage-to-backup",
  "direction": "PUSH",
  "transport": "LOCAL",
  "source_datasets": ["storage/vm-root"],
  "target_dataset": "Backup/replica-storage",
  "recursive": false,
  "enabled": true,
  "auto": true,
  "schedule": null,
  "restrict_schedule": null,
  "retention_policy": "CUSTOM",
  "lifetime_value": 14,
  "lifetime_unit": "DAY",
  "retries": 5,
  "readonly": "SET",
  "state": {
    "state": "FINISHED",
    "datetime": { "$date": 1789355118000 },
    "warnings": [],
    "last_snapshot": "storage/vm-root@auto-daily-2026-09-14_00-05"
  },
  "job": {
    "id": 913,
    "method": "replication.run",
    "state": "SUCCESS",
    "progress": { "percent": 100, "description": "Sending 1 of 1: storage/vm-root@auto-daily-2026-09-14_00-05" },
    "error": null,
    "time_started": { "$date": 1789355101000 },
    "time_finished": { "$date": 1789355118000 }
  }
}]
```

### Cache

Cache `id, name, direction, transport, source_datasets, target_dataset,
recursive, enabled, auto, retention_policy, lifetime_value, lifetime_unit,
schedule, retries, state.state, state.datetime, state.warnings,
state.last_snapshot, job.state, job.time_finished, job.error`. Drop
`ssh_credentials`, `encryption_key`, `job.logs_excerpt` and `job.exception`
before the write: they carry keys, dataset paths and stack traces.

### Run now

`POST /api/v2.0/replication/run` with a **bare integer** body (the task id).
Response: a job id integer (asynchronous). A body of `{"id": 1}` is passed
through as one positional dictionary and fails `[EINVAL] id: Input should be a
valid integer`; the wire body is the id alone.

### Errors and quirks

- Invalid id: `200` and a job id, then the job fails
  `[ENOENT] None: Replication 999999 does not exist`.
- The task `state` is a nested object, not a string. Its `datetime` and the
  job times are `{$date}` objects.
- `auto` tasks carry `schedule: null`; the cron lives on the embedded
  `periodic_snapshot_tasks`, whose own `state` field is a **JSON-encoded
  string**, not an object. That string must be parsed a second time before use.
- `job.logs_excerpt` can be large and names datasets; never cache it.

## 2. Cloud sync

`GET /api/v2.0/cloudsync` returns an array. It is empty on this box, so the
field list below is `reference only` (OpenAPI item schema).

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | |
| `description` | string | task label |
| `path` | string | local path, `/mnt/...` |
| `credentials` | object | `{id,name,provider{...}}`, **secrets inside** |
| `attributes` | object | `bucket,folder,fast_list,region,storage_class,...` |
| `schedule` | object | `minute,hour,dom,month,dow`, no `begin`/`end` |
| `pre_script` / `post_script` | string | commands, not cached |
| `snapshot` | boolean | snapshot before backup |
| `enabled` | boolean | |
| `job` | object or null | the last job, full job shape |
| `locked` | boolean | a locked task cannot run |
| `transfers` | integer or null | |
| `direction` | string | `PUSH` or `PULL` |
| `transfer_mode` | string | `SYNC`, `COPY`, `MOVE` |
| `encryption` / `filename_encryption` | boolean | |
| `encryption_password` / `encryption_salt` | string | **secrets** |
| `create_empty_src_dirs` / `follow_symlinks` | boolean | |

There is no top-level `state` field. The last run lives in `job` (`job.state`,
`job.time_finished`, `job.error`). The design's "states, last run" for cloud
sync therefore reads the job, not a task field.

### Cache

Cache `id, description, path, enabled, direction, transfer_mode, schedule,
job.state, job.time_finished, job.error`. Drop `credentials` (it can carry an
S3 `secret_access_key`, an FTP/SFTP/WebDAV `pass`, an OAuth `token`),
`encryption_password`, `encryption_salt`, `pre_script`, `post_script` and
`job.logs_excerpt`.

### Run now

`POST /api/v2.0/cloudsync/id/{id}/sync` with no body or `{}`. An optional body
of `{"dry_run": false}` is accepted. Response: a job id integer (asynchronous).

### Errors and quirks

- Do not put `id` in the body. With `{"id": 999999}` the body leaks into the
  options object and the job fails
  `[EINVAL] cloud_sync_sync_options.id: Extra inputs are not permitted`.
- An invalid id with an empty or absent body gives `200` and a job id, then the
  job fails `[ENOENT] None: CloudSync 999999 does not exist`.
- `/cloudsync/sync` is `404`; the run route has the id in the path. A separate
  `/cloudsync/sync_onetime` exists and wants a whole task object
  (`cloud_sync_sync_onetime attribute expected.` when it is missing). M4 does
  not need it.

## 3. Periodic snapshot tasks

`GET /api/v2.0/pool/snapshottask` returns an array. Seven tasks live (ids 1, 2,
4, 5, 6, 7, 8).

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | |
| `dataset` | string | may be nested, for example `Backup/Default` |
| `recursive` | boolean | |
| `lifetime_value` | integer | |
| `lifetime_unit` | string | `HOUR`, `DAY`, `WEEK`, `MONTH`, `YEAR` |
| `enabled` | boolean | |
| `exclude` | array of string | |
| `naming_schema` | string | `auto-hourly-%Y-%m-%d_%H-%M` |
| `allow_empty` | boolean | |
| `schedule` | object | `minute,hour,dom,month,dow,begin,end`, all strings |
| `state` | object | `{state, datetime, last_snapshot}`, or `{state}` when pending |
| `vmware_sync` | boolean | |

Sanitized samples:

```jsonc
{ "id": 1, "dataset": "storage", "recursive": true, "enabled": true,
  "naming_schema": "auto-hourly-%Y-%m-%d_%H-%M",
  "lifetime_value": 2, "lifetime_unit": "DAY",
  "schedule": { "minute": "0", "hour": "*", "dom": "*", "month": "*",
                "dow": "*", "begin": "00:00", "end": "23:59" },
  "state": { "state": "FINISHED", "datetime": { "$date": 1789358400000 },
             "last_snapshot": "storage@auto-hourly-2026-09-14_01-00" } }

{ "id": 6, "dataset": "Backup", "recursive": true, "enabled": true,
  "state": { "state": "PENDING" } }
```

### Cache

Cache `id, dataset, recursive, enabled, lifetime_value, lifetime_unit,
naming_schema, allow_empty, schedule, state.state, state.datetime,
state.last_snapshot`.

### Run now

`POST /api/v2.0/pool/snapshottask/id/{id}/run` with **no body**. The route is
synchronous: an invalid id answers `422`
`{"null":[{"message":"PeriodicSnapshotTask 999999 does not exist","errno":2}]}`
instead of a job id. The OpenAPI documents the success result as `null`
(`not verified`, since running a real task creates a snapshot).

### Errors and quirks

- An empty object body is rejected with
  `422 {"":[{"message":"Too many arguments (expected 1, found 2)","errno":22}]}`.
  Send no body at all.
- `state` loses `datetime` and `last_snapshot` while the task is `PENDING`; the
  plugin must treat a missing `last_snapshot` as absent, never as empty text or
  a fabricated success.
- The embedded `periodic_snapshot_tasks` inside a replication row carry a
  different, stringified `state` (see section 1). Do not reuse one normalizer
  blindly for both.

## 4. Scrub tasks

`GET /api/v2.0/pool/scrub` returns an array. Two tasks live, one per pool.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | |
| `pool` | integer | numeric pool id |
| `pool_name` | string | `storage`, `Backup` |
| `threshold` | integer | days; `35` on both live rows |
| `description` | string | empty on both live rows |
| `enabled` | boolean | |
| `schedule` | object | `minute,hour,dom,month,dow`, no `begin`/`end` |

Sanitized sample:

```jsonc
{ "id": 1, "pool": 1, "pool_name": "storage", "threshold": 35,
  "description": "", "enabled": true,
  "schedule": { "minute": "00", "hour": "00", "dom": "*", "month": "*",
                "dow": "7" } }
```

The scrub row carries no run state. A pool's scrub progress and last result
live on `pool.scan`, which M1 already normalizes. Do not add a second scrub
state field.

### Cache

Cache `id, pool, pool_name, threshold, description, enabled, schedule`. Nothing
here is secret.

### Run now (two routes, different meanings)

- `POST /api/v2.0/pool/scrub/run` with `{"name": "<pool>"}` and an optional
  `{"threshold": <int>}` (default 35). This starts a scrub only if the last one
  was more than `threshold` days ago. An invalid pool name answers `404` with
  the JSON body `{"message": ""}`, an empty message. The success result is
  documented as `null` (`not verified`).
- `POST /api/v2.0/pool/scrub/scrub` with `{"name": "<pool>", "action":
  "START"|"STOP"|"PAUSE"}`. This is asynchronous and returns a job id. An
  invalid pool name gives `200` and a job id, then the job fails
  `[EZFS_NOENT] Pool __probe_no_such__ not found`.
- `POST /api/v2.0/pool/id/{id}/scrub` with `{"action": "START"|"STOP"|"PAUSE"}`
  is the same action keyed by numeric pool id.

For a "run now" button the async `pool/scrub/scrub` with `action: START` is the
honest verb: it returns a job id the panel can watch. `pool/scrub/run` is
due-gated and may quietly do nothing, which reads as a broken button.

### Errors and quirks

- `pool/scrub/run` missing `name` is `400 {"message":"name attribute
  expected."}`; a bare integer body is `400 {"message":"Endpoint accepts
  multiple params, object/dict expected."}`.
- The scrub `schedule` has no `begin`/`end` window, unlike the replication and
  snapshot task schedules. A shared schedule renderer must tolerate both.

## 5. Snapshots

`GET /api/v2.0/pool/snapshot` returns the full ZFS snapshot list, 298 rows on
this box. Each row is `id` (`dataset@snapname`), `dataset`, `name`,
`snapshot_name`, `pool`, `type` (`SNAPSHOT`), `createtxg` (a numeric string) and
a large `properties` object (dozens of ZFS properties per snapshot).

Sanitized sample:

```jsonc
{ "id": "Backup@auto-hourly-2026-09-13_18-47",
  "dataset": "Backup", "name": "Backup@auto-hourly-2026-09-13_18-47",
  "snapshot_name": "auto-hourly-2026-09-13_18-47",
  "pool": "Backup", "type": "SNAPSHOT", "createtxg": "841879",
  "properties": { "creation": { "value": "..." }, "used": { "value": "..." } } }
```

Query options that matter for a poll:

| Query | Result |
| --- | --- |
| `?count=true` | the bare number `298` |
| `?count=true&dataset=storage` | `49` (exact dataset) |
| `?count=true&pool=storage` | `140` (whole pool, child datasets included) |
| `?limit=1&offset=297` | one row (paging works) |
| `?sort=-createtxg` | `422 {"options.sort":[{"message":"Extra inputs are not permitted","errno":22}]}` |
| `?select=id,dataset,snapshot_name` | `[]` (unknown params are treated as filters, not options) |
| `?extra.retrieve_properties=false` | still returns `properties`; does not slim the row |

### Cache

Fetch the count, not the list. `GET /api/v2.0/pool/snapshot?count=true` answers
a number in one small response; the full list is heavy (298 rows and a
`properties` blob each). If M4 wants per-pool figures, issue one count per pool
with `?count=true&pool=<name>`. Never fetch the full list on a poll, and never
cache `properties`.

### Run now

None. Snapshots are created by a snapshot task; M4's run verb for snapshots is
the snapshottask run in section 3. The route also exposes
`/pool/snapshot/{clone,hold,release,rollback,rename,delete}`; M4 does not use
them.

### Errors and quirks

- There is no sortable REST query: the `sort` parameter is rejected on this
  build. Sort client-side.
- `dataset` matches one dataset; `pool` matches every dataset under that pool.
  They are not interchangeable.
- Unknown query parameters act as row filters, so a typo narrows the list
  silently instead of erroring.

## Write verbs at a glance

| Verb | Method and path | Body | Response |
| --- | --- | --- | --- |
| run replication | `POST /replication/run` | bare integer id | job id (async) |
| run cloud sync | `POST /cloudsync/id/{id}/sync` | none or `{}` | job id (async) |
| run snapshot task | `POST /pool/snapshottask/id/{id}/run` | none | null (sync) |
| run scrub if due | `POST /pool/scrub/run` | `{"name":..,"threshold":..}` | null (sync) |
| scrub action | `POST /pool/scrub/scrub` | `{"name":..,"action":..}` | job id (async) |
| scrub action by id | `POST /pool/id/{id}/scrub` | `{"action":..}` | job id (async) |

Every async verb follows the M3 app-write rule: the panel forces a re-poll and
reads the state back rather than trusting the returned id.

## Probe commands

The read calls (the recipe at the top with the path substituted):

```bash
curl ... https://nas.example:4433/api/v2.0/replication
curl ... https://nas.example:4433/api/v2.0/cloudsync
curl ... https://nas.example:4433/api/v2.0/pool/snapshottask
curl ... https://nas.example:4433/api/v2.0/pool/scrub
curl ... 'https://nas.example:4433/api/v2.0/pool/snapshot?count=true'
curl ... 'https://nas.example:4433/api/v2.0/pool/snapshot?count=true&pool=storage'
curl ... https://nas.example:4433/api/v2.0/openapi.json
```

The write probes, all with a target that does not exist:

```bash
curl -X POST --data '999999'              .../api/v2.0/replication/run
curl -X POST                              .../api/v2.0/cloudsync/id/999999/sync
curl -X POST --data '{}'                  .../api/v2.0/cloudsync/id/999999/sync
curl -X POST                              .../api/v2.0/pool/snapshottask/id/999999/run
curl -X POST --data '{"name":"nope"}'     .../api/v2.0/pool/scrub/run
curl -X POST --data '{"name":"nope","action":"START"}' .../api/v2.0/pool/scrub/scrub
curl -X POST --data '{"id":999999}'       .../api/v2.0/replication/run
curl -X POST --data '{"id":999999}'       .../api/v2.0/pool/snapshottask/id/999999/run
```

The resulting job errors were read with
`GET /api/v2.0/core/get_jobs?id=<id>`.

## Could not verify, and why

- Cloud sync field presence and types: the box has no cloud sync tasks, so the
  list is empty. The field table is from the OpenAPI schema the box serves,
  marked `reference only`. A disposable cloud sync task would confirm it.
- Successful results of the synchronous verbs (`replication` is async, but
  `pool/scrub/run` and `pool/snapshottask/id/{id}/run` are sync). Running either
  for real starts a scrub or creates a snapshot, which the brief ruled out. The
  documented result is `null`; the invalid-input shapes were measured instead.
- The replication and snapshot task `state` vocabulary outside `FINISHED` and
  `PENDING`. The API does not enumerate it, and the live tasks were settled.
- Whether `pool/scrub/run` reports a job id on a *valid, due* pool. Its invalid
  name answered `404` synchronously, which is the evidence it is not a job.
- A non-self-signed TLS setup: the box uses a self-signed certificate, so only
  the `-k` path was exercised.
