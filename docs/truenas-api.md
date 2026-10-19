# TrueNAS API surface

The REST `/api/v2.0` endpoints this plugin reads and writes, the wire shapes it
consumes, and the rules that keep an unread value from becoming a fake zero.

Sources: the versioned API references at <https://api.truenas.com/v25.04.2/> and
<https://api.truenas.com/v25.10/>, plus live probes against TrueNAS SCALE 25.10.6
on 2026-09-13 and 2026-09-14. For routes with a JSON-RPC equivalent, the method
name is the target of the migration in
[websocket-migration.md](websocket-migration.md).

## Transport and auth

One header, `Authorization: Bearer <api-key>`, on every request. The base URL is
the user's own NAS, `https://<host>[:<port>]`, and the REST tree hangs off
`/api/v2.0`. A shell script with `curl` and `jq` is enough; there is no session
or cookie handling.

The key is passed to `curl` through a `--config -` document on stdin, never in
`argv`, `ps`, `shell.json` or a log line. `bin/truenas-lib.sh` `tn_http_request`
builds `header = "Authorization: Bearer <key>"`, escaping `\` and `"` because
curl processes backslash escapes inside a quoted config value and would
otherwise silently send the wrong key.

Response bodies and the documents derived from them follow the same rule inside
the poll: they reach `jq` as files or on stdin (`--slurpfile`, `--rawfile`),
never as an argument, because an argv word is world-readable through
`/proc/<pid>/cmdline`. See "Private data on a command line" in
[pitfalls.md](pitfalls.md).

TrueNAS revokes API keys sent over plain HTTP, so the base must be `https`. A
self-signed certificate is the norm, which is why `insecureTLS` exists; see
[pitfalls.md](pitfalls.md).

## REST is deprecated: the `tn_http_request` seam

REST `/api/v2.0` was deprecated in TrueNAS 25.04 and is removed in 26. The
replacement is versioned JSON-RPC 2.0 over WebSocket at `/api/current`, where
`GET /api/v2.0/system/info` is the `system.info` method, `GET /api/v2.0/alert/list`
is `alert.list`, `GET /api/v2.0/pool` is `pool.query`, and the alert writes are
`alert.dismiss` / `alert.restore`.

Every call goes through one helper, `tn_http_request` (reached as `tn_http_get`).
`tn_dialect()` reports the generation a poll used, `rest-v2.0` today, and the
poll records it in `state.connection.dialect`. Migrating to the websocket API is
a change to that one function and a websocket client, not a rewrite of every
endpoint. What the seam does not cover is in
[websocket-migration.md](websocket-migration.md).

## Read paths

| Purpose | Method | REST path | JSON-RPC method |
| --- | --- | --- | --- |
| version, hostname, memory, uptime | GET | `/api/v2.0/system/info` | `system.info` |
| active and dismissed alerts | GET | `/api/v2.0/alert/list` | `alert.list` |
| pools, capacity and scrub | GET | `/api/v2.0/pool` | `pool.query` |
| disk inventory and pool mapping | POST | `/api/v2.0/disk/details` | |
| disk temperatures | POST | `/api/v2.0/disk/temperatures` | |
| service list | GET | `/api/v2.0/service` | |
| app list | GET | `/api/v2.0/app` | |
| replication tasks | GET | `/api/v2.0/replication` | |
| cloud sync tasks | GET | `/api/v2.0/cloudsync` | |
| snapshot tasks | GET | `/api/v2.0/pool/snapshottask` | |
| scrub tasks | GET | `/api/v2.0/pool/scrub` | |
| SMB shares | GET | `/api/v2.0/sharing/smb` | |
| NFS exports | GET | `/api/v2.0/sharing/nfs` | |
| iSCSI targets | GET | `/api/v2.0/iscsi/target` | |
| network interfaces | GET | `/api/v2.0/interface` | |

## Write paths

| Purpose | Method | REST path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| dismiss an alert | POST | `/api/v2.0/alert/dismiss` | `{"uuid":…}` | `null` on 2xx |
| restore a dismissed alert | POST | `/api/v2.0/alert/restore` | `{"uuid":…}` | `null` on 2xx |
| service control | POST | `/api/v2.0/service/{start,stop,restart}` | `{"service":"ups"}` | `true` (synchronous) |
| app control | POST | `/api/v2.0/app/{start,stop,redeploy}` | `{"app_name":"appc"}` | a job id (asynchronous) |
| run replication | POST | `/api/v2.0/replication/run` | bare integer id | a job id |
| run cloud sync | POST | `/api/v2.0/cloudsync/id/{id}/sync` | none | a job id |
| run snapshot task | POST | `/api/v2.0/pool/snapshottask/id/{id}/run` | none | `null` (synchronous) |
| scrub action | POST | `/api/v2.0/pool/scrub/scrub` | `{"name":<pool>,"action":"START"}` | a job id |

Alert writes are reached through `bin/truenas-api`, one verb per call, JSON on
stdout. Both require the `ALERT_LIST_WRITE` role; the reads need
`ALERT_LIST_READ`. Every write is one queued process followed by a forced
re-poll, so the panel reads the NAS back rather than trusting the verb's stdout.
Dismiss and every service, app and protection control sit behind a confirmation.

## `GET /api/v2.0/system/info`

Slow-moving, so it rides the meta cache rather than the fast poll. Success is a
non-empty JSON object; anything else is a section failure, not a quiet NAS.
Fields `share/normalize.jq` consumes:

| Field | Type | Use |
| --- | --- | --- |
| `hostname` | string | Health header |
| `version` | string | Health header, `connection.version` |
| `uptime_seconds` | number | Health uptime |
| `cores` | number | Health |
| `physmem` | number | Health (bytes, formatted binary) |
| `loadavg` | array of number | Health |

The route also carries `buildtime`, `boottime` and `datetime` as `{$date}`
objects, which the plugin does not read, and `uptime` as a preformatted string,
which is not used because it cannot be aged.

## `GET /api/v2.0/alert/list`

Returns a JSON array of every current alert, active and dismissed. An alert as
the poller normalizes it:

```jsonc
{
  "uuid": "11111111-2222-3333-4444-555555555555", // falls back to id
  "level": "critical",                            // bucketed, lower-case
  "text": "Pool storage state is DEGRADED",
  "formatted": "Pool storage state is DEGRADED",
  "node": "Controller A",
  "datetime": "2026-08-21T14:28:00Z",             // wire {$date} or ISO
  "dismissed": false,
  "dismissable": true
}
```

Fields consumed: `uuid` (falling back to `id`), `level`, `formatted` (falling
back to `text`), `text`, `node`, `datetime`, `dismissed`, and `dismissable`
(treated as dismissable unless it is explicitly `false`). `source`, `klass`,
`args` and `key` are not read.

`level` is free text on the wire, not an enum, so it is upper-cased and bucketed
rather than compared literally. Worst first:

| Wire `level` | Bucket |
| --- | --- |
| `CRITICAL`, `ALERT`, `EMERGENCY` | `critical` |
| `ERROR` | `error` |
| `WARNING` | `warning` |
| `INFO` | `info` |
| `NOTICE` | `notice` |
| anything else | `notice` |

An unrecognized level becomes `notice`, never dropped: a level a TrueNAS build
grew that this list has not heard of is still an alert, and silently dropping it
is the one lie that matters. `counts` is computed from non-dismissed alerts only;
dismissed rows stay in `alerts` (flagged) and are counted as `dismissed`, because
a row that disappears when you silence it is how a person loses track of what
they muted.

## `GET /api/v2.0/pool`

Returns a JSON array of imported pools. Fields consumed:

| Field | Type | Use |
| --- | --- | --- |
| `name` | string | Pool identity |
| `status` | string | Worst-pool word, tint |
| `healthy` | boolean | Trusted when present, else `status == "ONLINE"` |
| `size` | number | `usedPct` denominator |
| `allocated` | number | `usedPct` numerator, bar |
| `free` | number | Bar |
| `fragmentation` | number or numeric string | Pools view |
| `scan` | object or absent | Scrub state and age; `null` when absent |
| `topology.data[].stats` | object | vdev read/write/checksum error counts |
| `error_count` | object | Pool-level errors, preferred when present |

`status` vocabulary: `ONLINE`, `DEGRADED`, `FAULTED`, `OFFLINE`, `UNAVAIL`,
`REMOVED`. Healthy is `ONLINE` only. An unknown status ranks worst, ahead of
`FAULTED`, in `Model.poolStatusRank`: "I cannot tell" must never sort below a
known good pool.

`scan` is carried through only when present. A pool with no scrub on record is
`null`, never a fabricated `"FINISHED"`. Its `start_time` / `end_time` follow the
datetime rule below; `percentage` and `errors` are coerced to numbers.

`usedPct` is `(allocated / size * 100)` rounded to one decimal, and `null` when
`size` is `0` or absent, because a bar drawn at `0%` reads as "empty", which is a
claim the poll cannot make.

## Disks and temperatures

`disk/temperatures` is POST-only (a GET answers `405`); `disk/details` is used as
a POST here. Verified against the live 25.10.6 on 2026-09-13:

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| disk inventory and pool mapping | POST | `/api/v2.0/disk/details` | `{"type":"USED"}` | JSON array, one object per disk; `imported_zpool` names the pool |
| temperatures and thresholds | POST | `/api/v2.0/disk/temperatures` | `{"name":["sda",…],"include_thresholds":true}` | JSON object `{"sda":[38.0,60.0],…}` |

Traps, each observed on that box unless marked otherwise:

- `GET /api/v2.0/disk/temperatures` is `405 Method Not Allowed`; the route is
  POST-only.
- The parameter is **`name`** (singular, an array), not `names`: an object
  carrying `names` is rejected with `not expected: names`.
- A bare-array body is rejected with `Endpoint accepts multiple params`; the
  names have to be wrapped in an object.
- `{"type":"BOTH"}` on `disk/details` answers a `{used,unused}` object instead of
  an array. The plugin uses `USED`: the array shape is simpler, and on the live
  box every disk is in use.
- With `include_thresholds:true` a value is normally `[tempC, criticalC]`. A bare
  number is the supported shape for a disk that reports no threshold (a shape
  rule, not a live probe; `share/normalize.jq` handles both). The missing
  threshold stays `null`, never `0`.
- The pool mapping is `imported_zpool` on `disk/details` (the plain `/disk` route
  has `"pool":null` on every row and is not used). Observed: `nvme0n1→storage`,
  `sda,sdb→boot-pool`, `sdc,sdd→Backup`.
- The rows also carry serials, identifiers and lunids, which the plugin never
  stores (see the caches below).

**SMART test results are not available on 25.04+.** `GET
/api/v2.0/smart/test/results` answers `404` on the live 25.10.6, and both API
references list no `smart.*` method at all, so SMART tests were removed after
24.10. The plugin ships temperature notifications only; a drive health feature
has to find another signal.

## Services and apps

`/service` and `/app` are read whole on the meta cadence; there is no query
route, so both lists are filtered client-side. Verified against the live 25.10.6
on 2026-09-13:

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| service list | GET | `/api/v2.0/service` | none | JSON array, rows `{id, service, enable, state, pids}` |
| app list | GET | `/api/v2.0/app` | none | JSON array, rows with the fields below |
| service control | POST | `/api/v2.0/service/{start,stop,restart}` | `{"service":"ups"}` | `200` and the body `true` (synchronous) |
| app control | POST | `/api/v2.0/app/{start,stop,redeploy}` | `{"app_name":"appc"}` | `200` and a job id number (asynchronous) |

Findings that constrain the design:

- Service writes answer `true` synchronously; app writes answer a job id and run
  asynchronously. A forced re-poll after an app write may still show the old
  state until the job lands. That is honest: the panel reads the NAS back and the
  next poll catches up. It never fabricates "starting".
- A service control `2xx` whose body is the JSON boolean `false` is the NAS
  accepting the request but the service not changing, so `bin/truenas-api` fails
  it as `action_failed`. A `null` (alert dismiss/restore), `true` (a landed
  service write) or a job id (an app write) `2xx` is an accepted write.
- A service control body missing `service` is `400 {"message":"service attribute
  expected."}`; an unknown service name is `404 {"message":"<name>"}`. An app
  body missing `app_name` is `400 {"message":"app_name attribute expected."}`.
  The `app/start` route with an empty body answered `200` with a failed job
  (`[EINVAL] app_name: Input should be a valid string`), so the caller always
  sends `app_name`.
- `POST /api/v2.0/app/restart` is `404`: there is no app restart route. The
  restart-like verb is `POST /api/v2.0/app/redeploy`. `POST /api/v2.0/app/query`
  is `404` too: the list is fetched whole and filtered client-side.
- `POST /api/v2.0/service/reload` exists but is not shipped.
- The app row carries `title`, `app_version`, `train`, `home` and `icon` (icon is
  `null` for a custom app) under `metadata`, plus `human_version` (e.g.
  `16.0.4-rootless_1.2.39`), `version`, `custom_app`, `upgrade_available`,
  `migrated`, `portals` (`{"Web UI":"http://…"}` or `{}`), `notes` and
  `active_workloads.containers`. `notes` can be tens of kilobytes: it is never
  cached and never enters `state.json`.

## Protection

Four list routes and four run verbs. Everything below is a live measurement
against TrueNAS 25.10.6 on 2026-09-14.

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| replication list | GET | `/api/v2.0/replication` | none | JSON array; row has nested `state{state,datetime,warnings,last_snapshot}`, `job|null`, `schedule|null` |
| cloud sync list | GET | `/api/v2.0/cloudsync` | none | JSON array (empty on this box); no top-level `state`, the last run is `job` |
| snapshot task list | GET | `/api/v2.0/pool/snapshottask` | none | JSON array; row has `state{state,datetime,last_snapshot}` and `naming_schema`; `PENDING` has no `datetime` |
| scrub task list | GET | `/api/v2.0/pool/scrub` | none | JSON array; rows `{id,pool,pool_name,threshold,enabled,schedule}` and no run state |
| run replication | POST | `/api/v2.0/replication/run` | bare integer id | async job id |
| run cloud sync | POST | `/api/v2.0/cloudsync/id/{id}/sync` | none or `{}` | async job id |
| run snapshot task | POST | `/api/v2.0/pool/snapshottask/id/{id}/run` | none | `null` (sync) |
| scrub action | POST | `/api/v2.0/pool/scrub/scrub` | `{"name":<pool>,"action":"START"}` | async job id |

Findings that constrain the design:

1. `POST /replication/run` with `{"id":1}` fails `[EINVAL] id: Input should be a
   valid integer`; the wire body is the bare integer, so this is the one write
   whose body is not a one-key object.
2. A body on `cloudsync/id/{id}/sync` leaks into the options object
   (`{"id":…}` fails `cloud_sync_sync_options.id: Extra inputs are not
   permitted`), so the sync verb sends no body with the id in the path.
3. `pool/snapshottask/id/{id}/run` rejects an empty object (`Too many arguments
   (expected 1, found 2)`), so the snapshot verb sends no body at all, with the
   id in the path. An invalid id answers `422` synchronously rather than a job
   id, which is how the route is told from the async ones.
4. `pool/scrub/run {"name":…}` is due-gated: it starts a scrub only when the last
   one was more than `threshold` days ago, and may quietly do nothing. The plugin
   uses `pool/scrub/scrub {"name":…,"action":"START"}` instead, which returns a
   job id the panel can watch. A missing `name` is `400 {"message":"name
   attribute expected."}`; an unknown pool is `404 {"message":""}`.
5. The scrub row carries no run state. A pool's scrub progress and last result
   live on `pool.scan`, which the Pools view already normalizes; there is no
   second scrub state field.
6. `GET /pool/snapshot` is not read. The full list is 298 heavy rows with a
   `properties` blob each, and a per-poll `?count=true` would spend a request for
   a figure no view needs. The periodic snapshot tasks are the snapshot section.
7. Dates inside `state` and `job` are Mongo `{$date: epoch_ms}` objects;
   `share/normalize.jq` `to_iso` accepts them. `state.datetime` and
   `job.time_finished` become ISO strings.
8. The replication `state` is a nested object, not a string; its `warnings` list
   is a failure signal even when the job state is `SUCCESS`. Cloud sync has no
   task state at all, only `job`.

## Shares and network

Four read-only list routes on the meta cadence. Everything below is a live
measurement against TrueNAS 25.10.6 on 2026-09-14. There is no write and no
notification for shares or network.

| Purpose | Method | Path | Observed answer |
| --- | --- | --- | --- |
| SMB shares | GET | `/api/v2.0/sharing/smb` | JSON array; three shares on this box (`default`, `backup`, `media`) |
| NFS exports | GET | `/api/v2.0/sharing/nfs` | JSON array; one export; the read-only flag is `ro` |
| iSCSI targets | GET | `/api/v2.0/iscsi/target` | JSON array; empty on this box |
| network interfaces | GET | `/api/v2.0/interface` | JSON array; one `PHYSICAL` interface; link and media live under `state` |

Findings that constrain the design:

1. **The interface route is `/interface`, not `/network/interface`** (the latter
   is `404`). `link_state`, `media_type` and `active_media_subtype` live under
   the nested `state` object, so a jq path that asks for `.link_state` on the
   top-level interface silently yields `null`. The row uses `state.aliases` (the
   runtime addresses, with `broadcast` dropped and the link-local IPv6 kept), not
   the top-level configured `aliases`.
2. **WebDAV is dropped.** `/api/v2.0/sharing/webdav` and `/api/v2.0/webdav` are
   both `404` `text/plain`, and neither the 25.04 nor the 25.10 reference lists a
   `webdav` method, so there is no source for it.
3. **SMB sessions are dropped.** `/api/v2.0/smb/status` is `404` and the `smb`
   namespace exposes only `smb.config`, `smb.update`, `smb.bindip_choices` and
   `smb.unixcharset_choices`.
4. **iSCSI is not a share.** The collection is `/api/v2.0/iscsi/target`, not under
   `/sharing`. The box has zero targets, so the iSCSI fixture is synthetic from
   the v25.10.5 `iscsi.target.query` schema and is marked as such; the first box
   with a target is the first real measurement.
5. **Two share vocabularies.** SMB calls the read-only flag `readonly`; NFS calls
   it `ro`. One normalizer row per type: `smb_norm`, `nfs_norm`, `iscsi_norm`.
   NFS `ro` is written as `readonly` so the two types present one name to the UI,
   and the iSCSI row carries only `id`, `name`, `alias`, `mode` (a target has no
   enabled, locked or path field).
6. **`shares` is rows, not counts.** The state holds `{smb:[],nfs:[],iscsi:[]}`;
   a count is the list's `.length` and is only trusted when no warning names the
   section.

A create route that fails model validation answers `422` with a JSON document,
not the `400 {"message": ...}` shape:

```
POST /api/v2.0/sharing/smb
{"data": [{"message": "Input should be a valid dictionary or instance of SmbShareCreate", "errno": 22}]}
```

`tn_error_message` surfaces the first keyed message from that shape (for example
`{"null":[{"message":"…"}]}` on a snapshot-task run) instead of rendering an
empty sentence. The plugin is read-only for shares and network and never sends
one.

## Not verified live

- **The iSCSI target row shape.** The live box has zero iSCSI targets, extents,
  portals, target-extent maps and initiators; the shape comes from the v25.10.5
  reference, and `tests/fixtures/iscsi-target.json` is synthetic and marked so.
- **`state.link_state` values other than `LINK_STATE_UP`.** Only `enp4s0` in
  `LINK_STATE_UP` was observed; `LINK_STATE_DOWN` and `LINK_STATE_UNKNOWN` come
  from the TrueNAS enum, not a live probe.
- **Bridge, VLAN and link-aggregation interfaces.** Only one `PHYSICAL` interface
  exists. The normalizer reads the same nested paths for every type, so an
  unknown shape degrades to empty strings, not a crash.
- **A locked share.** No locked dataset exists on the box, so `locked` was only
  ever seen `false`.

## Cross-cutting rules

### A datetime is a string or `{$date}`

TrueNAS writes timestamps two ways on different routes: an ISO-8601 string on
some, and Mongo's `{"$date": <epoch_ms>}` on others (`system/info.datetime`,
`alert.datetime` on the ZFS routes). `share/normalize.jq` `to_iso` accepts either
and emits an ISO string, or `null`. A raw object must never reach a QML binding
that expects a date.

### Numbers arrive as numeric strings

Some numeric fields (for example pool `fragmentation`) come back quoted. The
normalizer runs `tonumber? // null` over every numeric it consumes, so `"31"` and
`31` are one number and a non-numeric is `null` rather than a fabricated zero.

### A 200 is not success until the body has the promised shape

A route that does not exist can still answer `200` with HTML or an empty object.
`bin/truenas-poll` `expect_shape` checks `alert/list`, `pool` and `disk/details`
are arrays; `system/info` is a non-empty object; `disk/temperatures` an object;
and the service, app, protection, share and interface lists arrays of objects, so
a bare `null` entry is a failed section rather than a nameless card. A
wrong-shaped body is a section failure. Trusting the status code alone would
report a healthy NAS with zero alerts, which is the one lie that matters.

`tn_classify` reads the status code before the body, so an empty-body `401` is
`unauthenticated` and a `404` is `not_found` rather than "not JSON"; it treats
`202` as success and keeps `not_json` for a `2xx` with a non-JSON body. A valid
JSON value classifies from the status code, so a `2xx` body of `false` or `null`
is not "not JSON", and an empty non-2xx body is `http_<code>` rather than
`not_json`. `401` means `unauthenticated`, `403` `forbidden`, `5xx`
`server_error`.

### The rate limit and the two cadences

TrueNAS allows roughly 20 authenticated requests per 60 s, then a 10-minute
cooldown, and every route here is authenticated. A poll therefore never hits
every endpoint:

- every poll (`pollSeconds`, floor 15, default 30): `alert/list` and `pool`;
- every `notify.metaMaxAgeSeconds` (default 300): `system/info`, then
  `disk/details` and `disk/temperatures` (the temperatures request is built from
  the names the details call returned, so a failed details call skips it), then
  `service`, `app`, `sharing/smb`, `sharing/nfs`, `iscsi/target`, `interface`,
  `replication`, `cloudsync`, `pool/snapshottask` and `pool/scrub`.

A cold poll, with no fresh meta, spends fifteen requests: `alert/list`, `pool`,
`system/info`, `disk/details`, `disk/temperatures`, `service`, `app`,
`sharing/smb`, `sharing/nfs`, `iscsi/target`, `interface`, `replication`,
`cloudsync`, `pool/snapshottask` and `pool/scrub`. A warm poll, with a fresh meta
cache, spends two: `alert/list` and `pool`.

The slow set is cached in `~/.local/state/omarchy/truenas/meta.json` with a
`fetchedAt`, and `truenas-poll --force-meta` refetches regardless (used after a
write). The cache holds only the wire fields the normalizer consumes, under their
wire names, so secrets and heavy blobs never reach disk:

- disks keep `name`, `model`, `type`, `size`, `imported_zpool`, `bus`; serials,
  identifiers and lunids are dropped, and the temperatures map is cached as the
  wire wrote it.
- services drop `pids`; apps drop `notes` and the workload details.
- protection keeps `state` as `{state, datetime, warnings, last_snapshot}` or
  `null`, `job` as `{state, time_finished, error}` or `null`, and the schedule
  whitelisted to the seven cron keys. Replication `ssh_credentials` and
  `encryption_key`, `job.logs_excerpt` and `job.exception`, and cloud sync
  `credentials`, `encryption_password`, `encryption_salt`, `pre_script` and
  `post_script` are dropped.
- shares drop SMB `audit` and `options`, NFS `hosts`, `networks` and `security`,
  and iSCSI `groups` and `iscsi_parameters`.
- interfaces keep the nested `state` reduced to the four keys the normalizer
  reads; every MAC (`link_address`, `permanent_link_address`,
  `hardware_link_address`) is dropped.

Meta advances only when every section and normalization succeeded. A failed
section leaves the previous `meta.json` byte-for-byte intact, and an older meta
without a key reads as stale once, refetches once and self-heals.

## Deep links into the NAS UI

TrueNAS 25.04 serves the app under `/ui`. `Links.js` builds every URL from the
configured base and admits a server-supplied URL only through `safeUrl`, whose
origin gate requires the character after the base to be `/`, `?`, `#` or the end
of the string. A prefix test is not an origin test.

| Target | Path |
| --- | --- |
| Dashboard | `/ui/dashboard` |
| System (Health) | `/ui/system` |
| Storage (Pools) | `/ui/storage` |
| Apps | `/ui/apps` |
| Shares | `/ui/sharing` |
| Alerts | `/ui/alerts` |

Alerts are not a route in 25.04: the topbar bell opens a panel over whatever page
is showing, so `/ui/alerts` lands on the dashboard, which is where the bell
lives.

## Verification status

The endpoint shapes above are taken from the 25.04.2 and 25.10 references and
encoded in `share/normalize.jq`, and the test fixtures (`tests/fixtures/`) are
sanitized snapshots of those shapes plus synthetic failure states (a degraded
pool with checksum errors and a scrub on record, alert levels across the buckets,
`401`, `500`, unreachable, and a synthetic iSCSI target row). Every route above
was confirmed against a live TrueNAS 25.10.6 on 2026-09-13 and 2026-09-14 except
the ones listed under "Not verified live". A field the live box did not exercise
is still a claim to re-measure, not a fact to quote.
