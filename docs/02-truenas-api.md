# TrueNAS API surface

Sources: the versioned API references at <https://api.truenas.com/v25.04.2/>
and <https://api.truenas.com/v25.10/> (method names, parameter shapes and the
REST deprecation note), and live probes against the installed TrueNAS SCALE
25.10.6 on 2026-09-13. The REST paths below are the ones a poll reads; for the
milestone-1 routes the JSON-RPC method in brackets is the same operation under
the new API, and the migration target.

## Transport and auth

One header, `Authorization: Bearer <api-key>`, on every request. Base URL is the
user's own NAS, `https://<host>[:<port>]`, and the REST tree hangs off
`/api/v2.0`. A shell script with `curl` and `jq` is enough; there is no session
or cookie handling.

The key is passed to `curl` through a `--config -` document on stdin, never in
`argv`, `ps`, `shell.json` or a log line: `bin/truenas-lib.sh` `tn_http_request`
builds `header = "Authorization: Bearer <key>"`, escaping `\` and `"` because
curl processes backslash escapes inside a quoted config value and would
otherwise silently send the wrong key.

TrueNAS revokes API keys sent over plain HTTP, so the base must be `https`. A
self-signed certificate is the norm, which is why `insecureTLS` exists; see
`docs/11-pitfalls.md`.

## REST is deprecated: the `tn_call` / `tn_dialect` seam

REST `/api/v2.0` was deprecated in TrueNAS 25.04 and is removed in 26. The
replacement is versioned JSON-RPC 2.0 over WebSocket at `/api/current`, where
`GET /api/v2.0/system/info` is the `system.info` method, `GET /api/v2.0/alert/list`
is `alert.list`, `GET /api/v2.0/pool` is `pool.query`, and the alert writes are
`alert.dismiss` / `alert.restore`.

Every call in this repo goes through one helper, `tn_http_request` (reached as
`tn_http_get`; the design names this shim `tn_call`). `tn_dialect()` reports the
generation a poll used -- `rest-v2.0` today -- and the poll records it in
`state.connection.dialect`. Migrating to the websocket API is a change to that
one function and a websocket client, not a rewrite of every endpoint.

## Endpoints milestone 1 uses

| Purpose | Method | REST path | JSON-RPC method |
| --- | --- | --- | --- |
| version, hostname, memory, uptime | GET | `/api/v2.0/system/info` | `system.info` |
| active and dismissed alerts | GET | `/api/v2.0/alert/list` | `alert.list` |
| pools, capacity and scrub | GET | `/api/v2.0/pool` | `pool.query` |
| dismiss an alert | POST | `/api/v2.0/alert/dismiss` | `alert.dismiss` |
| restore a dismissed alert | POST | `/api/v2.0/alert/restore` | `alert.restore` |

The two POST routes are the milestone-1 alert actions (the Alerts view's
`dismiss` / `restore`). They need the `ALERT_LIST_WRITE` role; the reads need
`ALERT_LIST_READ`.

### GET `/api/v2.0/system/info`

Slow-moving, so it rides the meta cache rather than the fast poll. Success is a
non-empty JSON object; anything else is a section failure, not a quiet NAS.
Fields `share/normalize.jq` consumes:

| Field | Type | Use |
| --- | --- | --- |
| `hostname` | string | Health header |
| `version` | string | Health header, `connection.version` |
| `uptime_seconds` | number | Health uptime |
| `cores` | number | Health (slow sections) |
| `physmem` | number | Health (bytes; formatted binary) |
| `loadavg` | array of number | Health |

The route also carries `buildtime`, `boottime` and `datetime` as `{$date}`
objects, which this milestone does not read, and `uptime` as a preformatted
string, which is not used because it cannot be aged.

### GET `/api/v2.0/alert/list`

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
`args` and `key` are passed through by nothing in this milestone.

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
is the one lie that matters. `counts` is computed from non-dismissed alerts
only; dismissed rows stay in `alerts` (flagged) and are counted as `dismissed`,
because a row that disappears when you silence it is how a person loses track of
what they muted.

### GET `/api/v2.0/pool`

Returns a JSON array of imported pools. Fields consumed:

| Field | Type | Use |
| --- | --- | --- |
| `name` | string | Pool identity |
| `status` | string | Worst-pool word, tint |
| `healthy` | boolean | Trusted when present, else `status == "ONLINE"` |
| `size` | number | `usedPct` denominator |
| `allocated` | number | `usedPct` numerator, bar |
| `free` | number | Bar |
| `fragmentation` | number **or numeric string** | Pools view |
| `scan` | object or absent | Scrub state and age; `null` when absent |
| `topology.data[].stats` | object | vdev read/write/checksum error counts |
| `error_count` | object | Pool-level errors, preferred when present |

`status` vocabulary: `ONLINE`, `DEGRADED`, `FAULTED`, `OFFLINE`, `UNAVAIL`,
`REMOVED`. Healthy is `ONLINE` only. An unknown status ranks worst, ahead of
`FAULTED`, in `Model.poolStatusRank`: "I cannot tell" must never sort below a
known good pool.

`scan` is carried through only when present. A pool with no scrub on record is
`null`, never a fabricated `"FINISHED"`. Its `start_time` / `end_time` follow
the datetime rule below; `percentage` and `errors` are coerced to numbers.

`usedPct` is `(allocated / size * 100)` rounded to one decimal, and `null` when
`size` is `0` or absent -- a bar drawn at `0%` reads as "empty", which is a
claim the poll cannot make.

### POST `/api/v2.0/alert/dismiss` and `/api/v2.0/alert/restore`

The milestone-1 alert actions, implemented through `bin/truenas-api` (one verb
per call, JSON on stdout). `dismiss <uuid>` posts to `/api/v2.0/alert/dismiss`
and `restore <uuid>` to `/api/v2.0/alert/restore`; the body is one field:

```json
{ "uuid": "11111111-2222-3333-4444-555555555555" }
```

Both verbs answer with one JSON object: `{"ok":true}` on any 2xx, otherwise
`{error, message}`. The parameter tuple is documented as `uuid` alone, and both
methods require `ALERT_LIST_WRITE`. The panel re-polls with `--force-meta` and
reads the state back rather than trusting the verb's stdout. Every write is one
queued process, behind a `ConfirmAction` for dismiss; see the design doc.

## Milestone 2: disks and temperatures

`disk/temperatures` is POST-only (a GET answers `405`); `disk/details` is used
as a POST here. Verified against the live 25.10.6 on 2026-09-13:

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| disk inventory + pool mapping | POST | `/api/v2.0/disk/details` | `{"type":"USED"}` | JSON array, one object per disk; `imported_zpool` names the pool |
| temperatures (+ critical) | POST | `/api/v2.0/disk/temperatures` | `{"name":["sda",…],"include_thresholds":true}` | JSON object `{"sda":[38.0,60.0],…}` |

Traps, each observed on that box unless marked otherwise:

- `GET /api/v2.0/disk/temperatures` is `405 Method Not Allowed`; the route is
  POST-only.
- The parameter is **`name`** (singular, an array), not `names`: an object
  carrying `names` is rejected with `not expected: names`.
- A bare-array body is rejected with `Endpoint accepts multiple params`; the
  names have to be wrapped in an object.
- `{"type":"BOTH"}` on `disk/details` answers a **`{used,unused}`** object
  instead of an array. M2 uses `USED`: the array shape is simpler, and on the
  live box every disk is in use.
- With `include_thresholds:true` a value is normally `[tempC, criticalC]`. A
  bare number is the supported shape for a disk that reports no threshold (a
  shape rule, not a live probe; `share/normalize.jq` handles both). The missing
  threshold stays `null`, never `0`.
- The pool mapping is `imported_zpool` on `disk/details` (the plain `/disk`
  route has `"pool":null` on every row and is not used). Observed:
  `nvme0n1→storage`, `sda,sdb→boot-pool`, `sdc,sdd→Backup`.
- The rows also carry serials, identifiers and lunids; the plugin never stores
  them (see the meta cache below).

**SMART test results are not available on 25.04+.** `GET
/api/v2.0/smart/test/results` answers `404` on the live 25.10.6, and both API
references list no `smart.*` method at all -- 25.04.2
(<https://api.truenas.com/v25.04/>) and 25.10
(<https://api.truenas.com/v25.10/>) -- SMART tests were removed after 24.10.
Milestone 2 therefore ships temperature notifications only (the design's
`smartHealth`/`lastTest` disk fields are dropped), and a later milestone that
wants drive health has to find another signal.

### The disk meta cache

`meta.json` gains `disks` and `diskTemps` beside milestone 1's `system`:

```jsonc
{ "disks":     { "fetchedAt": "...",
                 "rows": [ { "name": "sda", "model": "SATA_HDD_500G",
                             "type": "HDD", "size": 500107862016,
                             "imported_zpool": "boot-pool", "bus": "ATA" }, … ] },
  "diskTemps": { "fetchedAt": "...", "map": { "sda": [38.0, 60.0], … } } }
```

The cached disk rows are exactly the wire fields a poll consumes, under their
wire names: `name`, `model`, `type`, `size`, `imported_zpool`, `bus`. Serials,
identifiers and lunids are dropped before the write and never reach the local
file, which is the point: the cache holds only what the normalizer needs, and
the normalizer stays the one owner of the row shape on both the fetch and the
reuse path. The temperatures map is cached as the wire wrote it. Meta advances
only when system, disks, temperatures and normalization all succeeded; a failed
section leaves the previous `meta.json` byte-for-byte intact, and an older meta
without the new keys reads as stale once, refetches once and self-heals.

## Milestone 3: services and apps

`/service` and `/app` are read whole on the meta cadence; there is no query
route, so both lists are filtered client-side. Verified against the live 25.10.6
on 2026-09-13:

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| service list | GET | `/api/v2.0/service` | -- | JSON array, rows `{id, service, enable, state, pids}` |
| app list | GET | `/api/v2.0/app` | -- | JSON array, rows with the fields below |
| service control | POST | `/api/v2.0/service/{start,stop,restart}` | `{"service":"ups"}` | `200` and the body `true` (synchronous) |
| app control | POST | `/api/v2.0/app/{start,stop,redeploy}` | `{"app_name":"appc"}` | `200` and the body is a job id number (asynchronous) |

Findings that constrain the design, each observed on that box unless marked
otherwise:

- Service writes answer `true` **synchronously**; app writes answer a job id and
  run asynchronously. A forced re-poll after an app write may still show the old
  state until the job lands. That is honest: the panel reads the NAS back and
  the next poll catches up. It never fabricates "starting".
- A service control body missing `service` is `400 {"message":"service attribute
  expected."}`; an unknown service name is `404 {"message":"<name>"}`. An app
  body missing `app_name` is `400 {"message":"app_name attribute expected."}`.
  The `app/start` route with an empty body answered `200` with a failed job
  (`[EINVAL] app_name: Input should be a valid string`), so the caller always
  sends `app_name`.
- `POST /api/v2.0/app/restart` is `404`: there is no app restart route. The
  restart-like verb is `POST /api/v2.0/app/redeploy`. `POST /api/v2.0/app/query`
  is `404` too: the list is fetched whole and filtered client-side.
- `POST /api/v2.0/service/reload` exists (404 for an unknown service), but M3
  does not ship it.
- The rows, as the two lists arrived: services `cifs RUNNING`, `nfs RUNNING`,
  `ssh RUNNING` and `ftp`, `iscsitarget`, `snmp`, `ups`, `nvmet` all `STOPPED`
  (the first three `enable` true, the rest false); apps `appa` (custom),
  `appc` and `appe` `RUNNING`, and `appb` `RUNNING` with an update
  available.
- The app row carries `title`, `app_version`, `train`, `home` and `icon` (icon is
  `null` for a custom app) under `metadata`, plus `human_version` (e.g.
  `16.0.4-rootless_1.2.39`), `version`, `custom_app`, `upgrade_available`,
  `migrated`, `portals` (`{"Web UI":"http://…"}` or `{}`), `notes` and
  `active_workloads.containers`. `notes` can be tens of kilobytes: it is never
  cached and never enters `state.json`.

### The service and app meta cache

`meta.json` gains `services` and `apps`, beside the M1 and M2 keys:

```jsonc
{ "services": { "fetchedAt": "...",
                "rows": [ { "id": 4, "service": "cifs", "state": "RUNNING",
                            "enable": true }, … ] },
  "apps":     { "fetchedAt": "...",
                "rows": [ { "name": "appc", "id": "appc",
                            "state": "RUNNING", "custom_app": false,
                            "upgrade_available": false, "migrated": false,
                            "human_version": "16.0.4-rootless_1.2.39",
                            "metadata": { "title": "appc",
                                          "app_version": "16.0.4-rootless",
                                          "train": "community",
                                          "home": "https://appc.org/",
                                          "icon": "…" },
                            "portals": { "Web UI": "http://…" },
                            "active_workloads": { "containers": 1 } }, … ] } }
```

The cached rows are the raw wire fields the plugin consumes, under their wire
names; service `pids`, app `notes` and the workload details are dropped before
the write and never reach disk. The normalizer owns the row shape on both the
fetch and the reuse path. Meta advances only when system, disks, temperatures,
services, apps and normalization all succeeded, and `meta_is_stale` requires all
five sections, so an older meta without the new keys reads as stale once,
refetches once and self-heals.

## Cross-cutting rules

### A datetime is a string *or* `{$date}`

TrueNAS writes timestamps two ways on different routes: an ISO-8601 string on
some, and Mongo's `{"$date": <epoch_ms>}` on others (`system/info.datetime`,
`alert.datetime` on the ZFS routes). `share/normalize.jq` `to_iso` accepts
either and emits an ISO string, or `null`. A raw object must never reach a QML
binding that expects a date.

### Numbers arrive as numeric strings

Some numeric fields (for example pool `fragmentation`) come back quoted. The
normalizer runs `tonumber? // null` over every numeric it consumes, so `"31"`
and `31` are one number and a non-numeric is `null` rather than a fabricated
zero.

### A 200 is not success until the body has the promised shape

A route that does not exist can still answer `200` with HTML or an empty object.
`bin/truenas-poll` `expect_shape` checks `alert/list`, `pool` and
`disk/details` are arrays, `system/info` is a non-empty object and
`disk/temperatures` an object after the request succeeds, and treats a
wrong-shaped body as a section failure. Trusting the status code alone would
report a healthy NAS with zero alerts, which is the one lie that matters.

`tn_classify` reads the status code before the body, so an empty-body `401` is
`unauthenticated` and a `404` is `not_found` rather than "not JSON"; it treats
`202` as success and keeps `not_json` for a `2xx` with a non-JSON body. `401` →
`unauthenticated`, `403` → `forbidden`, `5xx` → `server_error`.

### The rate limit and the two cadences

TrueNAS allows roughly 20 auth/unauthenticated requests per 60 s, then a
10-minute cooldown, and every route here is authenticated. A poll therefore
never hits every endpoint:

- every poll (`pollSeconds`, floor 15, default 30): `alert/list`, `pool`
  (and `core/get_jobs` in later milestones);
- every `notify.metaMaxAgeSeconds` (default 300): `system/info`, then
  `disk/details` and `disk/temperatures` (the temperatures request is built from
  the names the details call returned, so a failed details call skips it), then
  `service`, `app` and the rest as milestones add them.

A cold poll -- no fresh meta, so every section is fetched -- spends seven
requests: `alert/list`, `pool`, `system/info`, `disk/details`,
`disk/temperatures`, `service` and `app`. A warm poll, with a fresh meta cache,
spends two: `alert/list` and `pool`.

Results of the slow set are cached in
`~/.local/state/omarchy/truenas/meta.json` with a `fetchedAt`, and
`truenas-poll --force-meta` refetches regardless (used after a write). Static
answers live in `meta.json` beside the poll, the way the SigNoz reference caches
`/service_accounts/me` and `/rules`.

## Deep links into the NAS UI

TrueNAS 25.04 serves the app under `/ui`. `Links.js` builds every URL from the
configured base and admits a server-supplied URL only through `safeUrl`, whose
origin gate requires the character after the base to be `/`, `?`, `#` or the end
of the string -- a prefix test is not an origin test.

| Target | Path |
| --- | --- |
| Dashboard | `/ui/dashboard` |
| System (Health) | `/ui/system` |
| Storage (Pools) | `/ui/storage` |
| Apps | `/ui/apps` |
| Shares | `/ui/sharing` |
| Alerts | `/ui/alerts` |

Alerts are not a route in 25.04: the topbar bell opens a panel over whatever
page is showing, so `/ui/alerts` lands on the dashboard, which is where the bell
lives.

## Verification status

The endpoint shapes above are taken from the 25.04.2 reference and encoded in
`share/normalize.jq`, and the test fixtures (`tests/fixtures/`) are sanitized
snapshots of those shapes plus synthetic failure states (a degraded pool with
checksum errors and a scrub on record, alert levels across the buckets, `401`,
`500`, unreachable). The milestone-1 shapes, the milestone-2 disk routes and the
milestone-3 service and app routes were confirmed against a live TrueNAS 25.10.6
on 2026-09-13, and those probes are recorded above. A field the live box did not
exercise is still a claim to re-measure, not a fact to quote.
