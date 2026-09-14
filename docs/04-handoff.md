# TrueNAS plugin — handoff

Written 2026-09-14 at `master` `caaa590`, for an agent with none of the session
history. Read this first, then `.agent/WORKLOG.md`, then
`docs/plans/2026-09-13-truenas-plugin-design.md` and the milestone plans under
`docs/plans/`.

## tl;dr

Milestones 1 (system/pools/alerts), 2 (disks and temperatures) and 3 (services
and apps, with control writes) are complete, reviewed, merged, verified against
a live TrueNAS 25.10.6, installed and enabled on the desk, and pushed to `hub`.
Version is `0.3.0`. Nothing blocks milestone 4 (protection).

- Repo: `~/Projects/omarchy-truenas` (hub-only; remote `hub` =
  `forge:h4ad/omarchy-truenas.git`). No GitHub remote yet.
- Git identity: `Vinícius Lourenço <contact@viniciusl.com.br>`.
- `.agent` → `~/agent-state/omarchy-truenas` (Syncthing; never commit).
- Tests: 1164 assertions green (`./tests/run.sh`)
  (shell 750, model 175, search 63, bar variants 149, links 27).
  `omarchy plugin validate` clean on a tree without `.agent`;
  `/usr/lib/qt6/bin/qmllint` Qt6 0 errors.
- Reference plugin to copy patterns from: `~/Projects/omarchy-signoz`
  (architecture) and `docs/01-omarchy-plugin-api.md`, `docs/11-pitfalls.md`
  (both adapted into this repo).
- Merged milestone branches still exist locally as `agent/desk/m1-*`, `m2-*`,
  `m3-*` (audit); the worktrees were removed.

## How to continue (the process that worked)

Each task: a fresh implementer subagent does it and commits, then a separate
spec-compliance reviewer, then a code-quality reviewer; findings go back to the
implementer and the reviewer re-checks. Independent tasks run in parallel using
**git worktrees**, so two agents never touch the same index or file:

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-<slug> -b agent/desk/m4-<slug> master
# dispatch the task against /tmp/opencode/tn-<slug>
git merge --no-ff agent/desk/m4-<slug> -m "Merge Task <N>: <title>"
git worktree remove /tmp/opencode/tn-<slug> --force
```

Wave pattern that worked three times: pick tasks with disjoint file sets, run
them in parallel, review in parallel, merge in dependency order, run
`./tests/run.sh` after every merge, then one final whole-implementation review.
Always run `./tests/run.sh` before believing a task is done.

## What exists

```
manifest.json          bar-widget + menu + service; variants Default/Icon/Alerts/
                       Capacity/Pool/Temp/Full, hideWhenHealthy, panelWidth, configPath; 0.3.0
Service.qml            singleton poller owner (Timer + Process truenas-poll, IPC target "truenas")
BarWidget.qml          read-only watcher of state.json; variants; IPC io.github.h4ad.truenas; Loader(Panel)
Panel.qml              popout: Health/Pools/Disks/Services/Apps/Alerts/Config, single write queue, ConfirmAction
Menu.qml               summon menu (views, poll now, open NAS UI, status)
Model.js               .pragma library: mode, worstPool, capacityPct, formatBytes, errorSentence,
                       tempStateRank/tempLevel/hottestTempC/formatTemp, serviceStateRank/appStateRank,
                       worstServiceLevel/worstAppLevel, downServices/downApps, unknownServices/unknownApps,
                       appsUpgradeable, appLabel
BarVariants.js         Default/Icon/Alerts/Capacity/Pool/Temp/Full (+ offline override), soleSeverity
Links.js               origin-gated view URLs; Search.js alerts/pools/disks/services/apps filtering
Views/                 Health, Pools, Disks, Services, Apps, Alerts, Config
Ui/                    Card, Chip, CapacityBar, ConfirmAction, FilterField, HelpModal,
                       ScrollIndicator, SecretField, VariantPicker
bin/truenas-poll       read path -> state.json + notifications (alerts, pools, disk temps, service/app down)
bin/truenas-api        writes: dismiss/restore <uuid>; service-start/stop/restart <name>;
                       app-start/stop/redeploy <name>
bin/truenasctl         login/logout/test/status/alerts/pools/disks/services/apps/poll/config/open/purge
bin/truenas-lib.sh     config normalize, credential resolve, HTTP (key on curl stdin), classify
share/normalize.jq     API shapes -> stable state shape (system, counts, alerts, pools, disks, services, apps)
scripts/dev-install    copy runtime files to the plugin dir; --restart restarts the shell
docs/01,02,03,11       plugin API, TrueNAS API (M1-M3 verified), features, pitfalls
docs/plans/            the design, the M1, M2 and M3 plans
tests/                 run.sh + cases/*.sh + *.mjs + stubs + fixtures
```

### Data flow

`Service.qml` runs `bin/truenas-poll` on a timer (30s, floor 15). The poller
writes `~/.local/state/omarchy/truenas/state.json` atomically and sends
notifications; `BarWidget.qml` only watches that file, so there is one poll per
machine, not one per monitor. Fast cadence (every poll): `alert/list`, `pool`.
Meta cadence (`notify.metaMaxAgeSeconds`, default 300, `--force-meta` forces):
`system/info`, `disk/details`, `disk/temperatures`, `service`, `app`; the raw
rows (filtered to the consumed fields) and the temperatures map are cached in
`meta.json`, and every path re-runs the one normalizer. Writes go from the
panel's single process queue to `bin/truenas-api`, then a forced re-poll.

An unreachable or failed section is `null`/empty plus a `warnings` entry; it is
never rendered as `0`. That rule is load-bearing across the poller, Model,
views, Menu and `truenasctl`. `tempState` (ok/warning/critical/unknown, warning
band critical-10) is computed once in `share/normalize.jq`. A service is down
when its state is not `RUNNING` and not blank; an app is down in
`STOPPED`/`CRASHED`/`FAILED`/`EXITED`; the watcher carries a stable `down`
boolean in `seen.json` so a transitional poll cannot replay or hide a change.

## Live environment (verified)

- NAS web/API: `https://nas.example:4433` (port 8080 only redirects).
- TrueNAS **25.10.6**. REST `/api/v2.0` is deprecated but live (401 without a
  key, not 404). Migration seam is `tn_http_request`/`tn_dialect`.
- Self-signed cert (CN=localhost, iXsystems): `insecureTLS: true` required.
- Pools: `storage` (ONLINE) and `Backup` (ONLINE). Five disks: `nvme0n1` (storage),
  `sda`+`sdb` (boot-pool, a mirror not listed by `/pool`), `sdc`+`sdd` (Backup).
- **SMART is not in this API.** `GET /api/v2.0/smart/test/results` is 404 and the
  25.04/25.10 references list no `smart.*` methods (removed after 24.10).
  Temperature is the disk signal this plugin uses.
- Disk endpoints (verified): `POST /api/v2.0/disk/details {"type":"USED"}` ->
  array with `imported_zpool`; `POST /api/v2.0/disk/temperatures
  {"name":[...],"include_thresholds":true}` -> `{name:[tempC,criticalC]}` (bare
  number when a disk reports none). GET on temperatures is 405; `{"type":"BOTH"}`
  answers `{used,unused}`.
- Service and app endpoints (verified): `GET /api/v2.0/service` -> array
  `{id, service, enable, state, pids}`; `GET /api/v2.0/app` -> array with
  `name, state, custom_app, upgrade_available, human_version, version, migrated,
  metadata{title, app_version, train, home, icon}, portals, active_workloads
  {containers}` and a `notes` string that can be tens of KB (never cached).
  `POST /api/v2.0/service/{start,stop,restart} {"service":name}` answers a
  boolean; `POST /api/v2.0/app/{start,stop,redeploy} {"app_name":name}` answers
  an async job id. There is no `app/restart` (404): redeploy is the restart
  verb. An unknown name is 404 `{"message":"<name>"}`; a missing attribute is
  400 `{"message":"<attr> attribute expected."}`.
- The plugin is installed at `~/.config/omarchy/plugins/io.github.h4ad.truenas`
  and enabled in `shell.json` (`variant: "Full"`). Install/restart with
  `./scripts/dev-install --restart`.

## Secrets and paths

```
~/.config/omarchy/truenas/config.json     baseUrl, insecureTLS, pollSeconds, notify
~/.config/omarchy/truenas/credentials     TRUENAS_API_KEY=<key>, mode 600
~/.local/state/omarchy/truenas/           state.json, seen.json, meta.json
```

The key is read on stdin by `truenasctl login` and `config set-key`; it reaches
curl only through a `--config -` stdin document, never argv, the environment, a
log, `shell.json`, or the repo. Never commit it; never paste it into a chat.
`config list` reports `keySet`, never the value. If a key needs re-entering:
`bin/truenasctl login https://nas.example:4433 --insecure`.

## Testing

```bash
./tests/run.sh                       # all suites; no network, no desktop needed
bash -n bin/*.sh tests/*.sh tests/cases/*.sh
for f in tests/fixtures/*.json; do [[ $f == *err-401* ]] || jq empty "$f"; done
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml
omarchy plugin validate <clean-tree> # the dev repo's .agent symlink is rejected; validate a copy
./scripts/dev-install --restart      # install and restart the shell after QML edits
```

The harness sources `tests/cases/*.sh` into one shell; the stub `tests/stubs/curl`
emulates curl's config/header parsing and `tests/stubs/omarchy-notification-send`
emulates the sender's argv contract, so a broken invocation fails the suite. Keep
those stubs honest.

## Decisions and traps

- Never turn "I cannot tell" into a number. `docs/11-pitfalls.md` has the rest,
  including: `.pragma library` on line 1 of every shared `.js`; `arrayLike`, not
  `Array.isArray`; a visual dialog must live inside `PanelKeyCatcher`; duplicate
  function names kill a whole QML file silently; `Process` is depth-one;
  `omarchy-notification-send` needs `--exec` **last** with separate argv words.
- `disk/temperatures` takes `name` (singular, array), is POST-only, and answers
  `[value, critical]` only when `include_thresholds` is true.
- Disk to pool mapping comes from `imported_zpool` on `disk/details`; the plain
  `/disk` route has `"pool":null` on every row.
- The meta cache keeps disk rows filtered to `name, model, type, size,
  imported_zpool, bus` and app rows filtered to the consumed fields, so serials,
  notes and image identifiers never reach disk. `meta_is_stale` requires all
  five sections; a missing key self-heals once.
- A service control 2xx body of `false` means the NAS accepted the request but
  the service did not change; `truenas-api` reports `action_failed` rather than
  success. This surfaced because `tn_classify` validated the body with `jq -e`,
  which treats a valid JSON `false` (and `null`) as invalid; it now uses `jq .`.
  An empty non-2xx body classifies as `http_<code>`.
- App writes return a job id and run asynchronously, so a forced re-poll right
  after the write can still show the old state; the next poll catches up. The
  panel reads its write back rather than trusting the verb's stdout.
- Disk temperature toasts fire on a crossing into warning/critical and on
  cooling; the band start (critical-10) is defined in `normalize.jq` and
  re-derived in the toast body, so a band change needs both sites.
- Service and app down toasts dedupe through a stable `down` boolean in
  `seen.json`, so a blank or transitional poll cannot replay or hide a change.
- Read the real binary's contract, not the reference's stub. Bugs in M1, M2 and
  M3 came from trusting assumptions over a live probe.
- QML compiled components are cached per URL; `--restart` is the only reliable
  way to see a panel change.

## Known caveats / not verified

- The app write verbs (`app-start/stop/redeploy`) are covered by
  `tests/cases/15-api.sh` but were not exercised against the NAS: redeploying a
  live app is disruptive. A service write was exercised live instead
  (`service-start snmp` flipped it to RUNNING, `service-start ups` reported
  `action_failed`). Exercise an app write on a disposable app next time.
- Alert `dismiss`/`restore` is still not exercised against the NAS: the only
  active warning is a genuine "uncorrectable errors for sda".
- On load the shell logs `TypeError: Cannot assign to read-only property
  "moduleName"` at `plugins/bar/Bar.qml:1770`; hosts and the signoz plugin show
  the same shape. Probably host-side; confirm before chasing.
- `preview.png` is still the milestone-1 screenshot; M6 refreshes it.
- `Model.worstServiceLevel`/`worstAppLevel`/`appsUpgradeable` are tested but have
  no production caller yet; the Menu counts down and unknown rows directly.
- `qmllint` emits the repo's baseline unqualified-access warnings because
  `qs.Commons`/`qs.Ui` do not resolve outside the shell; 0 errors is the bar.

## Roadmap

M1, M2 and M3 shipped. Each later milestone gets its own plan; the design doc
lists them.

- **M4 Protection:** `/replication`, `/cloudsync`, `/pool/snapshottask`,
  `/pool/scrub`; states, last run, run-now. **Verify the endpoint shapes against
  the live API first.**
- **M5 Shares + Network:** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
  `/network/interface`.
- **M6 Polish:** menu completeness, glossary, preview, marketplace submission.

## Finishing / publishing

This is a hub-only project, so `git push hub master` is how work is stored. If a
GitHub remote is added later, only clean finished commits go to `origin`; never a
`wip/*` or `agent/*` ref. Follow the `git-park` skill.
