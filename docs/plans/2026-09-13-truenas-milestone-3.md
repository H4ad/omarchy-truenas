# TrueNAS plugin — Milestone 3 implementation plan

> **For the executor:** work this plan task-by-task. Independent tasks run in
> git worktrees, one branch each, with a fresh implementer per task and a
> separate spec + quality reviewer after. Steps are bite-sized; do not skip the
> "run it and watch it fail" step. See **Execution** at the bottom for the wave
> layout.

**Goal:** Milestone 3 — service and app inventory, a Services view and an Apps
view, down/recovery notifications, and the first control writes (service
start/stop/restart, app start/stop/redeploy) behind confirmation, all verified
against the real NAS (`https://nas.example:4433`, TrueNAS 25.10.6).

**Architecture:** unchanged from M1/M2. `bin/truenas-poll` reads `/service` and
`/app` on the meta cadence into `state.json`; `BarWidget.qml` stays a read-only
watcher; the panel's Services/Apps views render the rows and send confirmed
writes through the existing single queue to `bin/truenas-api`, then force a
re-poll. No new bar variant.

**Tech stack:** QML/Quickshell, bash + curl + jq, node for unit tests; the same
test harness as M1/M2.

**Design doc:** `docs/plans/2026-09-13-truenas-plugin-design.md`.
**Pitfalls:** `docs/11-pitfalls.md` (read the QML, `.pragma`, `arrayLike`,
notification-argv and duplicate-function sections before touching code).

---

## Conventions

- Every task commits with a Conventional Commit (`feat:`, `fix:`, `test:`,
  `docs:`, `chore:`). Never `git stash`; never force-push.
- `bash -n <file>` on every shell file touched.
  `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml`
  on QML changes. Bare `qmllint` is Qt 5 and lies.
- The API key is never committed, never in argv, never logged.
- Tests run with no network and no desktop: `./tests/run.sh`.
- Never turn "I cannot tell" into a number, a `0` or a `0%`. A failed section is
  an empty/null value plus a `warnings` entry, and the UI prints a sentence.
- All ids, names and states that came off the wire are written into request
  bodies by `jq -n --arg`, never interpolated into a shell string.

## Verified against the live NAS (2026-09-13, TrueNAS 25.10.6)

These were probed before this plan was written; the plan does **not** assume the
design doc's endpoint list.

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| service list | GET | `/api/v2.0/service` | — | JSON array, rows `{id, service, enable, state, pids}` |
| app list | GET | `/api/v2.0/app` | — | JSON array, rows with the fields in the contract below |
| service control | POST | `/api/v2.0/service/{start,stop,restart}` | `{"service":"ups"}` | `200` and the body `true` (synchronous) |
| app control | POST | `/api/v2.0/app/{start,stop,redeploy}` | `{"app_name":"appc"}` | `200` and the body is a **job id number** (asynchronous) |

Findings that constrain the design:

1. Service writes answer `true` **synchronously**; app writes answer a job id and
   run asynchronously. A forced re-poll after an app write may still show the old
   state until the job lands. That is honest: the panel reads the NAS back and
   the next poll catches up. Do not fabricate "starting".
2. A service control body missing `service` is `400 {"message":"service
   attribute expected."}`; an **unknown** service name is `404
   {"message":"<name>"}`. An app body missing `app_name` is `400 {"message":
   "app_name attribute expected."}`; the `app/start` route with an empty body
   returned `200` and a **failed job** (`[EINVAL] app_name: Input should be a
   valid string`), so the caller must always send `app_name`.
3. `POST /api/v2.0/app/restart` is **404**: there is no app restart route. The
   restart-like verb is `POST /api/v2.0/app/redeploy`. `POST /api/v2.0/app/query`
   is 404 too: the list is fetched whole and filtered client-side.
4. `POST /api/v2.0/service/reload` exists (404 for an unknown service), but M3
   does not ship it.
5. Live services (`service  enable  state`): `cifs true RUNNING`, `nfs true
   RUNNING`, `ssh true RUNNING`, `ftp false STOPPED`, `iscsitarget false
   STOPPED`, `snmp false STOPPED`, `ups false STOPPED`, `nvmet false STOPPED`.
6. Live apps (`name  state  upgrade_available  custom_app`): `appa RUNNING
   false true`, `appc RUNNING false false`, `appe RUNNING false false`,
   `appb RUNNING true false`.
7. App metadata carries `title, app_version, train, home, icon` (icon is `null`
   for a custom app). The row also carries `human_version` (e.g.
   `16.0.4-rootless_1.2.39`), `version`, `custom_app`, `upgrade_available`,
   `migrated`, `portals` (`{"Web UI":"http://…"}` or `{}`), `notes` and
   `active_workloads.containers`. `notes` can be tens of kilobytes: it is never
   cached and never enters `state.json`.

## Frozen contracts (all tasks code against these)

### `state.json` `services` and `apps` rows

```jsonc
"services": [
  { "id": 4, "service": "cifs", "state": "RUNNING", "enable": true }
],
"apps": [
  { "id": "appc", "name": "appc", "title": "appc",
    "state": "RUNNING", "version": "16.0.4-rootless_1.2.39",
    "appVersion": "16.0.4-rootless", "train": "community",
    "custom": false, "upgradeAvailable": false, "migrated": false,
    "containers": 1,
    "webui": { "label": "Web UI", "url": "http://nas.example:30142/" } }
]
```

- `services` sorted by `.service`; `apps` sorted by `.name` for stable tests and
  UI.
- `id` is a number for services and a string for apps, or `null` when absent.
  `enable`/`custom`/`upgradeAvailable`/`migrated` are booleans, defaulting
  `false`. `state` is the raw wire string, `""` when absent.
- `title` falls back to `name`; `version` is `human_version`, falling back to
  `version`, `""` when neither; `appVersion` is `metadata.app_version`, `""`
  when absent; `train` is `metadata.train`, `""` when absent.
- `containers` is `active_workloads.containers` as a number, `null` when absent,
  never `0`.
- `webui` is the `Web UI` portal when present, else the first portal sorted by
  key, as `{label, url}`, or `null` when `portals` is empty. It is a UI hint for
  a link-out; `Links.safeUrl` still gates it against the configured base before
  it is opened.
- A failed services fetch is `services: []` plus a `{section:"service"}`
  warning; a failed apps fetch is `apps: []` plus a `{section:"app"}` warning.
  Neither ever becomes an empty-but-healthy list.

### `meta.json`

M1/M2's keys are unchanged. Two caches are added and always written together
with them on a successful meta refresh:

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
names; `notes`, image identifiers and anything else are dropped before the write
and never reach disk. The normalizer owns the shape on both the fetch and the
reuse path.

`meta_is_stale` becomes true unless **all five** sections are present
(`.system.data`, `.disks.rows`, `.diskTemps.map`, `.services.rows`,
`.apps.rows`) and `.system.fetchedAt` is fresh (or `--force-meta`). An existing
`meta.json` without the new keys reads as stale once, refetches once, and
self-heals. Meta advances only when system, disks, temperatures, services, apps
and normalization all succeeded; otherwise the previous meta stays byte-for-byte
intact.

### Notifications (`bin/truenas-poll`, `seen.json`)

`seen.json` gains:

```jsonc
"services": { "cifs": { "state": "RUNNING", "down": false, "lastNotifiedAt": "…" } },
"apps":     { "appc": { "state": "RUNNING", "down": false, "lastNotifiedAt": "…" } }
```

- Gates: `services_notify_ok = normalize_ok && no "service" warning`;
  `apps_notify_ok = normalize_ok && no "app" warning`. Without its gate, that
  half of `seen.json` is not written (a network blip must not replay every
  service as stopped on recovery).
- The entry stores the last **decisive** state and a stable `down` boolean, not
  the raw observation. A decisive service state is any non-empty state; a
  decisive app state is one of `RUNNING`, `STOPPED`, `CRASHED`, `FAILED`,
  `EXITED`. `DEPLOYING`, `STARTING`, `STOPPING` and `""` are non-decisive for an
  app. A service is **down** when its decisive state is not `RUNNING`; an app is
  **down** when its decisive state is one of `STOPPED`, `CRASHED`, `FAILED`,
  `EXITED`.
- On a decisive poll the entry's `state` and `down` are set from the current
  row; on a non-decisive poll both are carried forward untouched and nothing
  toasts. Carrying the last decisive values forward is what stops a blank or
  transitional poll from erasing the signal, which otherwise produced missed
  crashes (the poll after the gap was read against the gap) and phantom
  recoveries.
- `stopped`: the previous entry exists, its `down` is `false`, and the current
  `down` is `true`. Toast: `Service cifs is STOPPED` / body `state changed from
  RUNNING to STOPPED` (and `App appc is CRASHED` / `state changed from
  RUNNING to CRASHED`), `GLYPH_ALERT`, urgency `urgency_for warning`. When the
  previous decisive state is empty the body is `state changed to <cur>` rather
  than an empty `from`.
- `recovered`: the previous `down` is `true` and the current `down` is `false`.
  Toast: `Service cifs is running again` / `App appc is running again`, low
  urgency, `GLYPH_OK`.
- A first sighting never toasts. Reduce over the **current** rows only, like
  `seen.pools`/`seen.disks`, so a removed service or app entry does not linger.

### Model.js helpers

| Function | Behavior |
| --- | --- |
| `serviceStateRank(state)` | `RUNNING` → `0`; `""` → `2`; anything else → `1` |
| `appStateRank(state)` | `RUNNING` → `0`; `DEPLOYING`/`STARTING`/`STOPPING`/`""` → `2`; anything else → `1` |
| `worstServiceLevel(services)` | `"warning"` if any rank `1`, else `"unknown"` if any rank `2`, else `""` |
| `worstAppLevel(apps)` | same rule |
| `downServices(services)` | the rows with rank `1`, in input order, as a copy |
| `downApps(apps)` | the rows with rank `1`, in input order, as a copy |
| `appsUpgradeable(apps)` | count of `upgradeAvailable == true`, `0` for a non-list |
| `appLabel(app)` | `title` when non-empty, else `name`, else `""` |

All helpers are pure, never touch QML, and guard every list argument with
`arrayLike`; absence is `""`/`null`, never `0`.

### Search.js filters

- `services(list, needle)`: matches `service`, `state`, `id`.
- `apps(list, needle)`: matches `name`, `title`, `state`, `train`, `appVersion`,
  `version`.
Both mirror `Search.disks` exactly: copy semantics, empty needle returns every
row, non-list and junk rows do not throw.

### Writes (`bin/truenas-api`)

`truenas-api <verb> <name>`; the usage text lists every verb. One positional
argument, required by every verb (`exit 2` when missing).

| Verb | Method + path | Body |
| --- | --- | --- |
| `dismiss <uuid>` | `POST /api/v2.0/alert/dismiss` | `{"uuid": …}` |
| `restore <uuid>` | `POST /api/v2.0/alert/restore` | `{"uuid": …}` |
| `service-start <name>` | `POST /api/v2.0/service/start` | `{"service": …}` |
| `service-stop <name>` | `POST /api/v2.0/service/stop` | `{"service": …}` |
| `service-restart <name>` | `POST /api/v2.0/service/restart` | `{"service": …}` |
| `app-start <name>` | `POST /api/v2.0/app/start` | `{"app_name": …}` |
| `app-stop <name>` | `POST /api/v2.0/app/stop` | `{"app_name": …}` |
| `app-redeploy <name>` | `POST /api/v2.0/app/redeploy` | `{"app_name": …}` |

Any 2xx answers `{"ok":true}` whether the NAS answered `true` (services) or a
job id (apps); a non-2xx answers `{error, message}` and exits `1`. The panel
calls `refreshAfterWrite()` after every write so the next poll reads the state
back.

### `truenasctl`

- `truenasctl services` prints `SERVICE  STATE  ENABLED`, one row per service,
  `ENABLED` is `yes`/`no`; a failed section prints `services unknown: <reason>`
  through `state_unknown_reason "$file" service`.
- `truenasctl apps` prints `APP  STATE  VERSION  UPDATE`, where `VERSION` is
  `version` or `unknown` and `UPDATE` is `yes`/`no`; a failed section prints
  `apps unknown: <reason>`.

### Warning section names

`service` and `app`. Views and `truenasctl` scan for both.

---

## Task A: Service and app read path — list, normalize, meta cache

**Files:**
- Modify: `share/normalize.jq`, `bin/truenas-poll`, `tests/cases/10-poll.sh`,
  `tests/cases/13-meta.sh`
- Create: `tests/fixtures/services.json`, `tests/fixtures/apps.json`

**Step 1: fixtures.** Add `tests/fixtures/services.json` (the eight live
services above) and `tests/fixtures/apps.json` (the four live apps, with
`metadata`, `portals`, `active_workloads` and a large `notes` on one row to
prove it is dropped). Sanitize: keep the real names/states, drop serials, keys
and full hostnames.

**Step 2: normalize.jq.** Add `service_norm` and `app_norm` producing exactly the
rows in the frozen contract, and add `--slurpfile services` / `--slurpfile apps`
to the top-level assembly. Output `services: ($service_rows | sort_by(.service))`
and `apps: ($app_rows | sort_by(.name))`.

**Step 3: poll.** Fetch `GET /api/v2.0/service` and `GET /api/v2.0/app` on the
meta cadence (inside the `meta_is_stale` branch, after the disk fetches), with
`shape='type == "array"'` for both. Extend `default_payload` with
`"services":[],"apps":[]`. Add `service_fetched/service_ok` and
`app_fetched/app_ok`. Reuse reconstructs `$WORK/services.json` and
`$WORK/apps.json` from `.services.rows` / `.apps.rows`. Extend `meta_is_stale`
and the meta-advance condition to all five sections, and cache the reduced wire
rows per the contract. Extend the final `state.json` assembly with `services`
and `apps`.

**Step 4: tests.** In `tests/cases/10-poll.sh`: map `/api/v2.0/service` and
`/api/v2.0/app` to the new fixtures in the healthy setup; assert the normalized
rows (count, sort, `enable`, `title`, `containers`, `webui`), and add failure
cases: a 500 on `/service` gives `services: []` plus a `service` warning while
pools still render, same for `/app`. Update the cold-poll request count from
`5` to `7` and keep the "no warnings on a clean poll" assertion green. In
`tests/cases/13-meta.sh`: update the cumulative warm count from `7` to `9`,
extend the self-heal loop over `services` and `apps`, and assert the cached
`apps` rows carry no `notes` and no image identifiers.

**Step 5:** `./tests/run.sh`, `bash -n bin/truenas-poll`, `jq empty` on the
fixtures.

**Step 6: Commit** — `feat: read services and apps on the meta cadence`.

---

## Task B: Service and app down/recovery notifications

**Files:**
- Modify: `bin/truenas-poll`, `tests/cases/11-notify.sh`

**Step 1:** Build the `service-decisions.json` / `app-decisions.json` reduction
exactly as the contract defines (`stopped` and `recovered`, reduce over current
rows only), gate on `services_ok` / `apps_ok`, and write `seen.services` /
`seen.apps`. On a failed poll leave both untouched.

**Step 2:** Toast with separate argv words, `--exec` last:
`Service cifs is STOPPED` / `state changed from RUNNING to STOPPED`, and the
recovery form. Never put wire text into the exec URL (it stays the configured
base).

**Step 3:** `tests/cases/11-notify.sh`: a service crossing RUNNING→STOPPED
toasts once and is not replayed on the next identical poll; STOPPED→RUNNING
toasts a recovery; a first sighting that is already STOPPED toasts nothing; a
failed `/service` poll leaves `seen.services` byte-for-byte and replays nothing;
the same four cases for apps; the notification argv shape check passes.

**Step 4:** `./tests/run.sh`, `bash -n bin/truenas-poll`.

**Step 5: Commit** — `feat: notify when a service or app goes down`.

---

## Task C: Model, Search and Links helpers

**Files:**
- Modify: `Model.js`, `Search.js`, `tests/model.mjs`, `tests/search.mjs`
- Test: `tests/links.mjs` (only if `Links.js` changes; it does not in M3)

**Step 1:** Add the eight Model helpers in the frozen contract, following the
`tempStateRank`/`tempLevel` style, with `arrayLike` guards and no fabricated
zero. `appLabel` must not print `"undefined"`.

**Step 2:** Add `Search.services` and `Search.apps`, copying `Search.disks`
including its copy semantics and junk-row tolerance.

**Step 3:** `tests/model.mjs`: one test group per helper; for each, the
unknown/absence case (`null`, `""`, non-list, a row with no state) proving it
does not become `0` or `"undefined"`. `tests/search.mjs`: the same block of
cases `disks` has for each new filter (matched fields, case-insensitivity, order
preserved, copy not identity, empty needle returns all, non-list returns `[]`,
junk rows do not throw).

**Step 4:** `./tests/run.sh`.

**Step 5: Commit** — `feat: add service and app helpers`.

---

## Task D: Services and Apps views, Panel tabs, Menu rows

**Files:**
- Create: `Views/Services.qml`, `Views/Apps.qml`
- Modify: `Panel.qml`, `Menu.qml`, `tests/cases/17-qml-structure.sh`

Run after A and C. The `17-qml-structure.sh` check cross-links the `Panel.qml`
tab keys, the `Panel.qml` `viewComponents` map and the `Menu.qml` view rows; all
three must gain `services` and `apps` (lowercase, exact indentation) or it
fails.

**Step 1:** `Views/Services.qml`, modelled on `Views/Disks.qml`: read
`view.panel.state`, guard `services` with `arrayLike`, a `warnings` lookup for
`section == "service"`, an `emptyText`/`warningLine` pair (a failed section says
why, never "0 services"), a `FilterField` + `Search.services`, and a `Card` per
service showing the name, a state chip tinted by `serviceStateRank`, and the
enabled flag. Actions: `service-start`/`service-stop`/`service-restart` through
`view.panel.runApi([...], cb)` then `refreshAfterWrite()`; every action goes
through `view.panel.requestConfirm(...)` because a misclick restarts a service.
A link-out line uses `Links.systemUrl(view.panel.baseUrl)`.

**Step 2:** `Views/Apps.qml`, same skeleton, `section == "app"`,
`Search.apps`, a `Card` per app showing `appLabel`, state tinted by
`appStateRank`, version, train, and an update marker when
`upgradeAvailable` is true. Actions: `app-start`/`app-stop`/`app-redeploy`
behind confirmation. When `webui` is present, a link-out opens it through
`view.panel.openUrl(app.webui.url)` (which applies `Links.safeUrl`); otherwise
fall back to `Links.appsUrl(view.panel.baseUrl)`.

**Step 3:** `Panel.qml`: add the two tab keys, the two `viewComponents` entries
and the two `Component { id: servicesView; Views.Services { panel: root } }` /
`appsView` registrations. `Menu.qml`: add `servicesText`/`appsText` detail
properties that print the down count, or the section's failure sentence for
unknown, and the two `{ kind: "view", args: ["services"], … }` /
`["apps"]` rows.

**Step 4:** `tests/cases/17-qml-structure.sh` keeps passing (it will, once all
three lists match). Add a `qmllint` gate locally.

**Step 5:** `./tests/run.sh`; `qmllint` 0 errors.

**Step 6: Commit** — `feat: add the Services and Apps views`.

---

## Task E: `truenas-api` control verbs

**Files:**
- Modify: `bin/truenas-api`, `tests/cases/15-api.sh`

**Step 1:** Generalise the argument guard to every verb and one positional
(`name`/`uuid`), keep `exit 2` for unknown verbs and missing arguments, and add
the eight-row verb table. Map verb → path + body key. Keep the key-on-stdin,
`jq -n --arg` body and `trap` structure exactly as the alert verbs do. A 2xx
with any body is `{"ok":true}`; anything else is `{error, message}` and exit 1.

**Step 2:** `tests/cases/15-api.sh`: for each of the six new verbs assert the
POST method, the exact route, the body key and value, and `ok` true; one error
case (a 404 from `/service/restart` for an unknown service carries the NAS
message); the missing-argument exit 2; and the key-never-in-logs check.

**Step 3:** `./tests/run.sh`, `bash -n bin/truenas-api`.

**Step 4: Commit** — `feat: add service and app control verbs to truenas-api`.

---

## Task F: `truenasctl services` and `truenasctl apps`

**Files:**
- Modify: `bin/truenasctl`, `tests/cases/14-ctl.sh`

**Step 1:** Add the two commands mirroring `cmd_disks`: the `[[ -s $file ]]`
guard, the `jq -e 'type == "object"'` unreadable guard, the
`state_unknown_reason "$file" service|app` gate that prints
`services unknown: <reason>` / `apps unknown: <reason>` and returns 0, then the
`jq -r` table. Add the dispatch arms and the usage lines.

**Step 2:** `tests/cases/14-ctl.sh`: hand-build a `state.json` with services and
apps and assert the two tables, the `enabled`/`update` formatting, an empty list
(`services: []`) printing just the header, and the unknown path when the
`service`/`app` section warning is present.

**Step 3:** `./tests/run.sh`, `bash -n bin/truenasctl`.

**Step 4: Commit** — `feat: add the truenasctl services and apps verbs`.

---

## Task G: Docs and version

**Files:**
- Modify: `docs/02-truenas-api.md`, `docs/03-features.md`,
  `docs/plans/2026-09-13-truenas-plugin-design.md`, `manifest.json`, `README.md`

**Run last, after the code tasks merge** (it documents their reality).

- `docs/02-truenas-api.md`: a milestone-3 section with the verified endpoint
  table and findings 1-7, including the synchronous `true` vs async job-id
  split, the missing `app/restart`, the `notes` size, and the exact 400/404
  messages.
- `docs/03-features.md`: a "Milestone 3, what ships" section (Services view,
  Apps view, down/recovery notifications, `truenasctl services`/`apps`, the six
  control verbs) and remove the M3 paragraph from **Planned**.
- `docs/plans/2026-09-13-truenas-plugin-design.md`: amend the `apps` row in the
  state sketch to the frozen shape, the notifications table (`app:<id>:state` /
  `service:<id>:state` ship), the writes list (`redeploy`, not `restart`, for
  apps), and note that no bar variant is added in M3.
- `manifest.json`: version `0.2.0` → `0.3.0`.
- `README.md`: remove apps/services from the **Planned** sentence.

**Verify:** `jq empty manifest.json`, then `./tests/run.sh`.

**Commit** — `docs: document milestone 3 and bump the version`.

---

## Execution

Wave layout (worktrees from the handoff recipe, one branch per task):

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m3-<slug> -b agent/desk/m3-<slug> master
# dispatch one implementer per task against its worktree
# reviewer (read-only) checks the branch, implementer fixes, reviewer re-checks
git merge --no-ff agent/desk/m3-<slug> -m "Merge Task <X>: <title>"
git worktree remove /tmp/opencode/tn-m3-<slug> --force
```

- **Wave 1, parallel:** A (read path), C (helpers), E (`truenas-api`).
- **Wave 2, parallel:** B (after A), D (after A + C), F (after A).
- **Wave 3:** G (after A-F; merge last).
- Reviews after each wave: spec-compliance reviewer, then code-quality reviewer,
  both read-only; a reviewer's finding goes back to the implementer and the same
  reviewer re-checks. No task merges with an open finding.
- After every merge run `./tests/run.sh` on master.

**Definition of done for M3:** all suites green; `qmllint` 0 errors;
`omarchy plugin validate` clean on a tree without `.agent`; `./scripts/dev-install
--restart`; against the live NAS `truenasctl poll` writes the eight services and
four apps with real states, `truenasctl services` and `truenasctl apps` print
them, and the panel renders both tabs; one live confirmed write is exercised on
a disposable target; `.agent/WORKLOG.md` and `docs/04-handoff.md` are updated;
`git push hub master`.
