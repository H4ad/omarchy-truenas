# TrueNAS plugin — handoff

Written 2026-09-13 at `master` `933462c`, for an agent with none of the session
history. Read this first, then `.agent/WORKLOG.md`, then
`docs/plans/2026-09-13-truenas-plugin-design.md` and
`docs/plans/2026-09-13-truenas-milestone-2.md`.

## tl;dr

Milestones 1 (system/pools/alerts) and 2 (disks and temperatures) are complete,
reviewed, merged, verified against a live TrueNAS 25.10.6, installed and enabled
on the desk, and pushed to `hub`. Nothing blocks milestone 3. This document says
where everything is and how to continue.

- Repo: `~/Projects/omarchy-truenas` (hub-only; remote `hub` =
  `forge:h4ad/omarchy-truenas.git`). No GitHub remote yet.
- Git identity: `Vinícius Lourenço <contact@viniciusl.com.br>`.
- `.agent` → `~/agent-state/omarchy-truenas` (Syncthing; never commit).
- Tests: 771 assertions green (`./tests/run.sh`). `omarchy plugin validate`
  clean on a tree without `.agent`; `/usr/lib/qt6/bin/qmllint` Qt6 0 errors.
- Reference plugin to copy patterns from: `~/Projects/omarchy-signoz`
  (architecture) and `docs/01-omarchy-plugin-api.md`, `docs/11-pitfalls.md`
  (both adapted into this repo).
- Merged M2 branches still exist locally as `agent/desk/m2-*` (audit); the
  worktrees were removed.

## How to continue (the process that worked)

Each task: a fresh implementer subagent does it and commits, then a separate
spec-compliance reviewer, then a code-quality reviewer; findings go back to the
implementer and the reviewer re-checks. Independent tasks run in parallel using
**git worktrees**, so two agents never touch the same index or file:

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-<slug> -b agent/desk/m3-<slug> master
# dispatch the task against /tmp/opencode/tn-<slug>
git merge --no-ff agent/desk/m3-<slug> -m "Merge Task <N>: <title>"
git worktree remove /tmp/opencode/tn-<slug> --force
```

Wave pattern that worked twice: pick tasks with disjoint file sets, run them in
parallel, review in parallel, merge in dependency order, run `./tests/run.sh`
after every merge, then one final whole-implementation review. Always run
`./tests/run.sh` before believing a task is done.

## What exists

```
manifest.json          bar-widget + menu + service; variants Default/Icon/Alerts/
                       Capacity/Pool/Temp/Full, hideWhenHealthy, panelWidth, configPath; 0.2.0
Service.qml            singleton poller owner (Timer + Process truenas-poll, IPC target "truenas")
BarWidget.qml          read-only watcher of state.json; variants; IPC io.github.h4ad.truenas; Loader(Panel)
Panel.qml              popout: Health/Pools/Disks/Alerts/Config, single write queue, ConfirmAction
Menu.qml               summon menu (views, poll now, open NAS UI, status)
Model.js               .pragma library: mode, worstPool, capacityPct, formatBytes, errorSentence,
                       tempStateRank, tempLevel, hottestTempC, hotTempLabel, formatTemp, tempThresholdText
BarVariants.js         Default/Icon/Alerts/Capacity/Pool/Temp/Full (+ offline override), soleSeverity
Links.js               origin-gated view URLs; Search.js alerts/pools/disks filtering
Views/                 Health, Pools, Disks, Alerts, Config
Ui/                    Card, Chip, CapacityBar, ConfirmAction, FilterField, HelpModal,
                       ScrollIndicator, SecretField, VariantPicker
bin/truenas-poll       read path -> state.json + notifications (alerts, pools, disk temps)
bin/truenas-api        writes: dismiss <uuid>, restore <uuid>
bin/truenasctl         login/logout/test/status/alerts/pools/disks/poll/config/open/purge
bin/truenas-lib.sh     config normalize, credential resolve, HTTP (key on curl stdin), classify
share/normalize.jq     API shapes -> stable state shape (system, counts, alerts, pools, disks)
scripts/dev-install    copy runtime files to the plugin dir; --restart restarts the shell
docs/01,02,03,11       plugin API, TrueNAS API (M1+M2 verified), features, pitfalls
docs/plans/            the design, the M1 plan, the M2 plan
tests/                 run.sh + cases/*.sh + *.mjs + stubs + fixtures
```

### Data flow

`Service.qml` runs `bin/truenas-poll` on a timer (30s, floor 15). The poller
writes `~/.local/state/omarchy/truenas/state.json` atomically and sends
notifications; `BarWidget.qml` only watches that file, so there is one poll per
machine, not one per monitor. Fast cadence (every poll): `alert/list`, `pool`.
Meta cadence (`notify.metaMaxAgeSeconds`, default 300, `--force-meta` forces):
`system/info`, `disk/details`, `disk/temperatures`; the raw disk rows (filtered
to the consumed fields) and the temperatures map are cached in `meta.json`, and
every path re-runs the one normalizer. Writes go from the panel's single process
queue to `bin/truenas-api`, then a forced re-poll.

An unreachable or failed section is `null`/empty plus a `warnings` entry; it is
never rendered as `0`. That rule is load-bearing across the poller, Model,
views, Menu and `truenasctl`. `tempState` (ok/warning/critical/unknown, warning
band critical-10) is computed once in `share/normalize.jq`.

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
  `/disk` route has `"pool":null` on every row. `boot-pool` appears for boot
  disks but is not a `/pool` row.
- The meta cache keeps disk rows filtered to `name, model, type, size,
  imported_zpool, bus` so serials/identifiers never reach disk. Temperatures are
  cached as-is.
- Disk temperature toasts fire on a crossing into warning/critical and on
  cooling; the band start (critical-10) is defined in `normalize.jq` and
  re-derived in the toast body, so a band change needs both sites.
- The bar's single-tint path honors one non-empty segment severity through
  `BarVariants.soleSeverity`; without it a hot disk (no alerts) would not tint.
- Read the real binary's contract, not the reference's stub. Bugs in M1 and M2
  came from trusting assumptions over a live probe.
- QML compiled components are cached per URL; `--restart` is the only reliable
  way to see a panel change.

## Known caveats / not verified

- Alert `dismiss`/`restore` is covered by `tests/cases/15-api.sh` but was still
  not exercised against the NAS: the only active warning is a genuine
  "uncorrectable errors for sda". Try it on a disposable alert.
- On load the shell logs `TypeError: Cannot assign to read-only property
  "moduleName"` at `plugins/bar/Bar.qml:1770`; hosts and the signoz plugin show
  the same shape. Probably host-side; confirm before chasing.
- A normalize-only failure still reads "no disks reported" in the Disks view and
  Menu (Pools has had the same shape since M1); the warnings-based sentences
  cover disk/diskTemp failures.
- `preview.png` is still the milestone-1 screenshot; M6 refreshes it.
- `qmllint` emits the repo's baseline unqualified-access warnings because
  `qs.Commons`/`qs.Ui` do not resolve outside the shell; 0 errors is the bar.

## Roadmap

M1 and M2 shipped. Each later milestone gets its own plan; the design doc lists
them.

- **M3 Apps + Services:** `/service`, `/app`; state and start/stop/restart with
  confirmations. **Verify the endpoint shapes against the live API first**; do
  not assume, and remember SMART: the design's endpoint list was wrong once.
- **M4 Protection:** `/replication`, `/cloudsync`, `/pool/snapshottask`,
  `/pool/scrub`; states, last run, run-now.
- **M5 Shares + Network:** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
  `/network/interface`.
- **M6 Polish:** menu completeness, glossary, preview, marketplace submission.

## Finishing / publishing

This is a hub-only project, so `git push hub master` is how work is stored. If a
GitHub remote is added later, only clean finished commits go to `origin`; never a
`wip/*` or `agent/*` ref. Follow the `git-park` skill.
