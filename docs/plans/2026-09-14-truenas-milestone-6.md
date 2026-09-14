# TrueNAS plugin milestone 6 implementation plan

> **For the executor:** work this plan task-by-task. Independent tasks run in
> git worktrees, one branch each, with a fresh implementer per task and a
> separate spec + quality reviewer after. Steps are bite-sized; do not skip the
> "run it and watch it fail" step. See **Execution** at the bottom for the wave
> layout.

**Goal:** Milestone 6, polish and marketplace readiness: make the glossary that
already exists in `Ui/HelpModal.qml` reachable, close the empty and error state
gaps that are left, complete the menu, bring the manifest and README up to a
first marketplace release, remove the helpers nobody calls, and bump the
version.

**Architecture:** no read or write path changes. `bin/truenas-poll`,
`bin/truenas-api`, `bin/truenasctl`, `bin/truenas-lib.sh`, `share/normalize.jq`
and `Service.qml` are not touched. The work is four QML surfaces (the help
sheet, its panel wiring, the views, the menu), one Model cleanup, and the
packaging around the plugin (manifest, README, preview, docs).

**Tech stack:** QML/Quickshell, bash, node for unit tests; the same test harness
as M1 to M5.

**Design doc:** `docs/plans/2026-09-13-truenas-plugin-design.md` (the M6 line is
"Menu, help/glossary, README, preview image, release").
**Handoff:** `docs/04-handoff.md` (the current caveats and the hub-only rule).
**Pitfalls:** `docs/11-pitfalls.md` (read the QML, `.pragma`, duplicate-function
and dialog-placement sections before touching code).

---

## Conventions

- Every task commits with a Conventional Commit (`feat:`, `fix:`, `test:`,
  `docs:`, `chore:`). Never `git stash`; never force-push; never trailers or
  commit bodies (subject line only).
- `bash -n <file>` on every shell file touched.
  `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml`
  on QML changes. Bare `qmllint` is Qt 5 and lies.
- Tests run with no network and no desktop: `./tests/run.sh`.
- The API key is never committed, never in argv, never logged.
- Never turn "I cannot tell" into a number, a `0` or a `0%`. A failed section is
  an empty list plus a `warnings` entry, and the UI prints a sentence.
- A visual dialog lives inside `PanelKeyCatcher`, never at `Panel.qml`'s root
  scope, because `BarWidget.qml` loads that root into a hidden `Loader` and the
  visible panel is a separate layer-shell window.
- `.agent` is a symlink into a Syncthing folder. It is never committed and never
  force-added. `git status` must never show it.

## What milestone 6 starts from

The audit behind this plan, measured on `master` at `773b323`:

| Surface | State |
| --- | --- |
| `Ui/HelpModal.qml` | Correct and complete as a component, and dead: nothing instantiates it. No `?` exists anywhere in the tree. Its sections cover CONNECTION, POOLS, ALERTS and SECRETS only. |
| `Panel.qml` | Nine tabs (health, pools, disks, services, apps, shares, protection, alerts, config), a `?`-less header, one `ConfirmAction` inside the key catcher. No help sheet. |
| `BarWidget.qml` | Read-only watcher; IPC verbs `open`/`close`/`show`/`hide`/`toggle`/`refresh`/`view`. No `openHelp`. |
| `Menu.qml` | All nine views, Poll now and Open the NAS UI are present. No Help row. The header prints the glyph and the word TrueNAS, not the version. |
| Views | Pools, Disks, Services and Apps use `emptyText`; Health and Alerts use `statusLine` and `warningLine`; Protection and Shares use `emptyFor` and `warningLineFor`. Each handles no-state, offline, its own failed section, an empty route answer and a filter that matched nothing. Two gaps: Apps has no updates summary, and the Shares Network block names down links but not unknown ones. |
| `Model.js` | `worstServiceLevel`, `worstAppLevel`, `worstLinkLevel` and `worstProtectionLevel` have node tests and no caller. `appsUpgradeable` and `unknownInterfaces` have node tests and no caller either. |
| `manifest.json` | Version `0.5.0`. Both `description` fields omit shares and network. `homepage` is `https://github.com/h4ad/omarchy-truenas`, a repo that does not exist yet (hub-only project). |
| `README.md` | Describes milestone 1 only and ends with a "Planned: milestone 6" paragraph. |
| `preview.png` | The milestone 1 screenshot. |
| `scripts/` | `dev-install` only. No screenshot helper. |

The correctness rules are already enforced by 1649 green assertions, `qmllint`
at zero errors and `omarchy plugin validate` clean on the installed tree. M6 adds
no rule and removes none.

## Scope of polish

In scope:

- A help sheet reachable from the panel header `?` and from the menu, with one
  section per shipped view plus a troubleshooting section.
- An empty and error state pass over all nine views against one written
  contract, fixing the two real gaps and any others the pass finds.
- Menu completeness: a Help row and the installed version.
- Marketplace readiness: `manifest.json` fields, the `MIT` license (already
  present as `LICENSE`), the `preview.png` screenshot, and the repo URL decision.
- `README.md` rewritten for the shipped feature set.
- Version bump, decision below.
- Dead-code cleanup: the four Model helpers with no caller.

Out of scope, and deliberately so:

- Any read path, write path, notification or normalization change.
- A new bar variant. The seven variants stand; `worstLinkLevel`,
  `worstServiceLevel`, `worstAppLevel` and `worstProtectionLevel` were written as
  candidates for a variant that never shipped, which is why they are removed
  rather than wired.
- A share enable toggle, a Network deep link in `Links.js`, or the `/smb` global
  header. Those are separate features, not polish.
- Creating the public GitHub repository or pushing to it. See the manual steps.

## Decisions

### Version: `0.5.0` to `1.0.0`

M6 is the release milestone. The design's v1 feature set is complete: all nine
sections ship, all writes are guarded, all notifications dedupe, the CLI covers
every section, and the suite is green. The marketplace wants a version a reader
can trust to mean "finished", and `1.0.0` is that statement.

The counterargument is the REST removal in TrueNAS 26 and the shapes that were
never measured live (`docs/04-handoff.md` lists them). It does not outweigh the
release: `tn_call`/`tn_http_request` is the documented migration seam, the
plugin targets 25.10 today, and the caveats live in `docs/04-handoff.md` for the
next reader. Stay on 0.x only if a 1.0 must mean "verified against every path on
every version", which no NAS plugin can honestly claim.

### Repo URL

The id `io.github.h4ad.truenas` already commits to `github.com/h4ad`. Keep
`homepage` as `https://github.com/h4ad/omarchy-truenas`, document
`omarchy plugin add https://github.com/h4ad/omarchy-truenas.git --enable` as the
install path, and list "create that repository and push only finished `master`"
as a manual step. Do not point `homepage` at the private hub: the marketplace
installs from a public git repo, and a hub URL would be useless to a reader.

### Preview image

`preview.png` is regenerated only from a real desktop session against a real
NAS, because the panel is a layer-shell surface and the frame that best shows
the plugin is a judgement call. M6 ships a small `scripts/screenshot` that opens
the panel over IPC and captures a human-selected region with `slurp` and `grim`,
and lists running it as a manual step. The agent does not fabricate a
screenshot and does not commit a placeholder. The marketplace submission is
blocked on the human run; the merge is not.

### Dead helpers

Remove `worstServiceLevel`, `worstAppLevel`, `worstLinkLevel` and
`worstProtectionLevel` with their tests. Each duplicates a fact the Menu or a
view already computes directly (`downServices`/`unknownServices`,
`downApps`/`unknownApps`, `downInterfaces`/`unknownInterfaces`,
`failedReplications`/`failedCloudSync`), and a second accessor with no slot is a
maintenance tax. Keep `appsUpgradeable` and `unknownInterfaces`: M6 gives each a
real home (the Apps header and the Shares Network block).

### Where the glossary content lives

It stays as data in `Ui/HelpModal.qml`, as it is today. The file already
separates `sections` (content) from the repeaters (layout), and there is no node
suite that could hold the words. Moving them to `Model.js` would drag QML
presentation strings into the library script for no gain.

## View state contract

Every view that reads polled data must answer all seven cases with a sentence,
never a fabricated zero. This is the checklist Task B walks. Views/Health,
Pools, Disks, Services, Apps, Shares, Protection and Alerts are in scope;
Views/Config is exempt because it reads no polled list.

| Case | The sentence must be |
| --- | --- |
| No state file | "No state yet. The service writes it after the first poll." |
| Not configured | "not configured yet · run truenasctl login <url>" |
| NAS did not answer | the `Model.errorSentence(connection)` reason, prefixed by "No answer from the NAS:" |
| The view's own section failed | the section's warning reason, and no count |
| The route answered with no rows | a phrase ("no pools", "nothing firing"), never `0` |
| A filter matched nothing | "no <noun> match the filter" |
| Some sections answered, others warned | the healthy rows render and the failed section prints its reason |

A view that cannot distinguish two of these is the bug this contract exists to
catch. Task B records the pass in the commit body of its review note, not in
code.

## Frozen contracts (all tasks code against these)

### Help sheet content

`Ui/HelpModal.qml`'s `sections` array keeps its current shape:

```jsonc
[ { "title": "DISKS", "note": "…",
    "terms": [ { "term": "tempState", "text": "…" } ] } ]
```

The array gains one section per shipped surface, in panel tab order, plus a
closing troubleshooting section: CONNECTION, POOLS, DISKS, SERVICES, APPS,
PROTECTION, SHARES AND NETWORK, ALERTS, SECRETS, WHEN SOMETHING FAILS. The
repeaters in the file are unchanged; only the data grows. Every sentence stays
in the plugin's voice: what the word means and what the user can do about it.

### Panel and bar widget help interface

- `Panel.qml` declares `Local.HelpModal { id: helpModal; … }` inside
  `PanelKeyCatcher`, with `anchors.fill: parent`, `z: 9`, the panel's
  `contentForeground`/`contentFontFamily`, and `onClosed: helpModal.opened =
  false`.
- `Panel.qml` gains `function showHelp()` (sets `helpModal.opened = true`),
  `function hideHelp()`, and `readonly property bool helpOpen:
  helpModal.opened`.
- The key catcher routing: `onCloseRequested` closes the help sheet first when
  `helpOpen`, otherwise the panel. `onMoveRequested` forwards `dy` to
  `helpModal.scrollBy(dy)` while `helpOpen`. `onTabRequested` and
  `onReturnRequested` do nothing while `helpOpen`.
- A `PanelActionButton` labelled `?` sits in the header beside the gear and
  calls `root.showHelp()`.
- `BarWidget.qml` gains `function openHelp()`: returns early when the panel
  loader is empty, calls `panelLoader.item.showHelp()`, then
  `panelLoader.item.open()`.

### Menu Help row

`Menu.qml` rows gain one entry:

```js
{ kind: "help", args: [], label: "Help", detail: "what the words mean" }
```

`activate` handles `kind === "help"` by calling `widget.openHelp()`; when the
widget has no `openHelp` it falls back to opening the Health view and sets the
existing `notice`. The header shows `manifest.version` as a dim caption beside
the TrueNAS word when the version is non-empty.

### Manifest

Fields after M6:

```jsonc
"version": "1.0.0",
"license": "MIT",
"homepage": "https://github.com/h4ad/omarchy-truenas",
"description": "… pool health, disk temperatures, active alerts, protection tasks, shares and network state …",
"barWidget": { "description": "… pools, disks, services, apps, protection, shares and alerts." }
```

No field is added that `omarchy plugin validate` does not read. The marketplace
screenshot is `preview.png` at the repo root; there is no manifest field for it.

### Model deletions

`Model.js` loses `worstServiceLevel`, `worstAppLevel`, `worstLinkLevel` and
`worstProtectionLevel`, and `tests/model.mjs` loses their four test groups.
`appsUpgradeable` and `unknownInterfaces` stay and gain callers.

---

## Task A: Help sheet content and panel wiring

**Files:**
- Modify: `Ui/HelpModal.qml`, `Panel.qml`, `BarWidget.qml`

**Step 1: content.** Extend `sections` in `Ui/HelpModal.qml` to the ten
sections in the frozen contract. Each term is one sentence, and each section
note says why the surface exists. Add the `?` to the CONNECTION note so the
sheet explains how it is opened. Keep the existing `anchors.rightMargin:
bodyBar.width` line and the `WheelHandler` exactly once each: `17-qml-structure`
pins both.

**Step 2: panel.** Declare the help sheet inside `PanelKeyCatcher` (four-space
scope), never at the root. Add `showHelp`/`hideHelp`/`helpOpen`, the `?` header
button, and the key-catcher routing per the frozen contract. The existing
`no HelpModal at Panel.qml root scope` check must stay green.

**Step 3: widget.** Add `openHelp()` to `BarWidget.qml`.

**Step 4: verify.** All of:

```bash
./tests/run.sh
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml
./scripts/dev-install
omarchy plugin validate ~/.config/omarchy/plugins/io.github.h4ad.truenas
```

Expected: all suites green, qmllint 0 errors, validate silent. Then, by hand on
the desk: `./scripts/dev-install --restart`, open the panel, click `?`, scroll,
press Escape twice, and
`qs log -p "$OMARCHY_PATH/shell" --tail 100` shows no truenas QML error.

**Step 5: Commit** - `feat: wire the glossary behind a help button`.

---

## Task B: Empty and error states, and the two helper wires

**Files:**
- Modify: `Views/Apps.qml`, `Views/Shares.qml`, and any other `Views/*.qml`
  that fails the state contract, plus `tests/cases/17-qml-structure.sh`

Run in parallel with A and C; the file set does not overlap either.

**Step 1: audit.** Walk every view against the seven-case state contract. For
each view write down which case it fails, if any. Fix only the failures. The
audit is expected to find two, both known:

- `Views/Apps.qml`: add an updates summary under the header, gated on
  `!view.appWarning`, using `Model.appsUpgradeable(view.apps)`. A zero count
  prints nothing, so "no updates" is the absence of the line, not a `0`.
- `Views/Shares.qml`: the Network block names down links through
  `Model.downInterfaces`; add the unknown count through
  `Model.unknownInterfaces(view.network)`, and print nothing when it is zero.

If the audit finds a third, fix it here. Do not start a refactor.

**Step 2: structure check.** In `tests/cases/17-qml-structure.sh`, after the
scroll-surface block, add a check that every data view declares one of
`emptyText`, `statusLine` or `emptyFor`. Name `Views/Config.qml` as the one
exemption in the check, with the reason in the comment. This is a grep over the
source, which is the strongest check available because nothing in CI runs QML.

**Step 3: verify.**

```bash
./tests/run.sh
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml
./scripts/dev-install
omarchy plugin validate ~/.config/omarchy/plugins/io.github.h4ad.truenas
```

Then by hand: `./scripts/dev-install --restart`, open each of the nine tabs with
a filter that matches nothing, and confirm the sentence (not a blank list). On
the desk the live NAS gives the healthy path; the failed-section and offline
paths are covered by `tests/fixtures` only through the poller, so the visual run
is a real check, not a formality.

**Step 4: Commit** - `fix: close the empty and error state gaps`.

---

## Task C: Remove the helpers with no caller

**Files:**
- Modify: `Model.js`, `tests/model.mjs`

**Step 1:** Delete `worstServiceLevel`, `worstAppLevel`, `worstLinkLevel` and
`worstProtectionLevel` from `Model.js`, with their comment blocks.

**Step 2:** Delete the `test_case("worstServiceLevel")`,
`test_case("worstAppLevel")`, `test_case("worstLinkLevel")` and
`test_case("worstProtectionLevel")` groups from `tests/model.mjs`. Keep
`appsUpgradeable` and the `downInterfaces and unknownInterfaces` group.

**Step 3: verify.**

```bash
node tests/model.mjs
./tests/run.sh
grep -rn 'worstServiceLevel\|worstAppLevel\|worstLinkLevel\|worstProtectionLevel' \
  Model.js Views Menu.qml BarWidget.qml Panel.qml
```

Expected: node suite green, all suites green, and the grep prints nothing.

**Step 4: Commit** - `chore: drop the helpers with no caller`.

---

## Task D: Manifest, README and version 1.0.0

**Files:**
- Modify: `manifest.json`, `README.md`

**Step 1:** `manifest.json`: version `0.5.0` to `1.0.0`; extend the top-level
and `barWidget` descriptions to name shares and network; keep `homepage`,
`license` and the schema unchanged. Do not invent fields.

**Step 2:** Rewrite `README.md` for the shipped feature set. Keep it short and
concrete: what the bar and popout show, notifications, the CLI, install (the
marketplace, then the `omarchy plugin add ... --enable` line), setup
(`truenasctl login`, key at mode 600), the security notes (a self-signed
certificate and `insecureTLS`; REST `/api/v2.0` deprecated with `tn_call` as the
migration seam; the key never in argv, `shell.json` or a log), requirements
(TrueNAS 25.10, one NAS, one API key), the docs links, the screenshot and the
`MIT` license. Delete the "Planned: milestone 6" paragraph. Point a reader at
`docs/04-handoff.md` for the shapes that were never measured live.

**Step 3: verify.**

```bash
jq empty manifest.json
./tests/run.sh
```

Expected: manifest parses, suites green. Read the README once against
`docs/03-features.md` and confirm it claims nothing that page does not.

**Step 4: Commit** - `chore: ready the manifest and README for 1.0.0`.

---

## Task E: Screenshot helper

**Files:**
- Create: `scripts/screenshot`
- Modify: `preview.png` (manual, not by the agent)

**Step 1:** Create an executable `scripts/screenshot` that opens the panel over
IPC, waits for the layer-shell surface, and captures a human-selected region:

```bash
#!/usr/bin/env bash
# Captures the bar item and popout into preview.png. Run it on the desk with the
# plugin installed and a live NAS: the panel is a layer-shell surface and the
# frame is a human choice, so the region is picked interactively.
set -euo pipefail

out=${1:-preview.png}
omarchy-shell io.github.h4ad.truenas open || true
sleep 1
grim -g "$(slurp)" "$out"
printf 'wrote %s\n' "$out"
```

`./scripts/dev-install`'s deny-list already drops `scripts` from the installed
tree, so this helper never ships to a user.

**Step 2:** Do not touch `preview.png`. Regenerating it is a manual step (below).

**Step 3: verify.** `bash -n scripts/screenshot`, and `shellcheck
scripts/screenshot` if shellcheck is installed. Then run it by hand and eyeball
the result.

**Step 4: Commit** - `chore: add the screenshot helper`.

---

## Task F: Menu completeness

**Files:**
- Modify: `Menu.qml`

Run after A: the Help row consumes the `openHelp` interface A adds.

**Step 1:** Add the Help row to `rows` and the `kind === "help"` arm to
`activate`, per the frozen contract. Keep the fallback notice for a widget with
no `openHelp`.

**Step 2:** Add the version caption to the header from `manifest.version`, shown
only when non-empty.

**Step 3: verify.**

```bash
./tests/run.sh
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" ./*.qml Views/*.qml Ui/*.qml
./scripts/dev-install
omarchy plugin validate ~/.config/omarchy/plugins/io.github.h4ad.truenas
```

Then by hand: summon the menu, arrow to Help, press Return, confirm the panel
opens with the glossary visible. `17-qml-structure`'s view-key comparison
ignores non-view rows, so it stays green.

**Step 4: Commit** - `feat: add the help and version rows to the menu`.

---

## Task G: Docs and worklog

**Files:**
- Modify: `docs/03-features.md`, `docs/04-handoff.md`,
  `docs/plans/2026-09-13-truenas-plugin-design.md`, `.agent/WORKLOG.md`

Run last, after A to F merge.

- `docs/03-features.md`: add "Milestone 6, what ships" (the help sheet, the
  menu Help row, the state-contract pass, the dropped helpers, the screenshot
  helper, 1.0.0); remove the M6 paragraph from **Planned**; add the M6 plan to
  the plan links; update the **Screenshot** section to name `scripts/screenshot`
  and the manual run.
- `docs/04-handoff.md`: version `1.0.0`, the recounted suite totals (run
  `./tests/run.sh` and copy the summary), the help sheet path, the menu Help
  row, the removed helpers, and the manual-only items that remain (preview,
  GitHub repo, marketplace form, visual pass).
- `docs/plans/2026-09-13-truenas-plugin-design.md`: mark M6 complete in the
  milestones list and record the version decision and the preview decision.
- `.agent/WORKLOG.md`: append the M6 section (date, machine, branch, what
  changed, what is next, what is blocked). Never commit it.

**Verify:** `./tests/run.sh`, then `git status --short` and confirm `.agent`
does not appear.

**Commit** - `docs: document milestone 6`.

---

## Manual-only steps

These cannot be automated inside a deploy or a test run. Each is a human action
with the exact command.

1. **Refresh the preview** (blocking for the marketplace submission, not for the
   merge). On the desk, with the plugin installed, a key set and the poll
   current:
   ```bash
   ./scripts/dev-install --restart
   omarchy-shell io.github.h4ad.truenas open
   ./scripts/screenshot preview.png   # drag over the bar item and the Health popout
   git add preview.png && git commit -S -m 'docs: refresh the preview screenshot'
   ```
   The panel is a layer-shell surface and the crop is a judgement, which is why
   the region is chosen by hand.

2. **Create the public GitHub repository and push only finished work.**
   ```bash
   gh repo create h4ad/omarchy-truenas --public --source ~/Projects/omarchy-truenas --remote origin
   git -C ~/Projects/omarchy-truenas push origin master
   ```
   Push `master` only. Never push an `agent/*` or `wip/*` ref to `origin`.
   Pushing is never done by the agent without an explicit request.

3. **Submit to the marketplace.** Open the submission form linked from
   `https://omarchyplugins.com/develop.html` and complete it with the repo URL,
   the `MIT` license and `preview.png`.

4. **A visual click-through** on a real session after `./scripts/dev-install
   --restart`: every tab, the help `?`, its scroll and Escape handling, the
   menu's Help row, and a filter that matches nothing on each list. No unit test
   runs QML, so this is the only check for the rendering itself.

5. **A live regression check** of the untouched read path:
   ```bash
   bin/truenasctl test -v
   bin/truenasctl poll && bin/truenasctl status
   qs log -p "$OMARCHY_PATH/shell" --tail 100
   ```
   Confirm all thirteen meta sections still write and the log stays clean.

## Execution

Wave layout (worktrees from the handoff recipe, one branch per task):

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m6-<slug> -b agent/desk/m6-<slug> master
# dispatch one implementer per task against its worktree
# reviewer (read-only) checks the branch, implementer fixes, reviewer re-checks
git merge --no-ff agent/desk/m6-<slug> -m "Merge Task <X>: <title>"
git worktree remove /tmp/opencode/tn-m6-<slug> --force
```

- **Wave 1, parallel:** A (help sheet and wiring), B (views), C (Model cleanup),
  D (manifest and README), E (screenshot helper).
- **Wave 2:** F (menu, after A).
- **Wave 3:** G (docs, after A to F; merge last).
- Reviews after each wave: spec-compliance reviewer, then code-quality reviewer,
  both read-only; a reviewer's finding goes back to the implementer and the same
  reviewer re-checks. No task merges with an open finding.
- After every merge run `./tests/run.sh` on master.

## Definition of done for M6

- All suites green (the count in `docs/04-handoff.md` matches the run);
  `/usr/lib/qt6/bin/qmllint` 0 errors; `omarchy plugin validate` clean on a tree
  without `.agent`.
- `Ui/HelpModal.qml` is reachable from the panel `?` and the menu Help row, its
  content covers every shipped surface, and the three `17-qml-structure` pins on
  it hold.
- Every data view satisfies the seven-case state contract, and the new
  structure check enforces a state line in each.
- `Model.js` no longer carries `worstServiceLevel`, `worstAppLevel`,
  `worstLinkLevel` or `worstProtectionLevel`; `appsUpgradeable` and
  `unknownInterfaces` each have a caller.
- `manifest.json` is `1.0.0` with both descriptions naming shares and network;
  `README.md` describes what ships.
- `docs/03`, `docs/04`, the design doc and `.agent/WORKLOG.md` are updated.
- Hub-only: the milestone is committed on `master` and is not pushed here. The
  GitHub repo, the `preview.png` refresh and the marketplace form are the
  manual-only steps above.

## Open questions

- Does the marketplace accept a `homepage` that does not resolve yet? The plan
  assumes no, which is why the repository creation is a manual gate before
  submission, not a code change.
- Is the `?` header button enough, or does the glossary also want a summon
  keybinding? The plan ships the button and the menu row and adds no keybinding,
  to avoid colliding with a host binding. Revisit if users ask.
- Should the Apps updates count move to the bar? No in M6: that is a bar variant
  and the design's variants are frozen at seven. The count lives in the Apps
  view.
- Does `1.0.0` overstate readiness while REST `/api/v2.0` is deprecated? The
  decision above says no, because the plugin pins 25.10 and `tn_call` isolates
  the migration. If a 1.0 is held to "every path measured live", stay `0.6.0`
  and record why; that is the only credible alternative.
