# TrueNAS plugin — Milestone 4 implementation plan

> **For the executor:** work this plan task-by-task. Independent tasks run in
> git worktrees, one branch each, with a fresh implementer per task and a
> separate spec + quality reviewer after. Steps are bite-sized; do not skip the
> "run it and watch it fail" step. See **Execution** at the bottom for the wave
> layout.

**Goal:** Milestone 4 — protection inventory (replication, cloud sync, periodic
snapshot tasks, scrub tasks), a Protection view, protection failure and recovery
notifications, and run-now writes (replication run, cloud sync sync, snapshot
task run, scrub start) behind confirmation, all verified against the real NAS
(`https://nas.example:4433`, TrueNAS 25.10.6).

**Architecture:** unchanged from M1/M2/M3. `bin/truenas-poll` reads
`/replication`, `/cloudsync`, `/pool/snapshottask` and `/pool/scrub` on the meta
cadence into `state.json`; `BarWidget.qml` stays a read-only watcher; the panel's
Protection view renders the rows and sends confirmed writes through the existing
single queue to `bin/truenas-api`, then forces a re-poll. No new bar variant.

**Tech stack:** QML/Quickshell, bash + curl + jq, node for unit tests; the same
test harness as M1/M2/M3.

**Recon:** `docs/plans/2026-09-14-recon-protection.md` (measured live; trust it
over the design where they differ).
**Design doc:** `docs/plans/2026-09-13-truenas-plugin-design.md` (M4 section).
**Pitfalls:** `docs/11-pitfalls.md` (read the QML, `.pragma`, `arrayLike`,
notification-argv and duplicate-function sections before touching code).

---

## Conventions

- Every task commits with a Conventional Commit (`feat:`, `fix:`, `test:`,
  `docs:`, `chore:`). Never `git stash`; never force-push; never trailers or
  commit bodies (subject line only).
- `bash -n <file>` on every shell file touched.
  `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml`
  on QML changes. Bare `qmllint` is Qt 5 and lies.
- The API key is never committed, never in argv, never logged.
- Tests run with no network and no desktop: `./tests/run.sh`.
- Never turn "I cannot tell" into a number, a `0` or a `0%`. A failed section is
  an empty/null value plus a `warnings` entry, and the UI prints a sentence.
- All ids, names and states that came off the wire are written into request
  bodies by `jq -n --arg`, never interpolated into a shell string. An id placed
  in a **path** is validated numeric first.

## Recon summary (measured live 2026-09-14, TrueNAS 25.10.6)

Four list routes join the meta cadence, and four run verbs join the write path.
Everything below is a live measurement from the recon doc; the recon doc is
authoritative.

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| replication list | GET | `/api/v2.0/replication` | -- | JSON array; row has nested `state{state,datetime,warnings,last_snapshot}`, `job|null`, `schedule|null` |
| cloud sync list | GET | `/api/v2.0/cloudsync` | -- | JSON array (empty on this box); **no top-level `state`**, last run is `job` |
| snapshot task list | GET | `/api/v2.0/pool/snapshottask` | -- | JSON array; row has `state{state,datetime,last_snapshot}` and `naming_schema`; `PENDING` has no `datetime` |
| scrub task list | GET | `/api/v2.0/pool/scrub` | -- | JSON array; rows `{id,pool,pool_name,threshold,enabled,schedule}` and **no run state** |
| run replication | POST | `/api/v2.0/replication/run` | **bare integer id** | async job id |
| run cloud sync | POST | `/api/v2.0/cloudsync/id/{id}/sync` | none or `{}` | async job id |
| run snapshot task | POST | `/api/v2.0/pool/snapshottask/id/{id}/run` | **none** | `null` (sync) |
| scrub action | POST | `/api/v2.0/pool/scrub/scrub` | `{"name":<pool>,"action":"START"}` | async job id |

Findings that constrain the design:

1. `POST /replication/run` with `{"id":1}` fails `[EINVAL] id: Input should be a
   valid integer`; the wire body is the bare integer. The write path therefore
   needs a body mode that is not the one-key object.
2. A body on `cloudsync/id/{id}/sync` leaks into the options object
   (`{"id":…}` fails `cloud_sync_sync_options.id: Extra inputs are not
   permitted`), so the sync verb sends **no body** with the id in the path.
3. `pool/snapshottask/id/{id}/run` rejects an empty object
   (`Too many arguments (expected 1, found 2)`), so the snapshot verb sends
   **no body at all** with the id in the path.
4. The scrub row carries no run state. A pool's scrub progress and last result
   live on `pool.scan`, which M1 already normalizes; M4 adds no second scrub
   state field.
5. `pool/scrub/run {"name":…}` is **due-gated** and may quietly do nothing,
   which reads as a broken button. M4 uses `pool/scrub/scrub {"name":…,
   "action":"START"}` (async job id) instead: it is honest about starting a job
   and matches the M3 async-write pattern.
6. `GET /pool/snapshot` is not read. The full list is 298 heavy rows with a
   `properties` blob each. M4 drops the design's `snapshots` list entirely: the
   periodic snapshot tasks are the snapshot section, and a per-poll
   `?count=true` would spend a request for a figure no view needs.
7. Dates inside `state` and `job` are Mongo `{$date: epoch_ms}` objects;
   `share/normalize.jq` `to_iso` already accepts them.
8. The replication `ssh_credentials`, `encryption_key`, `job.logs_excerpt` and
   `job.exception`, and the cloud sync `credentials`, `encryption_password`,
   `encryption_salt`, `pre_script`, `post_script`, `job.logs_excerpt`, are
   never cached.

## Frozen contracts (all tasks code against these)

### `state.json` new sections

Section names are stable and documented. Warning section tokens are exactly the
state keys.

```jsonc
"replication": [
  { "id": 1, "name": "storage-to-backup", "direction": "PUSH", "transport": "LOCAL",
    "sourceDatasets": ["storage/vm-root"], "targetDataset": "Backup/replica-storage",
    "recursive": false, "enabled": true, "auto": true,
    "retentionPolicy": "CUSTOM", "lifetimeValue": 14, "lifetimeUnit": "DAY",
    "schedule": { "minute": "0", "hour": "3", "dom": "*", "month": "*",
                  "dow": "*", "begin": "03:00", "end": "23:59" },
    "retries": 5,
    "state": { "state": "FINISHED", "datetime": "2026-…Z", "warnings": [],
               "lastSnapshot": "storage/vm-root@auto-daily-…" },
    "job": { "state": "SUCCESS", "timeFinished": "2026-…Z", "error": null } }
],
"cloudSync": [
  { "id": 3, "name": "clouda-backup", "path": "/mnt/storage/photos",
    "enabled": true, "direction": "PUSH", "transferMode": "SYNC",
    "schedule": { … } /* or null */,
    "job": { "state": "SUCCESS", "timeFinished": "2026-…Z", "error": null } }
],
"snapshotTasks": [
  { "id": 1, "dataset": "storage", "recursive": true, "enabled": true,
    "lifetimeValue": 2, "lifetimeUnit": "DAY",
    "namingSchema": "auto-hourly-%Y-%m-%d_%H-%M", "allowEmpty": true,
    "schedule": { … },
    "state": { "state": "FINISHED", "datetime": "2026-…Z",
               "lastSnapshot": "storage@auto-hourly-…" } }
],
"scrubs": [
  { "id": 1, "poolId": 1, "pool": "storage", "threshold": 35,
    "description": "monthly scrub", "enabled": true, "schedule": { … } }
]
```

Rules:

- `replication` sorted by `.name`; `cloudSync` by `.name`; `snapshotTasks` by
  `.dataset`; `scrubs` by `.pool`. Stable for tests and UI.
- A `schedule` is either `null` or exactly the seven keys
  `minute,hour,dom,month,dow,begin,end`, each a string or `null`. The scrub and
  cloud sync schedules carry no `begin`/`end`; those keys are `null`, never
  dropped, so one renderer handles both.
- `state`/`job` are `null` when the wire field is absent. Inside a present
  `state`: `state` is the raw string (`""` when absent), `datetime` ISO or
  `null`, `warnings` always an array, `lastSnapshot` the raw string or `null`
  (never `""`). Inside a present `job`: `state` raw (`""` when absent),
  `timeFinished` ISO or `null`, `error` the raw value or `null`.
- An absent id is `null`, never `0`; an absent numeric (`threshold`,
  `lifetimeValue`, `retries`) is `null`, never `0`. Booleans that are absent
  default `false` only where the wire flag means off (`enabled`, `recursive`,
  `auto`, `allowEmpty`).
- A failed section is `[]` plus a warning named after the section; it never
  becomes an empty-but-healthy list.

### Warning section names

`replication`, `cloudSync`, `snapshotTasks`, `scrubs`.

### `meta.json` new caches

Added beside the M1/M2/M3 keys, each `{fetchedAt, rows}`:

```jsonc
"replication": { "fetchedAt": "…",
  "rows": [ { "id": 1, "name": "storage-to-backup", "direction": "PUSH", …,
              "schedule": { … } /* sched whitelist or null */,
              "state": { "state": "FINISHED", "datetime": {…},
                         "warnings": [], "last_snapshot": "…" },
              "job": { "state": "SUCCESS", "time_finished": {…},
                       "error": null } } ] },
"cloudSync": { "fetchedAt": "…",
  "rows": [ { "id": 3, "description": "clouda-backup", "path": "…",
              "enabled": true, "direction": "PUSH", "transfer_mode": "SYNC",
              "schedule": {…}, "job": { "state": "SUCCESS", … } } ] },
"snapshotTasks": { "fetchedAt": "…",
  "rows": [ { "id": 1, "dataset": "storage", "recursive": true, "enabled": true,
              "lifetime_value": 2, "lifetime_unit": "DAY",
              "naming_schema": "…", "allow_empty": true, "schedule": {…},
              "state": { "state": "FINISHED", "datetime": {…},
                         "last_snapshot": "…" } } ] },
"scrubs": { "fetchedAt": "…",
  "rows": [ { "id": 1, "pool": 1, "pool_name": "storage", "threshold": 35,
              "description": "…", "enabled": true, "schedule": {…} } ] }
```

The cached rows keep the consumed wire fields under their wire names, with the
nested `state`/`job` reduced to the keys the normalizer reads. `state` is cached
as `{state, datetime, warnings, last_snapshot}` (or `null`); `job` as
`{state, time_finished, error}` (or `null`). The schedule is whitelisted to the
seven keys. Serials, keys, `logs_excerpt`, `exception`, cloud sync
`credentials`, `pre_script`, `post_script`, `encryption_password` and
`encryption_salt` never reach disk. The normalizer owns the shape on both the
fetch and the reuse path.

`meta_is_stale` requires **all nine** sections (`.system.data`, `.disks.rows`,
`.diskTemps.map`, `.services.rows`, `.apps.rows`, `.replication.rows`,
`.cloudSync.rows`, `.snapshotTasks.rows`, `.scrubs.rows`). Meta advances only
when all nine were fetched and normalized; a missing key self-heals once.

### Notifications (`bin/truenas-poll`, `seen.json`)

Only replication and cloud sync carry a `job`; snapshot tasks and scrub tasks do
not, so they do not toast. `seen.json` gains:

```jsonc
"replication": { "1": { "state": "SUCCESS", "failed": false, "lastNotifiedAt": "…" } },
"cloudSync":   { "3": { "state": "SUCCESS", "failed": false, "lastNotifiedAt": "…" } }
```

- Keyed by the task id as a string; a row without an id is skipped.
- Gates: `replication_notify_ok = normalize_ok && no "replication" warning`;
  `cloudSync_notify_ok = normalize_ok && no "cloudSync" warning`. Without its
  gate, that half of `seen.json` is not written.
- The entry stores the last **decisive** `job.state` and a stable `failed`
  boolean, not the raw observation. Terminal job states are `SUCCESS`,
  `FINISHED`, `FAILED`, `ERROR`, `ABORTED`; `WAITING`, `RUNNING`, `PENDING`,
  blank and anything else are non-decisive. A replication row with a non-empty
  `state.warnings` is also decisive.
- `failed` is true when the decisive `job.state` is `FAILED`, `ERROR` or
  `ABORTED`, or (replication only) `state.warnings` is non-empty.
- On a decisive poll the entry's `state` and `failed` are set from the current
  row; on a non-decisive poll both are carried forward untouched and nothing
  toasts. Carrying the last decisive values forward is what stops a `RUNNING`
  or blank poll from erasing the signal, which is the M3 state-clobbering bug.
- `failed` transition: the previous entry exists, its `failed` is `false`, and
  the current `failed` is `true`. Toast `Replication <name> failed` (body the
  job `error` when non-empty, else `job state <state>`) and `Cloud sync <name>
  failed`, `GLYPH_ALERT`, urgency `urgency_for warning`. When the previous
  decisive state is empty the body is `job state <cur>` rather than an empty
  `from`.
- `recovered`: the previous `failed` is `true` and the current is `false`.
  Toast `Replication <name> recovered` / `Cloud sync <name> recovered`, low
  urgency, `GLYPH_OK`.
- A first sighting never toasts. Reduce over the **current** rows only, so a
  removed task does not linger.

### Model.js helpers

| Function | Behavior |
| --- | --- |
| `protectionStateRank(state)` | `SUCCESS`/`FINISHED` → `0`; `FAILED`/`ERROR`/`ABORTED` → `1`; anything else (incl. blank) → `2` |
| `protectionState(row)` | `job.state` when non-empty, else `state.state`, else `""` |
| `replicationFailed(row)` | rank `1` on `taskState`, or non-empty `state.warnings` |
| `cloudSyncFailed(row)` | rank `1` on `job.state` |
| `failedReplications(rows)` | rows where `replicationFailed` is true, in input order, as a copy |
| `failedCloudSync(rows)` | rows where `cloudSyncFailed` is true, in input order, as a copy |
| `worstProtectionLevel(state)` | `"warning"` if any replication or cloud sync row failed, else `""` |
| `protectionLabel(row)` | `name` when non-empty, else `dataset`, else `pool`, else `""` |
| `scheduleText(schedule)` | `""` for null/non-object; else a compact `dow hour minute` string, `""` fields skipped |

All helpers are pure, never touch QML, and guard every list argument with
`arrayLike`; absence is `""`/`null`, never `0`.

### Search.js filters

- `replication(list, needle)`: matches `name`, `direction`, `transport`,
  `targetDataset`, `state.state`, `job.state`.
- `cloudSync(list, needle)`: matches `name`, `path`, `direction`,
  `transferMode`, `job.state`.
- `snapshotTasks(list, needle)`: matches `dataset`, `namingSchema`,
  `state.state`, `lastSnapshot`.
- `scrubs(list, needle)`: matches `pool`, `description`, `threshold`, `enabled`.
All mirror `Search.disks` exactly: copy semantics, empty needle returns every
row, non-list and junk rows do not throw.

### Writes (`bin/truenas-api`)

Four verbs join the eight. The body is no longer always a one-key object, so the
case table gains a `body` mode.

| Verb | Method + path | Body |
| --- | --- | --- |
| `replication-run <id>` | `POST /api/v2.0/replication/run` | bare integer id (`jq -n --argjson`) |
| `cloudsync-sync <id>` | `POST /api/v2.0/cloudsync/id/<id>/sync` | none |
| `snapshot-run <id>` | `POST /api/v2.0/pool/snapshottask/id/<id>/run` | none |
| `scrub-start <pool>` | `POST /api/v2.0/pool/scrub/scrub` | `{"name":<pool>,"action":"START"}` |

- `replication-run`, `cloudsync-sync` and `snapshot-run` take an id and validate
  `^[0-9]+$` before it can reach a path or a body; a non-numeric target is a
  usage error (`exit 2`). The id is placed in the path only after validation and
  in the JSON body only through `jq --argjson`.
- `scrub-start` takes a pool name, written into the body by `jq --arg`.
- Any 2xx answers `{"ok":true}` whether the NAS answers `true`, a job id or
  `null`; a non-2xx answers `{error, message}` and exits `1`. A 2xx whose body is
  the JSON boolean `false` is `action_failed` (unchanged). The panel calls
  `refreshAfterWrite()` after every write.

### `truenasctl`

- `truenasctl replication` prints `NAME  DIRECTION  STATE  LAST RUN`.
- `truenasctl cloudsync` prints `NAME  DIRECTION  STATE  LAST RUN`.
- `truenasctl snapshots` prints `DATASET  STATE  LAST SNAPSHOT` (the periodic
  snapshot tasks).
- `truenasctl scrubs` prints `POOL  ENABLED  THRESHOLD  SCHEDULE`.
Each prints the section's `unknown: <reason>` sentence through
`state_unknown_reason "$file" <section>` (and a non-array guard) instead of an
empty table, and `unknown` for a flag or string it did not learn.

---

## Task A: Protection read path — list, normalize, meta cache

**Files:**
- Modify: `share/normalize.jq`, `bin/truenas-poll`, `tests/cases/10-poll.sh`,
  `tests/cases/13-meta.sh`
- Create: `tests/fixtures/replication.json`, `tests/fixtures/cloudsync.json`,
  `tests/fixtures/snapshot-tasks.json`, `tests/fixtures/scrubs.json`

**Step 1: fixtures.** Add the four fixtures. `cloudsync.json` is `[]` (the live
box has none, so the default must match). `replication.json` has a healthy
`SUCCESS`/`FINISHED` row and a `PENDING` row with `schedule` and `job:null`.
`snapshot-tasks.json` has a `FINISHED` row, a `PENDING` row (no `datetime`, no
`last_snapshot`) and a disabled weekly row. `scrubs.json` has a `storage` and a
`Backup` row. Put a fake `ssh_credentials`, `encryption_key`, `job.logs_excerpt`
and `job.exception` on one replication row to prove they are dropped, and a
large `job.logs_excerpt` on the cloud sync variant the tests build inline.

**Step 2: normalize.jq.** Add a `schedule_norm` emitting the seven-key object or
`null`, and `replication_norm`, `cloudsync_norm`, `snapshot_task_norm`,
`scrub_norm` producing exactly the frozen rows. Add `--slurpfile` inputs and the
top-level assembly keys, sorted as the contract says. Use `to_iso` for every
datetime and `num` for every numeric.

**Step 3: poll.** Fetch the four routes on the meta cadence inside the
`meta_is_stale` branch, shape
`type == "array" and all(.[]; type == "object")`. Extend `default_payload` with
the four empty lists. Add the fetched/ok flags. Reuse reconstructs the four
`$WORK` bodies from `.replication.rows` / `.cloudSync.rows` /
`.snapshotTasks.rows` / `.scrubs.rows`. Extend `meta_is_stale`, the
meta-advance condition and the final `state.json` assembly with the four
sections. Cache the reduced wire rows per the contract.

**Step 4: tests.** In `tests/cases/10-poll.sh`: add the four routes to
`all_healthy`; assert the normalized rows (counts, sort, `schedule` shape,
`state.datetime` ISO, `PENDING` null `lastSnapshot`, `scrubs` no state, and no
`ssh_credentials`/`encryption_key`/`logs_excerpt` in any row), and add failure
cases: a 500 on each route gives an empty list plus that section's warning while
pools still render. Update the cold-poll request count from `7` to `11` and the
"seven requests on a cold poll" assertion. In `tests/cases/13-meta.sh`: add the
four routes to `meta_responses`, update the cumulative warm count from `9` to
`13`, the self-heal loop over the four new keys, the force-meta request
assertions and the cached-field filtering assertions (no secrets). Add a case
with a synthetic cloud sync row to prove normalization on a non-empty list.

**Step 5:** `./tests/run.sh`; `bash -n bin/truenas-poll`; `jq empty` on the
fixtures.

**Step 6: Commit** — `feat: read protection tasks on the meta cadence`.

---

## Task B: Protection failure and recovery notifications

**Files:**
- Modify: `bin/truenas-poll`, `tests/cases/11-notify.sh`

Run after A. Adds the four routes to `notify_endpoints` in the test so existing
disk/service/app cases stay quiet.

**Step 1:** Build the `replication-notify.json` and `cloudsync-notify.json`
reductions exactly as the contract defines (`failed` and `recovered`, reduce
over current rows only), gate on `replication_notify_ok` / `cloudsync_notify_ok`,
and write `seen.replication` / `seen.cloudSync`. On a failed poll leave both
untouched.

**Step 2:** Toast with separate argv words, `--exec` last:
`Replication <name> failed` / (job error or `job state <state>`) and the
recovery form, plus the cloud sync pair.

**Step 3:** `tests/cases/11-notify.sh`: a replication job crossing
`SUCCESS`→`FAILED` toasts once and is not replayed; `FAILED`→`SUCCESS` toasts a
recovery; a first sighting that is already `FAILED` toasts nothing; a
`state.warnings` row toasts; a job passing through `RUNNING` between `SUCCESS`
and `FAILED` carries the state forward and the later `FAILED` still toasts with
`state changed from SUCCESS to FAILED` (the state-clobbering guard); a failed
`/replication` poll leaves `seen.replication` byte-for-byte and replays nothing;
the same matrix for cloud sync (no warnings field); the notification argv shape
check passes.

**Step 4:** `./tests/run.sh`, `bash -n bin/truenas-poll`.

**Step 5: Commit** — `feat: notify when a protection task fails or recovers`.

---

## Task C: Model and Search helpers

**Files:**
- Modify: `Model.js`, `Search.js`, `tests/model.mjs`, `tests/search.mjs`

**Step 1:** Add the nine Model helpers in the frozen contract, following the
`serviceStateRank`/`downServices` style, with `arrayLike` guards and no
fabricated zero. `protectionLabel` must not print `"undefined"`.

**Step 2:** Add `Search.replication`, `Search.cloudSync`, `Search.snapshotTasks`
and `Search.scrubs`, copying `Search.disks` including its copy semantics and
junk-row tolerance.

**Step 3:** `tests/model.mjs`: one test group per helper; for each, the
unknown/absence case (`null`, `""`, non-list, a row with no state) proving it
does not become `0` or `"undefined"`. `tests/search.mjs`: the same block of
cases `disks` has for each new filter (matched fields, case-insensitivity, order
preserved, copy not identity, empty needle returns all, non-list returns `[]`,
junk rows do not throw).

**Step 4:** `./tests/run.sh`.

**Step 5: Commit** — `feat: add protection helpers`.

---

## Task D: Protection view, Panel tab, Menu row

**Files:**
- Create: `Views/Protection.qml`
- Modify: `Panel.qml`, `Menu.qml`

Run after A and C. `17-qml-structure.sh` cross-links the `Panel.qml` tab keys,
the `Panel.qml` `viewComponents` map and the `Menu.qml` view rows; all three
must gain `protection` (lowercase, exact indentation) or it fails.

**Step 1:** `Views/Protection.qml`, modelled on `Views/Services.qml`: read
`view.panel.state`, guard each section with `arrayLike`, a `warnings` lookup per
section (`replication`, `cloudSync`, `snapshotTasks`, `scrubs`), an
`emptyText`/`warningLine` pair per section (a failed section says why, never "0
tasks"), and a `FilterField` + `Search.*` per section. One card per row: a
label via `Model.protectionLabel`, a state chip tinted by
`Model.protectionStateRank` for replication/cloudSync/snapshotTasks, the
`lastRun`/`lastSnapshot`/`threshold`/`enabled` detail appropriate to the
section, and a `scheduleText` line. Actions: `replication-run`,
`cloudsync-sync`, `snapshot-run` and `scrub-start` through
`view.panel.runApi([...], cb)` then `refreshAfterWrite()`, each behind
`view.panel.requestConfirm(...)`. A link-out line uses
`Links.systemUrl(view.panel.baseUrl)`.

**Step 2:** `Panel.qml`: add the `protection` tab key (after `apps`), the
`viewComponents` entry and the `Component { id: protectionView;
Views.Protection { panel: root } }` registration. `Menu.qml`: add a
`protectionText` detail property that prints the failed count, or the section's
failure sentence, and the `{ kind: "view", args: ["protection"], … }` row.

**Step 3:** `tests/cases/17-qml-structure.sh` keeps passing. Add a `qmllint`
gate locally.

**Step 4:** `./tests/run.sh`; `qmllint` 0 errors.

**Step 5: Commit** — `feat: add the Protection view`.

---

## Task E: `truenas-api` run verbs

**Files:**
- Modify: `bin/truenas-api`, `tests/cases/15-api.sh`

**Step 1:** Add a `body` mode to the case table (one-key, bare-integer, none,
scrub pair), keep the key-on-stdin, `jq`-built body and `trap` structure
exactly as the existing verbs do. Place an id in a path only after `^[0-9]+$`
validation. Extend the usage text. A 2xx with any body is `{"ok":true}`;
anything else is `{error, message}` and exit 1.

**Step 2:** `tests/cases/15-api.sh`: for each of the four verbs assert the POST
method, the exact route (including the substituted id), the body shape and
`ok` true; a `false` 2xx is `action_failed`; a non-numeric id is a usage error
(`exit 2`); one error case carries the NAS message; the key-never-in-logs check.

**Step 3:** `./tests/run.sh`, `bash -n bin/truenas-api`.

**Step 4: Commit** — `feat: add protection run verbs to truenas-api`.

---

## Task F: `truenasctl` protection verbs

**Files:**
- Modify: `bin/truenasctl`, `tests/cases/14-ctl.sh`

**Step 1:** Add the four commands mirroring `cmd_services`/`cmd_apps`: the
`[[ -s $file ]]` guard, the `jq -e 'type == "object"'` unreadable guard, the
`jq -e '.replication | type == "array"'` non-array guard, the
`state_unknown_reason "$file" <section>` gate that prints
`<section> unknown: <reason>` and returns 0, then the `jq -r` table. Add the
dispatch arms and the usage lines.

**Step 2:** `tests/cases/14-ctl.sh`: hand-build a `state.json` with the four
sections and assert the four tables, the `enabled`/`unknown` formatting, an
empty list printing just the header, and the unknown path when a section
warning is present.

**Step 3:** `./tests/run.sh`, `bash -n bin/truenasctl`.

**Step 4: Commit** — `feat: add the truenasctl protection verbs`.

---

## Task G: Docs and version

**Files:**
- Modify: `docs/02-truenas-api.md`, `docs/03-features.md`,
  `docs/plans/2026-09-13-truenas-plugin-design.md`, `manifest.json`, `README.md`,
  `.agent/WORKLOG.md`

**Run last, after the code tasks merge** (it documents their reality).

- `docs/02-truenas-api.md`: a milestone-4 section with the verified endpoint
  table and findings 1-8, including the bare-integer replication body, the
  empty-body cloud sync and snapshot routes, the scrub due-gate choice, and the
  dropped snapshot list.
- `docs/03-features.md`: a "Milestone 4, what ships" section (Protection view,
  the four run verbs, failure/recovery notifications, `truenasctl
  replication/cloudsync/snapshots/scrubs`) and remove the M4 paragraph from
  **Planned**.
- `docs/plans/2026-09-13-truenas-plugin-design.md`: correct the M4 state sketch
  (`replication`, `cloudSync`, `snapshotTasks`, `scrubs`; no raw `snapshots`
  list), the notifications table (replication/cloud sync failure and recovery),
  and the writes list (run verbs).
- `manifest.json`: version `0.3.0` → `0.4.0`.
- `README.md`: remove protection from the **Planned** sentence.
- `.agent/WORKLOG.md`: append the M4 section.

**Verify:** `jq empty manifest.json`, then `./tests/run.sh`.

**Commit** — `docs: document milestone 4 and bump the version`.

---

## Execution

Wave layout (worktrees from the handoff recipe, one branch per task):

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m4-<slug> -b agent/desk/m4-<slug> master
# dispatch one implementer per task against its worktree
# reviewer (read-only) checks the branch, implementer fixes, reviewer re-checks
git merge --no-ff agent/desk/m4-<slug> -m "Merge Task <X>: <title>"
git worktree remove /tmp/opencode/tn-m4-<slug> --force
```

- **Wave 1, parallel:** A (read path), B (helpers), E (`truenas-api`).
- **Wave 2, parallel:** C (notifications, after A), D (view, after A + B), F
  (ctl, after A).
- **Wave 3:** G (after A-F; merge last).
- Reviews after each wave: spec-compliance reviewer, then code-quality reviewer,
  both read-only; a reviewer's finding goes back to the implementer and the same
  reviewer re-checks. No task merges with an open finding.
- After every merge run `./tests/run.sh` on master.

**Definition of done for M4:** all suites green; `qmllint` 0 errors;
`omarchy plugin validate` clean on a tree without `.agent`; `./scripts/dev-install
--restart`; against the live NAS `truenasctl poll` writes the four sections with
real rows, the four `truenasctl` verbs print them, and the panel renders the
Protection tab; the ERROR path of one run verb is exercised live (invalid id)
and the happy path stays in tests (no real scrub, replication or cloud sync is
started); `.agent/WORKLOG.md` and `docs/04-handoff.md` are updated.
