# TrueNAS plugin — Milestone 1 implementation plan

> **For the executor:** REQUIRED SUB-SKILL: use `superpowers:executing-plans` (or
> `superpowers:subagent-driven-development`) to work this plan task-by-task.
> Steps are 2–5 minutes each. Do not skip the "run it and watch it fail" step.

**Goal:** A working `io.github.h4ad.truenas` plugin: one poller writing
`state.json`, a bar item with variants, a popout with Health / Pools / Alerts /
Config, alert and pool notifications, and `truenasctl`. Verified against the real
NAS at `https://nas.example:4433` at the end.

**Architecture:** `Service.qml` (singleton) runs `bin/truenas-poll` on a timer;
the widget only watches `state.json`. Writes go through the panel's single
process queue and then a forced re-poll. Reference source for every pattern:
`~/Projects/omarchy-signoz` (`bin/`, `Service.qml`, `BarWidget.qml`, `Panel.qml`,
`Model.js`, `tests/`).

**Tech stack:** QML/Quickshell, bash + curl + jq, node for unit tests, `qml6`.

**Design doc:** `docs/plans/2026-09-13-truenas-plugin-design.md`.

---

## Conventions

- Work on branch `master`. Commit after every task with a Conventional Commit
  (`feat:`, `fix:`, `test:`, `docs:`, `chore:`). Never `git stash`; never
  force-push.
- Run `bash -n <file>` on every shell file you touch, and
  `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml`
  on QML changes. Bare `qmllint` is Qt 5 and lies.
- The API key is never committed, never passed as an argument, never logged.
- Tests run with no network and no desktop: `./tests/run.sh`.

## Endpoint map for this milestone

| Purpose | Method | Path |
| --- | --- | --- |
| version probe + hostname/mem/uptime | GET | `/api/v2.0/system/info` |
| alerts | GET | `/api/v2.0/alert/list` |
| dismiss alert | POST | `/api/v2.0/alert/dismiss` body `{"uuid":"..."}` |
| restore alert | POST | `/api/v2.0/alert/restore` body `{"uuid":"..."}` |
| pools + scrub | GET | `/api/v2.0/pool` |

TrueNAS alert `level` values seen in the wild: `INFO`, `NOTICE`, `WARNING`,
`ERROR`, `CRITICAL`, `ALERT`, `EMERGENCY`. We bucket them worst-first as
`critical` (CRITICAL, ALERT, EMERGENCY), `error`, `warning`, `notice`, `info`.

Pool `status` values: `ONLINE`, `DEGRADED`, `FAULTED`, `OFFLINE`, `UNAVAIL`,
`REMOVED`. Healthy is `ONLINE` only.

---

## Task 1: Test harness and stubs

**Files:**
- Create: `tests/run.sh`, `tests/lib.sh`, `tests/stubs/curl`,
  `tests/stubs/omarchy-notification-send`, `tests/README.md`
- Create: `tests/cases/00-smoke.sh`

Copy the harness from the reference so the two repos test the same way:
`tests/run.sh` and `tests/lib.sh` are `~/Projects/omarchy-signoz/tests/*`, with
every `SIGNOZ_` renamed `TRUENAS_`, `omarchy/signoz` → `omarchy/truenas`,
`signoz-poll` → `truenas-poll`, `signoz-api` → `truenas-api`,
`signozctl` → `truenasctl`. The stub `tests/stubs/curl` is copied verbatim
(it is URL-shape agnostic). `tests/stubs/omarchy-notification-send` verbatim.

**Step 1: Write the failing test** — `tests/cases/00-smoke.sh`

```bash
# shellcheck shell=bash
test_case "the harness runs and the workspace is isolated"
setup
check "XDG_STATE_HOME points at the temp dir" "$WORK/state" "$XDG_STATE_HOME"
check "a credentials file the suite wrote is mode 600" 600 \
  "$(stat -c '%a' "$TRUENAS_CREDENTIALS_FILE")"
teardown
```

**Step 2: Run it and watch it fail** — `./tests/run.sh`
Expected: the file is missing so nothing runs, then the node suites report
missing. Fail.

**Step 3: Implement the harness** — copy and rename as above. In `lib.sh` the
default credentials line is `TRUENAS_API_KEY=test-key`, and
`single_instance_config()` writes:

```json
{ "schema": 1, "pollSeconds": 30, "timeoutSeconds": 8,
  "insecureTLS": true,
  "instances": [ { "id": "nas", "label": "NAS",
    "baseUrl": "https://nas.example:4433" } ],
  "notify": {} }
```

(Keep the `instances` array even though the product is single-instance: one
commented config shape is cheaper than a second parser, and the array makes the
future multi-NAS path a config change. If this grows teeth, cut it — the design
says single NAS.)

Because the node suites are named in `run.sh`, create empty-but-valid
`tests/model.mjs`, `tests/links.mjs`, `tests/bar-variants.mjs` that print
`node: N passed, 0 failed`, so the harness is green from the start.

**Step 4: Run it and watch it pass** — `./tests/run.sh`
Expected: `all suites green`.

**Step 5: Commit** — `test: add bash/node test harness and stubs`.

---

## Task 2: truenas-lib.sh

**Files:**
- Create: `bin/truenas-lib.sh`
- Test: `tests/cases/12-config.sh`

Adapt `~/Projects/omarchy-signoz/bin/signoz-lib.sh` wholesale, renaming
`SZ_`→`TN_`, `signoz`→`truenas`. Keep the function names: `tn_now`, `tn_warn`,
`tn_have`, `tn_write_atomic`, `tn_read_json`, `tn_write_json`, `tn_load_config`,
`tn_creds_lookup`, `tn_creds_mode_ok`, `tn_resolve_key`, `tn_http_request`,
`tn_http_get`, `tn_classify`, `tn_error_message`, `tn_curl_rc_message`.

Changes from the reference:
1. `TN_CONFIG_FILE` default `~/.config/omarchy/truenas/config.json`.
2. Credential name is `TRUENAS_API_KEY`; keep the reference's per-instance
   `TRUENAS_API_KEY_<UPPER>` lookup ahead of the bare name, so the shape is
   already right when a second NAS arrives.
3. `tn_classify` classifies the status code **before** requiring a JSON body, so
   an empty-body `401`/`404` is still `unauthenticated`/`not_found`; maps `401` →
   `unauthenticated`, `403` → `forbidden`, `404` → `not_found`, `5xx` →
   `server_error`; treats `202` as success; keeps `not_json` for a `2xx` with a
   non-JSON body (a route that does not exist must never read as healthy).
4. Add `tn_insecure_args`: prints `-k` only when config `insecureTLS == true`.
   `insecureTLS` is type-guarded (`!= false` would be wrong; read the boolean
   explicitly).
5. Add `tn_dialect()`: cached from `meta.json`. Returns `rest-v2.0`.

The helpers keep the reference signatures: `tn_resolve_key <id> <key_file>
<key_cmd>` prints `ok:<key>` / `err:<reason>`. Add
`source "$ROOT/bin/truenas-lib.sh"` at the top of this case file so it can call
them directly; the reference tests normally go through the CLI, but these three
behaviours are cheaper and more precise to assert at the function, and the CLI
verbs that wrap them are tested in Task 7.

**Step 1: Write the failing tests** — `tests/cases/12-config.sh`

```bash
# shellcheck shell=bash
source "$ROOT/bin/truenas-lib.sh"

test_case "a key in the credentials file resolves"
setup
check "resolves" "ok:test-key" "$(tn_resolve_key nas '' '')"

test_case "a world-readable credentials file is refused"
setup
chmod 644 "$TRUENAS_CREDENTIALS_FILE"
check "refused" "err:credentials_permissions" "$(tn_resolve_key nas '' '')"

test_case "apiKeyCommand wins and never touches a file"
setup
rm -f "$TRUENAS_CREDENTIALS_FILE"
check "command key" "ok:cmd-key" "$(tn_resolve_key nas '' "printf 'cmd-key\n'")"

test_case "insecureTLS controls -k"
setup
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": true, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "on" "-k" "$(tn_insecure_args)"
cat >"$TRUENAS_CONFIG_FILE" <<JSON
{ "insecureTLS": false, "instances": [ { "id": "nas", "baseUrl": "https://nas.example" } ] }
JSON
check "off" "" "$(tn_insecure_args)"
```

`tn_insecure_args` reads `TN_CONFIG_FILE` itself (it is called before a config
is loaded on some paths), and prints nothing for a missing or unparsable file.

**Step 2: Run and watch it fail** — `./tests/run.sh` → `command not found`.

**Step 3: Implement** — as adapted. `tn_http_request` must send the key through
a `--config -` stdin document so it never lands in `argv`; the reference does
this and the stub tests it.

**Step 4: Run and watch it pass**, and `bash -n bin/truenas-lib.sh`.

**Step 5: Commit** — `feat: add truenas-lib config, credentials and http helpers`.

---

## Task 3: Manifest, entry-point stubs, dev-install

**Files:**
- Create: `manifest.json`, `LICENSE` (MIT), `README.md` (stub),
  `Service.qml`, `BarWidget.qml`, `Panel.qml`, `Menu.qml`, `Model.js`,
  `BarVariants.js`, `Links.js`, `Search.js`, `scripts/dev-install`,
  `.gitignore`
- Test: `omarchy plugin validate .`

`manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "io.github.h4ad.truenas",
  "name": "TrueNAS",
  "version": "0.1.0",
  "author": "Vinícius Lourenço",
  "license": "MIT",
  "description": "TrueNAS pool health and active alerts on the Omarchy bar, with desktop notifications and a popout for pools, alerts and system state.",
  "homepage": "https://github.com/h4ad/omarchy-truenas",
  "kinds": ["bar-widget", "menu", "service"],
  "keepLoaded": true,
  "entryPoints": {
    "barWidget": "BarWidget.qml",
    "menu": "Menu.qml",
    "service": "Service.qml"
  },
  "barWidget": {
    "displayName": "TrueNAS",
    "description": "Pool health, alerts and capacity, with a popout for everything the NAS is doing.",
    "category": "Monitoring",
    "aliases": ["truenas", "nas", "zfs", "pools", "storage"],
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": {
      "variant": "Default",
      "hideWhenHealthy": false,
      "panelWidth": 460,
      "configPath": ""
    },
    "schema": [
      { "key": "variant", "type": "enum",
        "label": "What the bar shows",
        "options": ["Default", "Icon", "Alerts", "Capacity", "Pool", "Full"],
        "defaultValue": "Default",
        "description": "Default is the active alert count when anything is firing, otherwise the fullest pool's capacity. Icon is the glyph alone, tinted by the worst state. Alerts is the active alert count. Capacity is the fullest pool. Pool is the worst pool status word. Full adds alerts and capacity. An unreachable or unconfigured NAS overrides every variant with a plug or cog: a number the plugin cannot vouch for is never printed as one." },
      { "key": "hideWhenHealthy", "type": "boolean",
        "label": "Hide the icon when everything is healthy",
        "defaultValue": false,
        "description": "Off keeps a dimmed glyph on the bar, which is also how you tell the plugin is alive and reaching the NAS." },
      { "key": "panelWidth", "type": "integer", "label": "Panel width",
        "min": 360, "max": 900, "step": 20, "defaultValue": 460 },
      { "key": "configPath", "type": "string", "defaultValue": "",
        "label": "Config file",
        "description": "Leave empty for ~/.config/omarchy/truenas/config.json. The API key is never stored in shell.json: it lives in the credentials file the config names, at mode 600." }
    ]
  }
}
```

The QML stubs must be loadable: `Model.js` starts with `.pragma library`; each
QML file imports `QtQuick`/`Quickshell`. `scripts/dev-install` copies every
top-level entry except a deny-list (`.git .agent docs tests scripts preview.png
.gitignore`), wipes `$DEST` first so a deleted file cannot linger, guards `jq`,
and only claims a restart when the restart succeeded.

**Steps:** write the files → validate a clean tree, because the dev repo's
`.agent` symlink is itself a symlink and `omarchy plugin validate` refuses any
symlink outside `.git`:

```bash
rm -rf /tmp/tn-validate && mkdir -p /tmp/tn-validate
git archive HEAD | tar -x -C /tmp/tn-validate
omarchy plugin validate /tmp/tn-validate    # no output, exit 0
```

(`git archive` also excludes untracked files, so the staged tree is exactly what
ships. `scripts/dev-install` validates the installed copy at `$DEST`, which is
the same idea.) → `./tests/run.sh` still green → commit `chore: scaffold plugin
manifest and entry points`.

---

## Task 4: Poll reads alerts, system and pools

**Files:**
- Create: `bin/truenas-poll`, `share/normalize.jq`
- Create fixtures: `tests/fixtures/system-info.json`, `pools-healthy.json`,
  `pools-degraded.json`, `alerts-empty.json`, `alerts-mixed.json`,
  `alerts-critical.json`, `err-401.json`, `err-500.json`
- Test: `tests/cases/10-poll.sh`

`share/normalize.jq` reads the three bodies (passed with `--slurpfile`) and
emits the stable shape from the design doc. Rules that matter:

- `level | ascii_upcase` → bucket; unknown level → `notice`, never dropped.
- counts computed from non-dismissed alerts only; `dismissed` counted separately.
- pool `usedPct = (allocated / size * 100)` rounded to one decimal; `null` when
  `size` is 0 or absent (never `0`).
- `scan` and `topology` carried through only when present; a missing scrub is
  `null`, not a fake `"FINISHED"`.
- `warnings` gets one entry per section whose request failed. A failed section
  contributes no rows and no zeros.

`bin/truenas-poll` structure, copying `signoz-poll`:
1. `--quiet`, `--force-meta` parsing; `tn_load_config`; `tn_resolve_key`.
2. `tn_http_get` each endpoint into a `mktemp` body; on non-empty
   `tn_classify` record `{error, message}` and skip normalization for it.
3. `jq -f share/normalize.jq --slurpfile ... >payload.json`.
4. Merge payload + connection into `state.json` via `tn_write_json`.

**Tests** (each with a `respond`/`respond_add` line per endpoint):

```bash
test_case "a healthy NAS reports the pools and a quiet count"
setup; single_instance_config
respond     "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
respond_add "/api/v2.0/pool"       0 200 "$ROOT/tests/fixtures/pools-healthy.json"
respond_add "/api/v2.0/system/info" 0 200 "$ROOT/tests/fixtures/system-info.json"
poll
check "connected" true "$(state '.connection.ok')"
check "two pools" 2 "$(state '.pools | length')"
check "no alerts" 0 "$(state '.counts.total')"
check "storage is used" 71 "$(state '.pools[] | select(.name=="storage") | .usedPct')"
teardown

test_case "an unreachable NAS is unknown, not zero"
setup; single_instance_config
respond "/api/v2.0/alert/list" 7 0 ""
poll
check "not connected" false "$(state '.connection.ok')"
check "no count is invented" 0 "$(state '.counts.total')"
check "and the reason is named" unreachable "$(state '.connection.error')"
check "the pool list is empty rather than wrong" 0 "$(state '.pools | length')"
teardown

test_case "a 401 says the key was rejected"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 401 "$ROOT/tests/fixtures/err-401.json"
poll
check "named as unauthenticated" unauthenticated "$(state '.connection.error')"
teardown
```

Fixtures: hand-write realistic TrueNAS SCALE JSON (see
`https://api.truenas.com/v25.04.2/`), **sanitized** — serials like `SERIAL0`,
no real hostnames. Include one degraded pool with a scrub in progress and one
with checksum errors.

**Steps:** failing test → run → implement → run → `bash -n`, `jq empty` on every
fixture → commit `feat: poll TrueNAS alerts, system and pools into state.json`.

---

## Task 5: Notifications and seen.json

**Files:**
- Modify: `bin/truenas-poll`
- Test: `tests/cases/11-notify.sh`

Reuse the reference's decision algorithm: compute `firing`, `renotify`,
`resolved` against `seen.json`, batch above `notify.batchThreshold`, then write
the new `seen.json`. Keys are per the design table. A failed poll leaves
`seen.json` untouched.

`urgency_for`: CRITICAL/ALERT/EMERGENCY → normal unless `notify.stickyCritical`;
ERROR/WARNING → normal; else low. Glyphs: critical ``, warning ``, ok ``,
offline ``.

**Tests:**

```bash
test_case "a new critical alert toasts once"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
check "one toast" 1 "$(notifications)"
check "and it names the alert" 1 \
  "$(grep -c 'Pool storage state is DEGRADED' "$STUB_NOTIFY_LOG" || true)"
poll
check "the same alert does not toast again" 1 "$(notifications)"

test_case "clearing an alert toasts its resolution"
setup; single_instance_config
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-critical.json"
poll
respond "/api/v2.0/alert/list" 0 200 "$ROOT/tests/fixtures/alerts-empty.json"
poll
check "a resolution toast" 1 "$(grep -c 'Resolved' "$STUB_NOTIFY_LOG" || true)"

test_case "a pool going DEGRADED toasts, recovering is low"
# run once healthy, once degraded, once healthy; assert one warning and one low
# that mentions the pool by name.

test_case "an unreachable poll does not replay alerts on recovery"
# critical, then rc=7, then critical again: exactly one toast total.
```

**Steps:** failing → implement → pass → commit
`feat: notify on new, cleared, degraded and recovered alerts and pools`.

---

## Task 6: Meta cadence and --force-meta

**Files:**
- Modify: `bin/truenas-poll`
- Test: `tests/cases/13-meta.sh`

Mirror the reference `meta_is_stale`/`refresh_meta`: slow-changing endpoints
(`system/info`, `disk`, `service`, `app`, ...) are cached in `meta.json` with
`fetchedAt` and refetched only after `notify.metaMaxAgeSeconds` (default 300).
`--force-meta` refetches regardless. Add a test that a fresh `meta.json`
suppresses the second request, that the alert request still happens, and that
`--force-meta` spends exactly one more.

**Commit:** `feat: cache slow endpoints and add --force-meta`.

---

## Task 7: truenasctl

**Files:**
- Create: `bin/truenasctl`
- Test: `tests/cases/14-ctl.sh`

Copy `signozctl`'s dispatch, verbs for this milestone:

```
truenasctl login <url> [--insecure]   read key on stdin; write config + creds (600)
truenasctl logout                     remove creds
truenasctl test [-v]                  step-by-step: DNS/TLS, cert, key, each endpoint
truenasctl status                     what the bar is showing, one screen
truenasctl alerts                     active alerts, one per line
truenasctl pools                      pools and capacity
truenasctl poll [--quiet]             poll now
truenasctl config list                JSON, never the key value
truenasctl config set <k> <v>
truenasctl config set-key             read key on stdin
truenasctl open [health|pools|alerts] xdg-open the NAS UI
truenasctl purge                      delete config, creds, state
```

`test` is the important one: it must distinguish "TLS refused" (self-signed and
`insecureTLS` off → say so and print the fix), "no key", "key rejected" (401),
"forbidden" (403), "not JSON", "timed out" — never collapse them into
"unreachable". When it sees a self-signed cert it prints:

```
the certificate is self-signed; set "insecureTLS": true in
~/.config/omarchy/truenas/config.json, or trust the TrueNAS CA on this machine
```

**Commit:** `feat: add truenasctl login, test, status and config`.

---

## Task 8: Model.js pure rules

**Files:**
- Modify: `Model.js`
- Test: `tests/model.mjs`

Adapt `signoz` Model.js: `arrayLike`, `severityRank`, `worstSeverity`, `ageText`,
`durationText`, `errorSentence`, `tooltipFor`, `glyphFor`, and add:
`poolStatusRank`, `worstPool`, `capacityPct`, `alertRows`, `byLevel`,
`notificationPause`, `formatBytes`. Keep `.pragma library` as line 1.

`tests/model.mjs` uses the reference node loader (strip `^.pragma|.import`).

Assertions:

```js
check("Array.isArray is false for a sequence-like", false, Array.isArray(seq));
check("arrayLike sees it", true, Model.arrayLike(seq));
check("no pools is not 0% used", null, Model.capacityPct({ pools: [] }));
check("a DEGRADED pool outranks ONLINE", "storage",
      Model.worstPool([online("boot"), degraded("storage")]).name);
```

**Commit:** `feat: add pure model rules for pools, alerts and errors`.

---

## Task 9: Links.js and Search.js

**Files:** `Links.js`, `Search.js`; tests `tests/links.mjs`, `tests/search.mjs`.

`Links.js` builds URLs into the **configured** base only, with the origin gate
from the reference (`safeUrl`: character after the base must be `/`, `?`, `#`).
Views: `open base + "/ui/alerts"`, `/ui/storage`, `/ui/system`, `/ui/apps`.
`Search.js` filters alerts/pools by substring. Assert the origin gate with
`https://nas.example.com.attacker.test/steal`.

**Commit:** `feat: add origin-checked links and list search`.

---

## Task 10: BarVariants.js

**Files:** `BarVariants.js`; test `tests/bar-variants.mjs`.

Segments per variant exactly as the manifest description promises. `resolveVariant`
takes the pinned setting; an empty or unknown setting resolves to the built-in
`Default` (the active alert count when anything is firing, otherwise the fullest
pool's capacity). `isMultiColour` for the tinted per-level row like the reference.

**Commit:** `feat: define bar variants`.

---

## Task 11: Service.qml

**Files:** `Service.qml`

Copy `~/Projects/omarchy-signoz/Service.qml` (67 lines) and change: paths
(`omarchy/truenas/config.json`, `bin/truenas-poll`), default `pollSeconds` 30,
floor **15**, `IpcHandler { target: "truenas" }` with `refresh()`/`poll()`.
One process, one timer, config watched with `FileView`.

**Verify:** `qmllint` by Qt 6 path on the file.

**Commit:** `feat: add the polling service`.

---

## Task 12: BarWidget.qml

**Files:** `BarWidget.qml`

Copy the reference `BarWidget.qml` and adapt: state path
`~/.local/state/omarchy/truenas/state.json`; segments from `BarVariants`;
`mode` from `Model` (unconfigured/offline/partial/degraded/firing/quiet);
glyph/tint; tooltip; `hideWhenHealthy`; the `Loader` + `injectPanel` contract
(`opened`, `popoutSwitchClosing`, `open/close/toggle/closeForPopoutSwitch/view`);
`IpcHandler { target: "io.github.h4ad.truenas" }`; middle-click refresh,
right-click opens the NAS UI. `Quickshell.execDetached` for links.

**Commit:** `feat: add the TrueNAS bar widget`.

---

## Task 13: Panel.qml shell, config view, write queue

**Files:** `Panel.qml`, `Views/Config.qml`, `Ui/SecretField.qml`,
`Ui/ConfirmAction.qml`, `Ui/Chip.qml`, `Ui/Card.qml`,
`Ui/ScrollIndicator.qml`, `Ui/VariantPicker.qml`, `Ui/HelpModal.qml`

Copy the reference `Panel.qml` skeleton: `KeyboardPanel` + `PanelKeyCatcher`,
`manageIpc: false`, the `apiQueue`/`pumpApi`/`finishApi` single-process queue,
`refreshAfterWrite`, `openUrl` via `execDetached`, tab header + gear. Adapt the
config view to the four settings and the credentials `SecretField` flow
(`config set-key` on stdin). `ConfirmAction` is declared **inside**
`PanelKeyCatcher`.

**Commit:** `feat: add the panel shell, config view and write queue`.

---

## Task 14: Views/Health.qml

Status line (unconfigured / no answer + reason / partial warnings), hostname +
version + uptime, pool capacity bars, alert counts by level, and the slow
sections once they exist. Follow the reference Home view's rule: an unknown
number is a sentence, never `0` or a loading dash.

**Commit:** `feat: add the health view`.

---

## Task 15: Views/Pools.qml

A `CapacityBar` per pool (`Ui/CapacityBar.qml`), status tinted, allocated/free,
scrub state and age, vdev error counts when non-zero. A pool with a failed scan
says so; a pool with no scrub data says "no scrub on record" rather than
inventing a date.

**Commit:** `feat: add the pools view`.

---

## Task 16: Views/Alerts.qml + dismiss/restore

Row per alert: level glyph, text, node, age; actions `dismiss` / `restore` when
`dismissable`; a link into the NAS UI via `Links.js`. Writes go through
`bin/truenas-api`:

```
truenas-api dismiss <uuid>
truenas-api restore <uuid>
```

Each answers one JSON object and the panel reads the state back rather than
trusting stdout. Destructive actions pass `ConfirmAction`.

Tests in `tests/cases/15-api.sh`: the verb builds the right POST body, a 400
answers `{error, message}`, and the credentials never appear in the stub's
method/payload logs.

**Commit:** `feat: add the alerts view with dismiss and restore`.

---

## Task 17: Menu.qml

Summon menu: toggle the popout, open each view, poll now, pause/resume
notifications, open the NAS UI, open config. Declaring `menu` changes where a
bare `omarchy-shell shell summon io.github.h4ad.truenas` goes, so the menu owns
it and the popout stays on left-click. Reuse the reference `Menu.qml`.

**Commit:** `feat: add the summon menu`.

---

## Task 18: QML structure and runtime tests

**Files:** `tests/cases/17-qml-structure.sh`, `tests/cases/18-qml-runtime.sh`.

From the pitfalls doc: fail on duplicate two-space-indented `function` names in
any `.qml`; assert `.pragma library` is line 1 of every shared `.js`; every
`MouseArea` that covers something has `hoverEnabled: true`; run two throwaway
components under `qml6` to prove a cached field written in one importer is read
in another.

**Commit:** `test: add qml structure and runtime checks`.

---

## Task 19: Docs and preview

**Files:** `README.md`, `docs/02-truenas-api.md`, `docs/03-features.md`,
`docs/01-omarchy-plugin-api.md` (copy from the reference), `docs/11-pitfalls.md`
(copy and add TrueNAS entries), `preview.png`.

**Commit:** `docs: write the README and API notes`.

---

## Task 20: Live verification and release

**Steps:**
1. Ask the operator for the API key through `truenasctl login` (stdin only).
2. `truenasctl test -v` against `https://nas.example:4433`: expect the
   self-signed cert to be reported and `insecureTLS` required.
3. `./scripts/dev-install --restart`; enable the widget; confirm the bar item,
   popout, and `truenasctl status` on the real data.
4. Trigger a real alert if safe (e.g. a one-shot `alert.emit`) and confirm the
   toast and the dismissal path.
5. `git status` must show no `.agent`, no credentials, no key.
6. Commit `chore: verified against a live TrueNAS 25.04 instance`.
7. Then, and only then, follow the `git-park` skill to publish to `hub`, and
   later the finished work to GitHub.

**Blocked on:** the operator creating an API key and piping it in.

---

## Later milestones (each gets its own plan when reached)

- **M2 Disks:** `/api/v2.0/disk`, `/disk/temperatures`, `/smart/test/results`;
  Disks view; temp/SMART notifications.
  *Superseded by `2026-09-13-truenas-milestone-2.md` (temperature only; SMART
  left the API after 24.10).*
- **M3 Apps + Services:** `/service`, `/app`; state, start/stop/restart writes
  and confirmations.
- **M4 Protection:** `/replication`, `/cloudsync`, `/pool/snapshottask`,
  `/pool/scrub`; states, last run, run-now writes.
- **M5 Shares + Network:** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
  `/network/interface`; counts, sessions, link state.
- **M6 Polish:** menu completeness, glossary, preview, marketplace submission.

## Definition of done for M1

- `./tests/run.sh` green.
- `omarchy plugin validate .` clean.
- `/usr/lib/qt6/bin/qmllint` clean.
- Against the real NAS: bar shows pool capacity and alert count; a simulated
  critical alert toasts once and resolves; the popout opens Health/Pools/Alerts/
  Config; dismiss works and the bar agrees after the forced re-poll.
- No secret in git, in `shell.json`, in `argv`, or in a log.
