# TrueNAS API surface (milestone 1)

Sources: the versioned API reference at <https://api.truenas.com/v25.04.2/>
(method names, parameter shapes and the REST deprecation note), and the
installed TrueNAS SCALE 25.04.2 the plugin was pointed at. The REST paths below
are the ones a milestone-1 poll reads; the JSON-RPC method in brackets is the
same operation under the new API, and the migration target.

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

## Endpoints this milestone uses

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

### POST `/api/v2.0/alert/dismiss` and `/api/v2.0/alert/restore` (planned)

The milestone-1 alert actions. **Not implemented in this build**: the write path
lands with the Alerts view, and there is no `bin/truenas-api` yet. The endpoints
below are the spec. The body is one field:

```json
{ "uuid": "11111111-2222-3333-4444-555555555555" }
```

The parameter tuple is documented as `uuid` alone; both methods return `null`
(no body) on success and require `ALERT_LIST_WRITE`. When shipped, writes will go
through `bin/truenas-api` (one verb per call, JSON on stdout); the panel then
re-polls with `--force-meta` and reads the state back rather than trusting the
verb's stdout. Every write is one queued process behind a `ConfirmAction`; see
the design doc.

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
`bin/truenas-poll` `expect_shape` checks `alert/list` and `pool` are arrays and
`system/info` is a non-empty object after the request succeeds, and treats a
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
- every `notify.metaMaxAgeSeconds` (default 300): `system/info`, then `disk`,
  `service`, `app` and the rest as milestones add them.

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
`500`, unreachable). They have **not** yet been confirmed
against the live NAS: milestone 1 ends with `truenasctl test -v` against
`https://nas.example:4433`, which is blocked on an API key. Until then every
field is a claim to re-measure, not a fact to quote.
