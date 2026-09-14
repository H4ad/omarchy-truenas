# TrueNAS plugin - handoff

Written 2026-09-14 at `master` (milestone 6 merged), for an agent with none of
the session history. Read this first, then `.agent/WORKLOG.md`, then
`docs/plans/2026-09-13-truenas-plugin-design.md` and the milestone plans under
`docs/plans/`.

## tl;dr

All six milestones are complete, reviewed, merged, verified against a live
TrueNAS 25.10.6, installed and enabled on the desk. Milestone 6 was the release
milestone: the glossary is reachable from the panel `?` and the menu Help row,
the menu header shows the version, every data view satisfies the empty and error
state contract, the four uncalled Model helpers are gone, and the manifest ships
as version `1.0.0`. The design's v1 feature set is finished. Nothing
blocks publication except the manual steps below.

- Repo: `~/Projects/omarchy-truenas` (hub-only; remote `hub` =
  `forge:h4ad/omarchy-truenas.git`). No GitHub remote yet.
- Git identity: `Vinícius Lourenço <contact@viniciusl.com.br>`.
- `.agent` → `~/agent-state/omarchy-truenas` (Syncthing; never commit).
- Tests: 1623 assertions green (`./tests/run.sh`)
  (shell 1065, model 237, search 145, bar variants 149, links 27).
  `/usr/lib/qt6/bin/qmllint` Qt6 0 errors; `omarchy plugin validate` clean on
  the installed tree.
- Reference plugin to copy patterns from: `~/Projects/omarchy-signoz`
  (architecture) and `docs/01-omarchy-plugin-api.md`, `docs/11-pitfalls.md`
  (both adapted into this repo).
- Merged milestone branches still exist locally as `agent/desk/m1-*` … `m6-*`
  (audit); the worktrees were removed.

## How to continue (the process that worked)

Each task: a fresh implementer subagent does it and commits, then a separate
spec-compliance reviewer, then a code-quality reviewer; findings go back to the
implementer and the reviewer re-checks. Independent tasks run in parallel using
**git worktrees**, so two agents never touch the same index or file:

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m6-<slug> -b agent/desk/m6-<slug> master
# dispatch the task against /tmp/opencode/tn-m6-<slug>
git merge --no-ff agent/desk/m6-<slug> -m "Merge Task <N>: <title>"
git worktree remove /tmp/opencode/tn-m6-<slug> --force
```

Wave pattern that worked six times: pick tasks with disjoint file sets, run them
in parallel, review in parallel, merge in dependency order, run `./tests/run.sh`
after every merge, then one final whole-implementation review. Always run
`./tests/run.sh` before believing a task is done.

## What exists

```
manifest.json          bar-widget + menu + service; Default/Icon/Alerts/
                       Capacity/Pool/Temp/Full, hideWhenHealthy, panelWidth,
                       configPath; 1.0.0
Service.qml            singleton poller owner (Timer + Process truenas-poll, IPC target "truenas")
BarWidget.qml          read-only watcher of state.json; variants; IPC io.github.h4ad.truenas;
                       Loader(Panel); openHelp() -> panelLoader.item.showHelp() then open()
Panel.qml              popout: Health/Pools/Disks/Services/Apps/Shares/Protection/Alerts/Config,
                       single write queue, ConfirmAction inside PanelKeyCatcher,
                       HelpModal + showHelp/hideHelp/helpOpen + the header `?` button
Menu.qml               summon menu (views, poll now, open NAS UI, status, Help row,
                       dim version caption from manifest.version)
Model.js               .pragma library: mode, worstPool, capacityPct, formatBytes, errorSentence,
                       tempStateRank/tempLevel/hottestTempC/formatTemp, serviceStateRank/appStateRank,
                       downServices/downApps, unknownServices/unknownApps, appsUpgradeable, appLabel,
                       protectionStateRank/protectionState/replicationFailed/cloudSyncFailed/
                       failedReplications/failedCloudSync/protectionLabel/scheduleText,
                       linkStateRank/linkStateText/downInterfaces/unknownInterfaces/shareCounts
BarVariants.js         Default/Icon/Alerts/Capacity/Pool/Temp/Full (+ offline override), soleSeverity
Links.js               origin-gated view URLs; Search.js alerts/pools/disks/services/apps/replication/
                       cloudSync/snapshotTasks/scrubs/shares/interfaces filtering
Views/                 Health, Pools, Disks, Services, Apps, Shares, Protection, Alerts, Config
Ui/                    Card, Chip, CapacityBar, ConfirmAction, FilterField, HelpModal (ten sections),
                       ScrollIndicator, SecretField, VariantPicker
bin/truenas-poll       read path -> state.json + notifications (alerts, pools, disk temps,
                       service/app down, replication/cloud sync failure & recovery)
bin/truenas-api        writes: dismiss/restore <uuid>; service-start/stop/restart <name>;
                       app-start/stop/redeploy <name>; replication-run/cloudsync-sync/snapshot-run <id>;
                       scrub-start <pool>
bin/truenasctl         login/logout/test/status/alerts/pools/disks/services/apps/replication/cloudsync/
                       snapshots/scrubs/shares/network/poll/config/open/purge
bin/truenas-lib.sh     config normalize, credential resolve, HTTP (key on curl stdin), classify,
                       tn_error_message (flat + first keyed 422 message)
share/normalize.jq     API shapes -> stable state shape (system, counts, alerts, pools, disks,
                       services, apps, replication, cloudSync, snapshotTasks, scrubs, shares, network)
scripts/dev-install    copy runtime files to the plugin dir; --restart restarts the shell
scripts/screenshot     open the panel over IPC, capture a hand-picked region into preview.png
docs/01,02,03,11       plugin API, TrueNAS API (M1-M5 verified; M6 added no route), features, pitfalls
docs/plans/            the design and the M1-M6 plans
tests/                 run.sh + cases/*.sh + *.mjs + stubs + fixtures
```

### Data flow

`Service.qml` runs `bin/truenas-poll` on a timer (30s, floor 15). The poller
writes `~/.local/state/omarchy/truenas/state.json` atomically and sends
notifications; `BarWidget.qml` only watches that file, so there is one poll per
machine, not one per monitor. Fast cadence (every poll): `alert/list`, `pool`.
Meta cadence (`notify.metaMaxAgeSeconds`, default 300, `--force-meta` forces):
`system/info`, `disk/details`, `disk/temperatures`, `service`, `app`,
`sharing/smb`, `sharing/nfs`, `iscsi/target`, `interface`, `replication`,
`cloudsync`, `pool/snapshottask`, `pool/scrub`; the raw rows (filtered to the
consumed fields) are cached in `meta.json`, and every path re-runs the one
normalizer. Writes go from the panel's single process queue to `bin/truenas-api`,
then a forced re-poll.

An unreachable or failed section is `null`/empty plus a `warnings` entry; it is
never rendered as `0`. That rule is load-bearing across the poller, Model,
views, Menu and `truenasctl`. `tempState` (ok/warning/critical/unknown, warning
band critical-10) is computed once in `share/normalize.jq`. A service is down
when its state is not `RUNNING` and not blank; an app is down in
`STOPPED`/`CRASHED`/`FAILED`/`EXITED`; a replication or cloud sync task is
failed on a `FAILED`/`ERROR`/`ABORTED` job or a replication `state.warnings`; a
link is down only on a real down state, never on blank or `LINK_STATE_UNKNOWN`.
The watcher carries stable booleans in `seen.json` so a transitional poll cannot
replay or hide a change.

## Live environment (verified)

- NAS web/API: `https://nas.example:4433` (port 8080 only redirects).
- TrueNAS **25.10.6**. REST `/api/v2.0` is deprecated but live (401 without a
  key, not 404). Migration seam is `tn_http_request`/`tn_dialect`.
- Self-signed cert (CN=localhost, iXsystems): `insecureTLS: true` required.
- Pools: `storage` (ONLINE) and `Backup` (ONLINE). Five disks: `nvme0n1` (storage),
  `sda`+`sdb` (boot-pool, a mirror not listed by `/pool`), `sdc`+`sdd` (Backup).
  One `PHYSICAL` interface `enp4s0`, `LINK_STATE_UP`, `1000Mb/s Twisted Pair`.
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
- Protection endpoints (verified 2026-09-14): `GET /replication` (nested
  `state{state,datetime,warnings,last_snapshot}`, `job|null`, `schedule|null`),
  `GET /cloudsync` (empty on this box; last run is `job`, no task state),
  `GET /pool/snapshottask` (nested `state{state,datetime,last_snapshot}`),
  `GET /pool/scrub` (no run state; scrub progress lives on `pool.scan`). Run
  verbs: `POST /replication/run` takes a **bare integer id**; `POST
  /cloudsync/id/{id}/sync` and `POST /pool/snapshottask/id/{id}/run` take **no
  body**; `POST /pool/scrub/scrub {"name":pool,"action":"START"}` (the
  due-gated `/pool/scrub/run` is not used).
- Share and interface endpoints (verified 2026-09-14): `GET /sharing/smb` ->
  array (three shares: `default`, `backup`, `media`); `GET /sharing/nfs` ->
  array (one export, read-only flag is `ro`); `GET /iscsi/target` -> `[]` (real
  zero); `GET /interface` -> array, one `PHYSICAL` `enp4s0` with
  `link_state`/`media_type`/`active_media_subtype`/`aliases` under the nested
  `state`. There is **no** `/network/interface`, no `/sharing/webdav` and no
  `/smb/status` (all 404 `text/plain`).
- The plugin is installed at `~/.config/omarchy/plugins/io.github.h4ad.truenas`
  and enabled in `shell.json` (`variant: "Full"`). Install/restart with
  `./scripts/dev-install --restart`.

### Milestone 6 live verification (2026-09-14, after `./scripts/dev-install --restart`)

- `connection: ok`, dialect `rest-v2.0`, version `25.10.6`, uptime `17h 25m`,
  pools `2 (worst ONLINE)`, alerts `4 active (critical 0, error 0, warning 2,
  notice 0, info 2, dismissed 0)`.
- `./bin/truenasctl poll --quiet --force-meta` exits 0 and `state.json` holds all
  thirteen polled sections with zero `warnings`: alerts 4, pools 2, disks 5,
  services 8, apps 5, replication 1, cloudSync 0 (the real zero), snapshotTasks
  7, scrubs 2, smb 3, nfs 1, iscsi 0 (the real zero), network 1.
- `./bin/truenasctl test -v`: reachable yes, version 25.10.6, key set, curl rc 0
  http 200.
- The shell was restarted and the plugin reloaded; `qs log` shows no truenas QML
  errors, only the pre-existing host-side `moduleName` TypeError at
  `plugins/bar/Bar.qml:1770` and a Syncthing plugin warning, both unrelated.
- The IPC verbs `open` and `close` work.

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
those stubs honest. Current totals: shell 1065, model 237, search 145, bar
variants 149, links 27, for 1623 assertions.

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
- The meta cache keeps only the consumed wire fields per section, so disk serials,
  app notes/image ids, replication `ssh_credentials`/`encryption_key`, cloud sync
  secrets, SMB `audit`/`options`, NFS `hosts`/`networks`/`security`, iSCSI
  `groups`/`iscsi_parameters` and interface MACs never reach disk.
  `meta_is_stale` requires all thirteen sections; a missing key self-heals once.
- A service control 2xx body of `false` means the NAS accepted the request but
  the service did not change; `truenas-api` reports `action_failed` rather than
  success. This surfaced because `tn_classify` validated the body with `jq -e`,
  which treats a valid JSON `false` (and `null`) as invalid; it now uses `jq .`.
  An empty non-2xx body classifies as `http_<code>`.
- `tn_error_message` reads the flat `.error.message`/`.error.type`/`.message`,
  then the first keyed message under an array key (`{"data":[{"message",...}]}`
  or `{"null":[{"message",...}]}`), so a `422` model-validation body is not an
  empty sentence. A non-array value is guarded.
- App writes return a job id and run asynchronously, so a forced re-poll right
  after the write can still show the old state; the next poll catches up. The
  panel reads its write back rather than trusting the verb's stdout.
- Disk temperature toasts fire on a crossing into warning/critical and on
  cooling; the band start (critical-10) is defined in `normalize.jq` and
  re-derived in the toast body, so a band change needs both sites.
- Service/app and replication/cloud sync toasts dedupe through a stable boolean
  in `seen.json` (a `down`/`failed` flag), so a blank or transitional poll cannot
  replay or hide a change.
- `linkStateRank` treats an unrecognized link word as a real down state (rank 1),
  matching the frozen M5 contract. `linkStateText` still prints `unknown` for a
  word it does not know, so the chip and the section level can disagree for a
  future enum; revisit if the NAS grows a link state.
- The help sheet's content is data in `Ui/HelpModal.qml`, not a Model accessor:
  there is no node suite that could hold the words, and only the layout repeaters
  are code. Add a section by adding an array entry.
- The version caption reads `manifest.version` and renders only when it is
  non-empty, so a manifest with no version shows nothing rather than a blank.
- Read the real binary's contract, not the reference's stub. Bugs in M1-M6 came
  from trusting assumptions over a live probe.
- QML compiled components are cached per URL; `--restart` is the only reliable
  way to see a panel change.

## Known caveats / not verified

- **The iSCSI target row shape is synthetic.** The live box has zero iSCSI
  targets, so `tests/fixtures/iscsi-target.json` is built from the v25.10.5
  `iscsi.target.query` reference and `state.shares.iscsi` was verified live only
  as the empty real zero. First box with a target is the first real measurement.
- **Non-up link states and non-`PHYSICAL` interfaces are unverified.** Only
  `enp4s0` in `LINK_STATE_UP` and one `PHYSICAL` interface exist; the down and
  unknown spellings and the `BRIDGE`/`VLAN`/`LINK_AGGREGATION` shapes come from
  the enum/documentation.
- **`locked` was only ever seen `false`.** No locked dataset exists on the box.
- **The panel `?` and the help sheet were not clicked through by a human.** The
  sheet is wired, `qmllint` and `validate` are clean, and the shell reloaded with
  no truenas QML errors, but the click, the scroll and the Escape handling want a
  visual pass.
- **The menu Help row and the version caption were not visually confirmed.** The
  row and caption exist and the suite is green; a human has not opened the menu
  and read them.
- The app write verbs (`app-start/stop/redeploy`) are covered by
  `tests/cases/15-api.sh` but were not exercised against the NAS: redeploying a
  live app is disruptive. A service write was exercised live instead
  (`service-start snmp` flipped it to RUNNING, `service-start ups` reported
  `action_failed`). Exercise an app write on a disposable app next time.
- Alert `dismiss`/`restore` is still not exercised against the NAS: the active
  warnings are genuine (for example, uncorrectable errors for sda).
- The M4 run verbs were verified live only on their error path (an invalid id
  answers `422`); no real scrub, replication or cloud sync was started.
- On load the shell logs `TypeError: Cannot assign to read-only property
  "moduleName"` at `plugins/bar/Bar.qml:1770`; hosts and the signoz plugin show
  the same shape. Probably host-side; confirm before chasing.
- `preview.png` is still the milestone-1 screenshot; milestone 6 shipped
  `scripts/screenshot` but did not refresh the image (see the manual steps).
- `qmllint` emits the repo's baseline unqualified-access warnings because
  `qs.Commons`/`qs.Ui` do not resolve outside the shell; 0 errors is the bar.

## Remaining manual steps

These are human actions with the exact command; none blocks the merge.

1. **Create the public GitHub repository and push only finished `master`.**
   ```bash
   gh repo create h4ad/omarchy-truenas --public --source ~/Projects/omarchy-truenas --remote origin
   git -C ~/Projects/omarchy-truenas push origin master
   ```
   Push `master` only. Never push an `agent/*` or `wip/*` ref to `origin`.
   Pushing is never done by the agent without an explicit request.
2. **Refresh `preview.png`** (blocking for the marketplace submission, not for
   the merge). On the desk, with the plugin installed, a key set and the poll
   current:
   ```bash
   ./scripts/dev-install --restart
   omarchy-shell io.github.h4ad.truenas open
   ./scripts/screenshot preview.png   # drag over the bar item and the Health popout
   git add preview.png && git commit -S -m 'docs: refresh the preview screenshot'
   ```
   The panel is a layer-shell surface and the crop is a judgement, which is why
   the region is chosen by hand.
3. **Submit to the marketplace.** Open the submission form linked from
   `https://omarchyplugins.com/develop.html` and complete it with the repo URL,
   the `MIT` license and `preview.png`.
4. **A visual click-through** on a real session after `./scripts/dev-install
   --restart`: every tab, the help `?`, its scroll and Escape handling, the
   menu's Help row and version caption, and a filter that matches nothing on each
   list. No unit test runs QML, so this is the only check for the rendering
   itself.
5. **A live regression check** of the read path:
   ```bash
   bin/truenasctl test -v
   bin/truenasctl poll && bin/truenasctl status
   qs log -p "$OMARCHY_PATH/shell" --tail 100
   ```
   Confirm all thirteen meta sections still write and the log stays clean.

## Writing and git rules

- No emojis and no em dashes. Use a comma, a period or parentheses.
- No banned inflating or stock words; the working agreement carries the list.
  Sentence case in headings.
- Commit subjects are conventional (`docs:`, `feat:`, `fix:`, `chore:`, `test:`),
  subject line only, no body and no trailers.
- Never commit `.agent`: it is a Syncthing symlink, never tracked, and
  `git status` must never show it.
- Never `git stash`; use a wip commit.
- Hub-only: `git push hub master` stores the work. Only finished commits go to a
  GitHub `origin`, never a `wip/*` or `agent/*` ref. Follow the `git-park` skill.

## Finishing / publishing

This is a hub-only project, so `git push hub master` is how work is stored. If a
GitHub remote is added, only clean finished commits go to `origin`; never a
`wip/*` or `agent/*` ref. The GitHub repo, the `preview.png` refresh and the
marketplace form are the remaining manual gates above.
