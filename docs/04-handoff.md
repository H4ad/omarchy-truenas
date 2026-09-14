# TrueNAS plugin — handoff

Written 2026-09-13 at `master` `9f72f47`, for an agent with none of the session
history. Read this first, then `.agent/WORKLOG.md`, then
`docs/plans/2026-09-13-truenas-plugin-design.md`.

## tl;dr

Milestone 1 of `io.github.h4ad.truenas` is complete, verified against a live
TrueNAS 25.10.6, installed and enabled on the desk, and pushed to `hub`. Nothing
blocks milestone 2. This document says where everything is and how to continue.

- Repo: `~/Projects/omarchy-truenas` (hub-only; remote `hub` =
  `forge:h4ad/omarchy-truenas.git`). No GitHub remote yet.
- Git identity: `Vinícius Lourenço <contact@viniciusl.com.br>`.
- `.agent` → `~/agent-state/omarchy-truenas` (Syncthing; never commit).
- Tests: 538 assertions green (`./tests/run.sh`). `omarchy plugin validate` clean.
  `/usr/lib/qt6/bin/qmllint` Qt6: 0 errors.
- Reference plugin to copy patterns from: `~/Projects/omarchy-signoz`
  (architecture) and `docs/01-omarchy-plugin-api.md`, `docs/11-pitfalls.md`
  (both adapted into this repo).

## How to continue (the process that worked)

Each task: a fresh implementer subagent does it and commits, then a separate
reviewer checks spec compliance and quality. Independent tasks run in parallel
using **git worktrees**, so two agents never touch the same index or file:

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-<slug> -b agent/desk/m2-<slug> master
# dispatch the task against /tmp/opencode/tn-<slug>
git merge --no-ff agent/desk/m2-<slug> -m "Merge ..."
git worktree remove /tmp/opencode/tn-<slug> --force
```

Wave pattern that worked for M1: a few independent tasks in parallel, then the
reviewers in parallel, then merge. Keep reviewers read-only so they can run
concurrently. Always run `./tests/run.sh` before believing a task is done.

## What exists (milestone 1)

```
manifest.json          bar-widget + menu + service; variant/hideWhenHealthy/panelWidth/configPath
Service.qml            singleton poller owner (Timer + Process truenas-poll, IPC target "truenas")
BarWidget.qml          read-only watcher of state.json; variants; IPC io.github.h4ad.truenas; Loader(Panel)
Panel.qml              popout: Health/Pools/Alerts/Config, single write queue, ConfirmAction
Menu.qml               summon menu (views, poll now, open NAS UI, status)
Model.js               .pragma library: mode, worstPool, capacityPct, formatBytes, errorSentence, ...
BarVariants.js         Default/Icon/Alerts/Capacity/Pool/Full (+ offline override)
Links.js               origin-gated view URLs; Search.js list filtering
Views/                 Health, Pools, Alerts, Config
Ui/                    Card, Chip, CapacityBar, ConfirmAction, FilterField, HelpModal,
                       ScrollIndicator, SecretField, VariantPicker
bin/truenas-poll       read path -> state.json + notifications
bin/truenas-api        writes: dismiss <uuid>, restore <uuid>
bin/truenasctl         login/logout/test/status/alerts/pools/poll/config/open/purge
bin/truenas-lib.sh     config normalize, credential resolve, HTTP (key on curl stdin), classify
share/normalize.jq     API shapes -> stable state shape
scripts/dev-install    copy runtime files to the plugin dir; --restart restarts the shell
docs/01,02,03,11       plugin API, TrueNAS API notes, features, pitfalls
docs/plans/            the approved design and the milestone-1 implementation plan
tests/                 run.sh + cases/*.sh + *.mjs + stubs + fixtures
```

### Data flow

`Service.qml` runs `bin/truenas-poll` on a timer (30s, floor 15). The poller
writes `~/.local/state/omarchy/truenas/state.json` atomically and sends
notifications; `BarWidget.qml` only watches that file, so there is one poll per
machine, not one per monitor. Writes go from the panel's single process queue to
`bin/truenas-api`, then a forced re-poll. `system/info` is cached in `meta.json`
(default 300s, `--force-meta`), because TrueNAS rate-limits.

An unreachable or failed section is `null`/empty plus a `warnings` entry; it is
never rendered as `0`. That rule is load-bearing across the poller, Model,
views, Menu and `truenasctl`.

## Live environment (verified)

- NAS web/API: `https://nas.example:4433` (port 8080 only redirects).
- TrueNAS **25.10.6**. REST `/api/v2.0` is deprecated but live (returns 401
  without a key, not 404). Future migration seam is `tn_http_request`/`tn_dialect`.
- Self-signed cert (CN=localhost, iXsystems): `insecureTLS: true` is required.
- Two pools (`storage`, `Backup`), both ONLINE. Real data renders in the panel; see
  `preview.png`.
- The plugin is installed at `~/.config/omarchy/plugins/io.github.h4ad.truenas`
  and enabled in `shell.json`. Install/restart with `./scripts/dev-install --restart`.

## Secrets and paths

```
~/.config/omarchy/truenas/config.json     baseUrl, insecureTLS, pollSeconds, notify
~/.config/omarchy/truenas/credentials     TRUENAS_API_KEY=<key>, mode 600
~/.local/state/omarchy/truenas/           state.json, seen.json, meta.json
```

The key is read on stdin by `truenasctl login` and `config set-key`; it reaches
curl only through a `--config -` stdin document, never argv, the environment, a
log, `shell.json`, or the repo. Never commit it; never paste it into a chat.
`config list` reports `keySet`, never the value. If a key needs to be re-entered:
`bin/truenasctl login https://nas.example:4433 --insecure`.

## Testing

```bash
./tests/run.sh                       # all suites; no network, no desktop needed
bash -n bin/*.sh tests/*.sh          # after touching shell
jq empty tests/fixtures/*.json       # err-401.json is deliberately plain text
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml
omarchy plugin validate <clean-tree> # the dev repo's .agent symlink is rejected; validate a copy
./scripts/dev-install --restart      # install and restart the shell after QML edits
```

The harness sources `tests/cases/*.sh` into one shell; the stub `tests/stubs/curl`
emulates curl's config/header parsing and `tests/stubs/omarchy-notification-send`
emulates the sender's argv contract, so a broken invocation fails the suite. Keep
those stubs honest: a stub that accepts anything made a real notification bug
invisible once already.

## Decisions and traps

- Never turn "I cannot tell" into a number. `docs/11-pitfalls.md` has the rest,
  including: `.pragma library` on line 1 of every shared `.js`; `arrayLike`, not
  `Array.isArray`; a visual dialog must live inside `PanelKeyCatcher`; duplicate
  function names kill a whole QML file silently; `Process` is depth-one;
  `omarchy-notification-send` needs `--exec` **last** with separate argv words.
- Read the real binary's contract, not the reference's stub. Two bugs in M1 came
  from trusting the signoz reference.
- QML compiled components are cached per URL; `--restart` is the only reliable
  way to see a panel change.

## Known caveats / not verified

- Alert `dismiss`/`restore` is covered by `tests/cases/15-api.sh` but was **not**
  exercised against the NAS: the only active warning is a genuine
  "409 uncorrectable errors for sda", and hiding a real disk warning to test a
  button is the wrong trade. Try it on a disposable alert.
- On load the shell logs `TypeError: Cannot assign to read-only property
  "moduleName"` at `plugins/bar/Bar.qml:1770`. The widget, menu and popout all
  render; the signoz plugin shows the same shape, so it is probably host-side.
  Confirm before chasing it.
- `Search.js`, `Ui/FilterField.qml`, `Ui/Chip.qml` and `Ui/HelpModal.qml` are
  built and lint-clean but not yet wired into a view (search/glossary are the
  intended consumers).
- `qmllint` emits the repo's baseline unqualified-access warnings because
  `qs.Commons`/`qs.Ui` do not resolve outside the shell; 0 errors is the bar.

## Roadmap

M1 shipped. Each later milestone gets its own plan; the design doc lists them.

- **M2 Disks:** `/api/v2.0/disk`, `/disk/temperatures`, `/smart/test/results`;
  a Disks view; temp/SMART notifications. (Note: disk shapes and the SMART
  endpoints need verifying against the live API first — do not assume.)
- **M3 Apps + Services:** `/service`, `/app`; state and start/stop/restart with
  confirmations.
- **M4 Protection:** `/replication`, `/cloudsync`, `/pool/snapshottask`,
  `/pool/scrub`; states, last run, run-now.
- **M5 Shares + Network:** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
  `/network/interface`.
- **M6 Polish:** menu completeness, glossary, preview, marketplace submission.

## Finishing / publishing

This is a hub-only project, so `git push hub master` is how work is stored. If a
GitHub remote is added later, only clean finished commits go to `origin`; never a
`wip/*` or `agent/*` ref. Follow the `git-park` skill.
