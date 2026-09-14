# TrueNAS plugin — Milestone 2 implementation plan

> **For the executor:** work this plan task-by-task. Independent tasks run in
> git worktrees, one branch each, with a fresh implementer per task and a
> separate reviewer after. Steps are bite-sized; do not skip the "run it and
> watch it fail" step. See **Execution** at the bottom for the wave layout.

**Goal:** Milestone 2 — disk inventory, temperatures, a Disks view, temperature
notifications and the deferred `Temp` bar variant, all verified against the real
NAS (`https://nas.example:4433`, TrueNAS 25.10.6).

**Architecture:** unchanged from M1. `bin/truenas-poll` reads the disk endpoints
on the meta cadence into `state.json`; `BarWidget.qml` stays a read-only watcher;
the panel's Disks view renders the rows; notifications ride the existing
`seen.json` + `notify()` machinery. No writes in this milestone.

**Tech stack:** QML/Quickshell, bash + curl + jq, node for unit tests; the same
test harness as M1.

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

## Verified against the live NAS (2026-09-13, TrueNAS 25.10.6)

These were probed before this plan was written; the plan does **not** assume the
design doc's endpoint list.

| Purpose | Method | Path | Body | Observed answer |
| --- | --- | --- | --- | --- |
| disk inventory + pool mapping | POST | `/api/v2.0/disk/details` | `{"type":"USED"}` | JSON array, one object per disk |
| temperatures (+ critical) | POST | `/api/v2.0/disk/temperatures` | `{"name":["sda",…],"include_thresholds":true}` | JSON object `{"sda":[38.0,60.0],…}` |

Findings that constrain the design:

1. **SMART is gone.** `GET /api/v2.0/smart/test/results` is `404` on 25.10.6 and
   the 25.10 API reference has no `smart.*` methods at all (SMART tests were
   dropped after 24.10). M2 therefore ships **temperature** notifications, not
   SMART ones; the design's `smartHealth`/`lastTest` disk fields are dropped.
2. `GET /api/v2.0/disk/temperatures` is `405 Method Not Allowed`; it is POST
   only, and the parameter is **`name`** (singular, an array), not `names`. A
   bare array body is rejected with `Endpoint accepts multiple params`; an object
   carrying `names` is rejected with `not expected: names`.
3. With `include_thresholds:true` each value is `[tempC, criticalC]`; without it
   each value is a bare number. Normalize **both** shapes (a disk that reports no
   threshold can answer with the bare number even when thresholds are asked for).
4. `POST /api/v2.0/disk/details {"type":"BOTH"}` answers a **`{used,unused}`
   object**, while `{"type":"USED"}` answers a plain array. M2 uses `USED`: the
   array shape is simpler, and on the live box every disk is in use.
5. Disk→pool mapping comes from `imported_zpool` on `disk/details` (the plain
   `/disk` route has `"pool":null` on every row and is not used). Observed:
   `nvme0n1→storage`, `sda,sdb→boot-pool`, `sdc,sdd→Backup`.
6. `disk/details` returns `name, model, type (HDD|SSD), size, bus, rotationrate,
   imported_zpool, …` plus serials/identifiers that the plugin never stores.
7. Live temps: `{"nvme0n1":[42.85,78.85],"sda":[38.0,60.0],"sdb":[39.0,60.0],
   "sdd":[38.0,60.0],"sdc":[40.0,60.0]}`.

## Frozen contracts (all tasks code against these)

### `state.json` `disks` rows

```jsonc
[
  { "name": "sda", "model": "SATA_HDD_500G", "type": "HDD", "size": 500107862016,
    "pool": "boot-pool", "bus": "ATA",
    "tempC": 38.0, "tempCriticalC": 60.0, "tempState": "ok" }
]
```

- `pool` is `""` when `imported_zpool` is null. `size`, `tempC`,
  `tempCriticalC` are `null` when absent, never `0`. `model`/`type`/`bus` are
  `""` when absent. Rows sorted by `name` for stable tests and UI.
- `tempState` is computed **once, in `share/normalize.jq`** (the single source of
  truth the bash notifier and the QML view both read):
  - `tempC == null` or `tempCriticalC == null` → `"unknown"`
  - `tempC >= tempCriticalC` → `"critical"`
  - `tempC >= tempCriticalC - 10` → `"warning"`
  - otherwise → `"ok"`
- A failed disks fetch is `disks: []` plus a `{section:"disk"}` warning; a failed
  temperatures fetch leaves rows with `tempC:null, tempState:"unknown"` plus a
  `{section:"diskTemp"}` warning. Neither ever becomes a zero.

### `meta.json`

M1's `.system` object is unchanged. Two disk caches are added and always written
together with it on a successful meta refresh:

```jsonc
{ "system": { "fetchedAt": "...", "data": { …normalized… } },
  "disks":     { "fetchedAt": "...",
                 "rows": [ { "name": "sda", "model": "SATA_HDD_500G",
                             "type": "HDD", "size": 500107862016,
                             "imported_zpool": "boot-pool", "bus": "ATA" }, … ] },
  "diskTemps": { "fetchedAt": "...", "map": { "sda": [38.0, 60.0], … } } }
```

The cached disk rows are the raw wire fields the plugin consumes, under their
wire names (`name, model, type, size, imported_zpool, bus`); serials,
identifiers and lunids are dropped before the write and never reach disk. The
temperatures map is cached exactly as the wire wrote it. Caching wire fields
rather than normalized rows keeps exactly one normalizer owning the shape on
both the fetch and the reuse path. An existing meta.json without the new keys
reads as stale once, refetches once, and self-heals.
`meta_is_stale` is true unless all three are present and the `.system.fetchedAt`
age is below `META_MAX_AGE` (or `--force-meta`). Meta advances only when system,
disks, temperatures and normalization all succeeded; otherwise the previous meta
stays byte-for-byte intact.

### Notifications (`bin/truenas-poll`, `seen.json`)

`seen.json` gains:

```jsonc
"disks": { "sda": { "state": "ok", "tempC": 38.0, "lastNotifiedAt": "..." } }
```

- Gate: `disks_ok = normalize_ok && no "disk" warning && no "diskTemp" warning`.
  Without it, `seen.disks` is not written (a network blip must not replay every
  disk as hot on recovery).
- `hot`: a disk whose `tempState` is `warning`/`critical` where the previous
  recorded state was not (`ok`, `unknown` or absent). Toast:
  `Disk sda is hot` / `61 °C, critical at 60 °C` (critical → `GLYPH_CRITICAL`,
  urgency `urgency_for critical`; warning → `GLYPH_ALERT`, urgency
  `urgency_for warning`).
- `cooled`: `tempState == "ok"` where the previous state was warning/critical.
  Toast: `Disk sda cooled` / `38 °C`, low urgency, `GLYPH_OK`.
- Reduce over the **current** rows only, like `seen.pools`, so a removed disk's
  entry does not linger.
- The temperature request is built from the freshly fetched disk names; when the
  details fetch failed there are no names to ask about, so temperatures are
  skipped and only the `disk` section is warned about.

### Bar variant `Temp`

- `VARIANTS` gains `"Temp"`; manifest `options` gains `"Temp"` (order matches:
  `Default, Icon, Alerts, Capacity, Pool, Temp, Full`).
- `barView` gains `tempText` (e.g. `"54°"`, `""` when no temperature is known)
  and `tempLevel` (`"critical"`, `"warning"` or `""`; `""` means the item's own
  tint).
- `tempSegments(view)` prints `tempText` tinted by `tempLevel`; `""` prints
  nothing — the hottest known temperature, never a fabricated zero.
- Offline/unconfigured still override every variant with the plug/cog glyph.

### CLI

`truenasctl disks` prints one row per disk:
`NAME  TYPE  SIZE  POOL  TEMP`; `TEMP` is `38 °C` or `unknown`; a failed disks
or temperatures section prints the `state_unknown_reason` sentence instead of an
empty table.

### Warning section names

`disk` (details) and `diskTemp` (temperatures). Views scan for both.

---

## Task A: Disk read path — details, temperatures, meta cache

**Files:**
- Modify: `share/normalize.jq`, `bin/truenas-poll`
- Create: `tests/fixtures/disks.json`, `tests/fixtures/disk-temperatures.json`,
  `tests/fixtures/disk-temperatures-hot.json`
- Modify: `tests/cases/10-poll.sh`, `tests/cases/13-meta.sh`

**Rules:** implement the frozen contracts above. No serials, identifiers or
lunids in fixtures — the sanitized fixtures are in the plan and hold only the
fields the plugin consumes.

**Fixtures** (copy verbatim):

`tests/fixtures/disks.json`

```json
[
  { "name": "nvme0n1", "model": "NVMe_SSD_2T", "type": "SSD",
    "size": 2000398934016, "imported_zpool": "storage", "bus": "UNKNOWN" },
  { "name": "sda", "model": "SATA_HDD_500G", "type": "HDD",
    "size": 500107862016, "imported_zpool": "boot-pool", "bus": "ATA" },
  { "name": "sdb", "model": "SATA_HDD_500G", "type": "HDD",
    "size": 500107862016, "imported_zpool": "boot-pool", "bus": "ATA" },
  { "name": "sdc", "model": "SATA_HDD_4T", "type": "HDD",
    "size": 4000787030016, "imported_zpool": "Backup", "bus": "ATA" },
  { "name": "sdd", "model": "SATA_HDD_4T", "type": "HDD",
    "size": 4000787030016, "imported_zpool": "Backup", "bus": "ATA" }
]
```

`tests/fixtures/disk-temperatures.json`

```json
{ "nvme0n1": [42.85, 78.85], "sda": [38.0, 60.0], "sdb": [39.0, 60.0],
  "sdc": [40.0, 60.0], "sdd": [38.0, 60.0] }
```

`tests/fixtures/disk-temperatures-hot.json`

```json
{ "nvme0n1": [42.85, 78.85], "sda": [61.0, 60.0], "sdb": [39.0, 60.0],
  "sdc": [51.0, 60.0], "sdd": [38.0, 60.0] }
```

**Step 1: Failing tests.** In `tests/cases/10-poll.sh`:

- add a helper `all_healthy()` with the two new stubs, and extend the existing
  clean-poll test:
  ```bash
  respond '/api/v2.0/disk/details' 0 200 "$ROOT/tests/fixtures/disks.json"
  respond '/api/v2.0/disk/temperatures' 0 200 "$ROOT/tests/fixtures/disk-temperatures.json"
  ```
- assert the normalized rows, e.g.
  ```bash
  check "five disks" 5 "$(state '.disks | length')"
  check "rows sorted by name" "nvme0n1" "$(state '.disks[0].name')"
  check "pool mapping" "boot-pool" "$(state '.disks[] | select(.name=="sda") | .pool')"
  check "temperature" "38" "$(state '.disks[] | select(.name=="sda") | .tempC')"
  check "critical" "60" "$(state '.disks[] | select(.name=="sda") | .tempCriticalC')"
  check "state ok" "ok" "$(state '.disks[] | select(.name=="sda") | .tempState')"
  ```
- a failure test: stub only `disk/details` (or a 500) and assert
  `warnings[] | select(.section=="disk")` is non-empty, `disks == []`, and that
  no `0` temperature is invented.
- a temperatures-failure test: details OK, temperatures 500 → rows present,
  every `tempC == null` and `tempState == "unknown"`, warning section
  `diskTemp`.
- a hot test using `disk-temperatures-hot.json` → `sda` is `critical`, `sdc` is
  `warning`.
- update **every** request-count assertion (`grep -n requests tests/cases/*.sh`)
  from three meta+fresh requests to five on a cold poll; a warm (fresh meta)
  poll stays at two fast requests.

In `tests/cases/13-meta.sh`: add the disk stubs to the meta response bundle;
assert `.disks.rows` and `.diskTemps.map` exist after a cold poll; assert a
second poll with fresh meta makes **no** disk requests (reuse path); assert a
failed disk fetch leaves the previous meta byte-for-byte intact.

**Step 2: Run and watch it fail** — `./tests/run.sh`; the new assertions fail
because `state.disks` is null and the stub map has no disk entries.

**Step 3: Implement.** In `bin/truenas-poll`:

- extend `fetch()` with an optional method and payload so POSTs share the one
  failure path (`fetch disk "/api/v2.0/disk/details" "$out" POST "$payload"`;
  keep GET as the default so existing calls are untouched);
- add shape checks: `disk` → `type == "array"`, `diskTemp` → `type == "object"`;
- write `$WORK/disk-details-request.json` = `{"type":"USED"}` before the fetch;
  after a successful details fetch build the temperatures payload with
  `jq -c '{name: [.[].name], include_thresholds: true}'` and POST it; on a
  details failure skip the temperatures request entirely;
- extend `meta_is_stale` as specified; on the stale path fetch system, disks and
  temperatures and advance meta only when all succeeded; on the reuse path copy
  `.disks.rows` and `.diskTemps.map` back into `$WORK/`;
- pass `--slurpfile disks "$WORK/disks.json" --slurpfile diskTemps
  "$WORK/disk-temps.json"` to `normalize.jq`;
- add `"disks":[]` to `default_payload()` and `disks: $p.disks` to the state
  builder.

In `share/normalize.jq`: add `def disk_norm` (the frozen row shape and the
`tempState` rule, handling both `[temp, crit]` and bare-number temperature
values, using the existing `num` helper), read `$disks[0] // []` and
`$diskTemps[0] // {}`, sort by name, and add `disks: $disk_rows` to the output.

**Step 4: Run and watch it pass** — `./tests/run.sh`, then
`bash -n bin/truenas-poll`, `jq empty tests/fixtures/*.json`.

**Step 5: Commit** — `feat: read disks and temperatures into state.json`.

---

## Task B: Disk temperature notifications

**Files:**
- Modify: `bin/truenas-poll`, `tests/cases/11-notify.sh`

**Depends on Task A** (merge order A → B).

**Step 1: Failing tests.** In `tests/cases/11-notify.sh` extend the response
bundle with the disk fixtures and add cases:

- baseline poll (all cool) → no disk toast;
- then hot temps (`disk-temperatures-hot.json`) → one toast whose headline is
  `Disk sda is hot` and whose body contains `60`, plus `Disk sdc is hot` for the
  warning band; assert the notification log and `seen.json` `.disks.sda.state`
  is `critical`;
- a third poll with healthy temps → `Disk sda cooled` toast, low urgency;
- a poll where `sda` stays hot → **no** second toast (no renotify);
- a poll where the temperatures request fails → no disk toast and `seen.json`
  `.disks` unchanged (byte-for-byte the previous value).

**Step 2: Run and watch it fail.**

**Step 3: Implement** the `seen.disks` shape, the `disks_ok` gate, the jq
decisions document, the toasts and the seen reduction exactly as frozen above.
Follow the existing pool block (`bin/truenas-poll` ~374-424) as the template;
`urgency_for`, `glyph_for` and `notify` are reused, not copied.

**Step 4:** `./tests/run.sh`, `bash -n bin/truenas-poll`.

**Step 5: Commit** — `feat: notify when a disk runs hot or cools`.

---

## Task C: Model.js temperature helpers

**Files:**
- Modify: `Model.js`, `tests/model.mjs`

**Independent of A** (pure JS over the frozen row shape).

**Step 1: Failing tests** in `tests/model.mjs` for:

- `tempStateRank("critical") > tempStateRank("warning") > tempStateRank("ok")`,
  `tempStateRank("unknown")` lowest; unknown strings lowest.
- `tempLevel([...])` → `"critical"` when any row is critical, `"warning"` when
  the worst is warning, `""` for ok/unknown/empty/null.
- `hottestTempC(rows)` → the max known `tempC`, `null` when none; ignores
  `null`/`""`/NaN and never returns `0` for absence.
- `hotTempLabel(rows)` → `"54°"` (rounded), `""` when unknown.
- `formatTemp(38.0)` → `"38 °C"`, `formatTemp(null)` → `""`,
  `formatTemp("")` → `""`.
- `tempThresholdText({tempCriticalC:60})` → `"critical at 60 °C"`,
  `null`/absent → `""`.
- every helper survives a non-array (`null`, `""`): `arrayLike` guard, no throw.

**Step 2: Run and watch it fail** — `node tests/model.mjs` (or `./tests/run.sh`).

**Step 3: Implement** the helpers as pure top-level functions with the existing
style (`.pragma library` untouched, no QML types, unknown is `""`/`null`, never
`0`). Do **not** import Model from `BarVariants.js`; the widget passes values.

**Step 4:** `./tests/run.sh`.

**Step 5: Commit** — `feat: model helpers for disk temperatures`.

---

## Task D: `Temp` bar variant

**Files:**
- Modify: `BarVariants.js`, `BarWidget.qml`, `manifest.json`,
  `tests/bar-variants.mjs`

**Depends on Task C** for the helper names (the contract is frozen above, so it
can be built in the same wave and merged after C).

**Step 1: Failing tests** in `tests/bar-variants.mjs`: update the `VARIANTS`
equality assertions to include `"Temp"`; a view with `tempText:"54°"` prints a
segment `54°` with `tempLevel` passed through; `tempText:""` prints only the
main glyph; offline still overrides `Temp` with the plug glyph.

**Step 2: Run and watch it fail.**

**Step 3: Implement**: `VARIANTS` gains `Temp` (`BarVariants.js:34`),
`tempSegments` slot into `bodySegments` (`:136-149`) copying `capacitySegments`;
`BarWidget.qml` adds `tempText`/`tempLevel` to `barView` (`:66-72`) computed
through the Task C helpers over `state.disks`; `manifest.json` adds `Temp` to
`options` and names it in the description. No new `.js` file, so the shared-JS
lists in `tests/cases/17-qml-structure.sh` are untouched.

**Step 4:** `./tests/run.sh`; `qmllint` with the repo's baseline (0 errors).

**Step 5: Commit** — `feat: add the Temp bar variant`.

---

## Task E: Disks view and tab

**Files:**
- Create: `Views/Disks.qml`
- Modify: `Panel.qml`, `Menu.qml`, `Search.js`, `tests/search.mjs`

**Independent**; renders the frozen row shape whether or not Task A has merged.

**Step 1: Failing tests.** `tests/search.mjs`: `Search.disks(rows, "nvme")`
matches on name; `"nvme"` matches model; `"storage"` matches pool; `""` copies
the list; a non-array yields `[]`; a row without fields does not throw. The QML
structure suite discovers `.qml` automatically; run it after creating the view.

**Step 2: Run and watch it fail.**

**Step 3: Implement.**

- `Search.js`: add `disks(list, needle)` matching name/model/type/pool/bus, in
  the same shape as `alerts`/`pools`.
- `Views/Disks.qml`: root `Column { required property var panel }`, props
  `nasState/connection/connected/disks` copied from `Views/Pools.qml`; a
  `FilterField` (`Ui/FilterField.qml`) bound to a local `query` filtering
  through `Search.disks`; a warning sentence when `warnings[]` contains section
  `disk` or `diskTemp` (same pattern as `poolWarning`); an empty sentence
  distinguishing "no state yet" / "offline" / "no disks reported"; then one
  `Ui/Card` per disk:
  - header: `name` (foreground) and the temperature right-aligned — `Model.formatTemp(tempC)` tinted urgent/accent/foreground by `tempState`, or the dim
    word `temperature unknown`;
  - second line: `model` dim, elided;
  - third line: `type · size · pool · bus` (skip empty pieces, never print a
    fabricated size);
  - fourth line, only when known: `Model.tempThresholdText(disk)` dim, e.g.
    `critical at 60 °C`.
- `Panel.qml`: add `{ key: "disks", label: "Disks" }` after Pools in `tabs`
  (`:74-79`), a `viewComponents` entry (`:81-86`), and a
  `Component { id: disksView; Views.Disks { panel: root } }` (`:568-571`).
- `Menu.qml`: add a `Disks` row next to the other view rows (`:154-166`).

**Step 4:** `./tests/run.sh`; `qmllint -I "$OMARCHY_PATH/shell"` over
`Views/Disks.qml` and the touched files (0 errors, baseline warnings OK).

**Step 5: Commit** — `feat: add the Disks view`.

---

## Task F: `truenasctl disks`

**Files:**
- Modify: `bin/truenasctl`, `tests/cases/14-ctl.sh`

**Independent.**

**Step 1: Failing tests** in `tests/cases/14-ctl.sh`: write a state.json with
three disks (one unknown temp, one hot) and assert the table's header, the
`38 °C` cell, the `unknown` cell, and that a `disk` warning produces the
`state_unknown_reason` sentence instead of a table. Never assert `0 °C`.

**Step 2: Run and watch it fail.**

**Step 3: Implement** `cmd_disks` next to `cmd_pools`
(`bin/truenasctl:348-354`), `disks) cmd_disks ;;` in the dispatch
(`:471-485`) and a usage line (`:18-38`). Reuse the `human` jq helper from
`cmd_status` for sizes, and `state_unknown_reason` for the failure path —
extend it if it only knows `alert`/`pool`.

**Step 4:** `./tests/run.sh`, `bash -n bin/truenasctl`.

**Step 5: Commit** — `feat: add the truenasctl disks verb`.

---

## Task G: Docs and version

**Files:**
- Modify: `docs/02-truenas-api.md`, `docs/03-features.md`,
  `docs/plans/2026-09-13-truenas-plugin-design.md`, `manifest.json`

**Run last, after the code tasks merge** (it documents their reality).

- `docs/02-truenas-api.md`: a milestone-2 section with the verified endpoint
  table and findings 1-7 above, including the 405/404/parameter-name traps and
  the `imported_zpool` mapping. State plainly that SMART test results are not
  available on 25.04+ and that temperature is the disk signal this milestone
  uses.
- `docs/03-features.md`: a "Milestone 2, what ships" section (Disks view, Temp
  variant, temperature notifications, `truenasctl disks`) and remove the M2
  paragraph from **Planned**.
- `docs/plans/2026-09-13-truenas-plugin-design.md`: amend the disk row in the
  state sketch (`smartHealth`/`lastTest` → `bus`/`tempCriticalC`/`tempState`),
  the notifications table (`disk:<name>:smart` is not shipped; explain the API
  removal) and the "disk/temperatures may need a names parameter" risk with the
  verified answer.
- `manifest.json`: version `0.1.0` → `0.2.0`.

**Verify:** `jq empty manifest.json`, then `./tests/run.sh`.

**Commit** — `docs: document milestone 2 and bump the version`.

---

## Execution

Wave layout (worktrees from the handoff recipe, one branch per task):

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m2-<slug> -b agent/desk/m2-<slug> master
# dispatch one implementer per task against its worktree
# reviewer (read-only) checks the branch, implementer fixes, reviewer re-checks
git merge --no-ff agent/desk/m2-<slug> -m "Merge Task <X>: <title>"
git worktree remove /tmp/opencode/tn-m2-<slug> --force
```

- **Wave 1, parallel:** A, C, E, F.
- **Wave 2, parallel:** B (after A), D (after C), G (after A-D can be assumed;
  merge G last).
- Reviews after each wave: spec-compliance reviewer, then code-quality reviewer,
  both read-only; a reviewer's finding goes back to the implementer and the same
  reviewer re-checks. No task merges with an open finding.
- After every merge run `./tests/run.sh` on master.

**Definition of done for M2:** all suites green; `qmllint` 0 errors;
`omarchy plugin validate` clean on a tree without `.agent`; `./scripts/dev-install
--restart`; against the live NAS `truenasctl poll` writes five disk rows with
real temperatures and `truenasctl disks` prints them; the bar renders the `Temp`
variant and the panel renders the Disks tab; `.agent/WORKLOG.md` and
`docs/04-handoff.md` are updated; `git push hub master`.
