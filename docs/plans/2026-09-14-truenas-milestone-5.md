# TrueNAS plugin milestone 5 implementation plan

> **For the executor:** work this plan task-by-task. Independent tasks run in
> git worktrees, one branch each, with a fresh implementer per task and a
> separate spec + quality reviewer after. Steps are bite-sized; do not skip the
> "run it and watch it fail" step. See **Execution** at the bottom for the wave
> layout.

**Goal:** Milestone 5 - shares and network read-only inventory: read the SMB and
NFS shares, the iSCSI targets and the network interfaces on the meta cadence
into `state.json`, render a Shares view with a Network block, and add
`truenasctl shares` / `truenasctl network`, all verified against the real NAS
(`https://nas.example:4433`, TrueNAS 25.10.6).

**Architecture:** unchanged from M1 to M4. `bin/truenas-poll` reads four more
slow routes and caches the consumed wire fields in `meta.json`;
`share/normalize.jq` gains one row function per share type because the three
share types do not share a field vocabulary; `BarWidget.qml` stays a read-only
watcher; the panel's new Shares view renders the rows. M5 adds no write, no bar
variant and no notification.

**Tech stack:** QML/Quickshell, bash + curl + jq, node for unit tests; the same
test harness as M1 to M4.

**Design doc:** `docs/plans/2026-09-13-truenas-plugin-design.md`.
**Recon:** `docs/plans/2026-09-14-recon-shares-network.md` (the measured shapes;
it overrides the design's endpoint guesses).
**Pitfalls:** `docs/11-pitfalls.md` (read the QML, `.pragma`, `arrayLike` and
duplicate-function sections before touching code).

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
  an empty list plus a `warnings` entry, and the UI prints a sentence. An empty
  list only ever means the route answered with no rows.
- All names and states that came off the wire are written into request bodies by
  `jq -n --arg`, never interpolated into a shell string.
- `bin/truenas-api` is not touched in M5: nothing new is written.

## Verified against the live NAS (2026-09-14, TrueNAS 25.10.6)

These were probed before this plan was written, and the plan does **not** assume
the design doc's endpoint list. The full probe record is
`docs/plans/2026-09-14-recon-shares-network.md`.

| Purpose | Method | Path | Observed answer |
| --- | --- | --- | --- |
| SMB shares | GET | `/api/v2.0/sharing/smb` | JSON array, three shares (`default`, `backup`, `media`) |
| NFS exports | GET | `/api/v2.0/sharing/nfs` | JSON array, one export; read-only flag is `ro` |
| iSCSI targets | GET | `/api/v2.0/iscsi/target` | JSON array, empty on this box |
| network interfaces | GET | `/api/v2.0/interface` | JSON array, one `PHYSICAL` interface; link and media live under `state` |
| WebDAV shares | GET | `/api/v2.0/sharing/webdav` | 404, `text/plain` |
| SMB status / sessions | GET | `/api/v2.0/smb/status` | 404, `text/plain` |
| interfaces (design name) | GET | `/api/v2.0/network/interface` | 404, `text/plain` |
| list query routes | POST/GET | `/sharing/smb/query`, `/interface/query` | 404: there is no query route anywhere |

### What the recon changed from the design

1. **Interface route.** The design's `/network/interface` is 404; the route is
   `/api/v2.0/interface`. `link_state`, `media_type` and `active_media_subtype`
   live under the nested `state` object, not at the top level. A jq path that
   asks for `.link_state` on the interface yields `null` silently.
2. **WebDAV is dropped.** There is no `/sharing/webdav` route and no `webdav`
   method on 25.10. The design's `shares.webdav` has no source and is not in
   `state.json`.
3. **SMB sessions are dropped.** `/smb/status` is 404 and the `smb` namespace
   exposes only `smb.config`, `smb.update`, `smb.bindip_choices` and
   `smb.unixcharset_choices`. The design's `sessions.smb` is not in `state.json`.
4. **iSCSI is not a share.** It is not under `/sharing`; the collection is
   `/api/v2.0/iscsi/target`. The box has zero targets, so the iSCSI fixture in
   the tests is synthetic (from the v25.10.5 `iscsi.target.query` schema) and is
   marked as such. It is the first real measurement on a box with a target.
5. **Two share vocabularies.** SMB calls the read-only flag `readonly`; NFS calls
   it `ro`. One normalizer row per type, not a generic mapper.
6. **`shares` becomes rows, not counts.** The design's `shares` object of counts
   is replaced by `{smb:[],nfs:[],iscsi:[]}`; a count is the list's `.length`
   and is only trusted when no warning names the section.

## Frozen contracts (all tasks code against these)

### `state.json` `shares` and `network`

```jsonc
"shares": {
  "smb": [ { "id": 1, "name": "default", "path": "/mnt/storage/default",
             "enabled": true, "locked": false, "readonly": false,
             "purpose": "DEFAULT_SHARE", "comment": "" } ],
  "nfs": [ { "id": 1, "path": "/mnt/storage/default", "enabled": true,
             "locked": false, "readonly": false, "comment": "" } ],
  "iscsi": [ { "id": 1, "name": "iqn.2005-10.org.freenas.ctl:target0",
               "alias": "bulk", "mode": "ISCSI" } ]
},
"network": [ { "name": "enp4s0", "type": "PHYSICAL",
               "linkState": "LINK_STATE_UP",
               "mediaType": "Ethernet",
               "mediaSubtype": "1000Mb/s Twisted Pair",
               "addresses": [ { "type": "INET", "address": "192.0.2.10",
                                "netmask": 24 } ] } ]
```

- `shares.smb` rows carry `id`, `name`, `path`, `enabled`, `locked`,
  `readonly`, `purpose`, `comment`. `enabled`, `locked` and `readonly` are
  booleans defaulting `false`; `id` is a number or `null`.
- `shares.nfs` rows carry `id`, `path`, `enabled`, `locked`, `readonly`,
  `comment`. The normalizer reads the wire `ro` and writes `readonly`, so the
  two share types present one name to the UI.
- `shares.iscsi` rows carry `id`, `name`, `alias`, `mode`. An iSCSI target has
  no `enabled`, `locked` or `path` field in the schema, so the row does not
  invent one; `groups`, `rel_tgt_id` and `iscsi_parameters` are dropped.
- `network` rows carry `name`, `type`, `linkState`, `mediaType`, `mediaSubtype`,
  `addresses`. `linkState` is the raw `state.link_state` word (`LINK_STATE_UP`,
  `LINK_STATE_DOWN` or `LINK_STATE_UNKNOWN`). `mediaType` is
  `state.media_type`; `mediaSubtype` is `state.active_media_subtype`, the
  negotiated speed. `addresses` is `state.aliases` (the runtime addresses)
  mapped to `{type, address, netmask}`, with `broadcast` dropped and the
  link-local IPv6 kept.
- Sorted for stable tests and UI: `shares.smb` by `name`, `shares.nfs` by
  `path`, `shares.iscsi` by `name`, `network` by `name`.
- A failed section is its list empty plus a warning; an answered-but-empty list
  is a real zero with no warning. `shares.webdav`, `sessions` and the old
  `shares` counts are gone.

### `meta.json`

The four new sections ride the meta cadence exactly as the M3 sections do. The
cache keys are the section names, and each holds `fetchedAt` plus the raw wire
fields the normalizer consumes, under their wire names:

```jsonc
{ "smb":     { "fetchedAt": "...",
               "rows": [ { "id": 1, "name": "default", "path": "/mnt/storage/default",
                           "enabled": true, "locked": false, "readonly": false,
                           "purpose": "DEFAULT_SHARE", "comment": "" } ] },
  "nfs":     { "fetchedAt": "...",
               "rows": [ { "id": 1, "path": "/mnt/storage/default", "enabled": true,
                           "locked": false, "ro": false, "comment": "" } ] },
  "iscsi":   { "fetchedAt": "...",
               "rows": [ { "id": 1, "name": "iqn.…:target0", "alias": "bulk",
                           "mode": "ISCSI" } ] },
  "network": { "fetchedAt": "...",
               "rows": [ { "name": "enp4s0", "type": "PHYSICAL",
                           "state": { "link_state": "LINK_STATE_UP",
                                      "media_type": "Ethernet",
                                      "active_media_subtype": "1000Mb/s Twisted Pair",
                                      "aliases": [ { "type": "INET", "address": "192.0.2.10",
                                                     "netmask": 24 } ] } } ] } }
```

The whitelist is the point: it drops the SMB `audit` and `options` blobs, the
NFS `hosts`, `networks` and `security` lists, the iSCSI `groups` and
`iscsi_parameters`, and every interface MAC (`link_address`,
`permanent_link_address`, `hardware_link_address`) before the write. The
`network` row keeps the nested `state` object because the normalizer reads
`state.link_state` on both the fetch and the reuse path.

`meta_is_stale` becomes true unless **all nine** sections are present
(`.system.data`, `.disks.rows`, `.diskTemps.map`, `.services.rows`,
`.apps.rows`, `.smb.rows`, `.nfs.rows`, `.iscsi.rows`, `.network.rows`) and
`.system.fetchedAt` is fresh (or `--force-meta`). An existing `meta.json`
without the new keys reads as stale once, refetches once, and self-heals. Meta
advances only when every fetched section succeeded and normalization succeeded;
otherwise the previous meta stays byte-for-byte intact.

The SMB global config at `GET /api/v2.0/smb` is **not** cached in M5: the design
does not ask for it and it would add a fifth call. See the open questions.

### Warning section names

`smb`, `nfs`, `iscsi` and `network`. Views, Menu and `truenasctl` scan for all
four. The message from `state_unknown_reason` is "the `<section>` section did
not answer".

### Model.js helpers

| Function | Behavior |
| --- | --- |
| `linkStateRank(state)` | `LINK_STATE_UP` → `0`; `""` and `LINK_STATE_UNKNOWN` → `2`; anything else (including `LINK_STATE_DOWN`) → `1` |
| `linkStateText(state)` | `LINK_STATE_UP` → `"up"`; `LINK_STATE_DOWN` → `"down"`; anything else → `"unknown"` |
| `worstLinkLevel(network)` | `"warning"` if any rank `1`, else `"unknown"` if any rank `2`, else `""` |
| `downInterfaces(network)` | the rank `1` rows, in input order, as a copy |
| `unknownInterfaces(network)` | the rank `2` rows, in input order, as a copy |
| `shareCounts(shares)` | `{smb, nfs, iscsi, total}` from the three lists, each `0` for an absent or non-list key; a bad `shares` object yields all zeroes |

The non-monotonic link rank follows `serviceStateRank`: a blank or unknown link
is "I cannot tell" and must not read as a down link. `shareCounts` counts rows
and yes, a section that failed contributes `0`, so the caller must gate the
printed count on that section's warning, exactly as `Menu.qml` gates
`servicesText` today. All helpers are pure, never touch QML, and guard every
list argument with `arrayLike`.

### Search.js filters

- `shares(list, needle)`: matches `name`, `path`, `comment` and `purpose`. One
  filter serves all three share types because each type carries a subset of
  those fields and an empty field never matches a non-empty needle.
- `interfaces(list, needle)`: matches `name`, `type`, `linkState`, `mediaType`,
  `mediaSubtype`, and each `addresses[].address`.
Both mirror `Search.disks` exactly: copy semantics, empty needle returns every
row, non-list and junk rows do not throw.

### `truenasctl` verbs

- `truenasctl shares` prints `TYPE  NAME  PATH  ENABLED  RO`, one row per SMB,
  NFS and iSCSI share, sorted SMB (by name), NFS (by path), iSCSI (by name).
  `ENABLED` and `RO` are `yes`/`no`; a field the type does not have prints `-`
  (iSCSI has no `path`, `enabled` or read-only flag, NFS has no `name`); a
  field the type has but the poll did not learn prints `unknown`. A type whose
  section warned prints `TYPE shares unknown: <reason>` on its own line before
  the table, and its rows are omitted.
- `truenasctl network` prints `NAME  TYPE  LINK  MEDIA  ADDRESSES`, one row per
  interface, sorted by name. `LINK` is `up`/`down`/`unknown` derived from
  `linkState`; `MEDIA` is `mediaSubtype`, falling back to `mediaType`; `ADDRESSES`
  is every `address/netmask` joined with `,`. A failed interface section prints
  `network unknown: <reason>` instead of an empty table.

---

## Task A: Shares and network read path - list, normalize, meta cache

**Files:**
- Modify: `share/normalize.jq`, `bin/truenas-poll`, `tests/cases/10-poll.sh`,
  `tests/cases/13-meta.sh`, `tests/cases/11-notify.sh`
- Create: `tests/fixtures/shares-smb.json`, `tests/fixtures/shares-nfs.json`,
  `tests/fixtures/iscsi-target.json`, `tests/fixtures/interfaces.json`

**Step 1: fixtures.** Add the four fixtures in the exact shapes above. The SMB
fixture carries three shares (`default` and `backup` enabled, `media` disabled
and read-only) with the `audit` and `options` blobs present on purpose, so the
meta-cache test can prove they are dropped. The NFS fixture carries one export
with `ro` false. The iSCSI fixture is synthetic from the v25.10.5
`iscsi.target.query` schema (two targets) and its header comment says so,
because the live box has zero targets. The interface fixture uses documentation
addresses (`192.0.2.10`, `2001:db8::10`) and a documentation MAC
(`02:00:00:00:00:01`) on purpose, so the cache test can prove the MAC is
dropped. No real serials, keys, hostnames or MACs.

**Step 2: normalize.jq.** Add `smb_norm`, `nfs_norm`, `iscsi_norm` and
`iface_norm` producing exactly the frozen rows, and add `--slurpfile smb`,
`--slurpfile nfs`, `--slurpfile iscsi`, `--slurpfile network` to the top-level
assembly. `iface_norm` reads the nested state safely:

```jq
def iface_norm:
  ((.state? // {}) | if type == "object" then . else {} end) as $st
  | {
      name:         (.name // ""),
      type:         (.type // ""),
      linkState:    ($st.link_state // ""),
      mediaType:    ($st.media_type // ""),
      mediaSubtype: ($st.active_media_subtype // ""),
      addresses: [ ($st.aliases? // [])[]?
                   | { type:    (.type // ""),
                       address: (.address // ""),
                       netmask: ((.netmask? // null) | num) } ]
    };
```

Output `shares: { smb: ($smb_rows | sort_by(.name)), nfs: ($nfs_rows |
sort_by(.path)), iscsi: ($iscsi_rows | sort_by(.name)) }` and
`network: ($iface_rows | sort_by(.name))`.

**Step 3: poll.** Fetch the four routes on the meta cadence, after the app
fetch, with `shape='type == "array" and all(.[]; type == "object")'` for each.
Add the four arms to the `fetch` `case $section`. Extend `default_payload` with
`"shares":{"smb":[],"nfs":[],"iscsi":[]},"network":[]`. Add
`smb_fetched/smb_ok`, `nfs_fetched/nfs_ok`, `iscsi_fetched/iscsi_ok` and
`network_fetched/network_ok`. On the reuse path reconstruct `$WORK/smb.json`
from `.smb.rows`, `$WORK/nfs.json` from `.nfs.rows`, `$WORK/iscsi.json` from
`.iscsi.rows` and `$WORK/network.json` from `.network.rows`. Extend
`meta_is_stale` and the meta-advance condition to all nine sections, and cache
the reduced wire rows per the contract. Extend the final `state.json` assembly
with `shares` and `network`.

**Step 4: tests.** In `tests/cases/10-poll.sh`: add the four routes to
`all_healthy`; assert the SMB sort (`backup,default,media`), the disabled and
read-only `media` row, `locked` false, the one NFS export with
`readonly` false, the two synthetic iSCSI targets, the one interface with
`linkState == "LINK_STATE_UP"`, `mediaSubtype`, and two addresses; keep the "no
warnings on a clean poll" assertion green. Add failure cases: a 500 on
`/sharing/smb` gives `shares.smb: []` plus an `smb` warning while NFS and
network still render; a 500 on `/api/v2.0/interface` gives `network: []` plus a
`network` warning while the shares render; a `[]` from `/iscsi/target` is a real
zero with **no** warning. Update the cold-poll request count from `7` to `11`.
In `tests/cases/13-meta.sh`: add the four routes to `meta_responses`; add
`smb_requests`, `nfs_requests`, `iscsi_requests` and `network_requests` helpers;
update the cumulative warm count from `9` to `13`; update the self-heal loop to
`for missing in disks diskTemps services apps smb nfs iscsi network` with the
"refetches all eleven" count `11`; add cache assertions proving the SMB
`audit`/`options` blobs, the NFS `hosts`/`networks`/`security` lists, the iSCSI
`groups`/`iscsi_parameters` and the interface MAC fields never reach disk, and
that the consumed fields survive. In `tests/cases/11-notify.sh`: extend
`notify_endpoints` with the four routes so the notification suites still reach
the warm path and the "seven endpoints" comment is updated.

**Step 5:** `./tests/run.sh`, `bash -n bin/truenas-poll`, `jq empty` on the four
fixtures.

**Step 6: Commit** - `feat: read shares and interfaces on the meta cadence`.

---

## Task B: Model and Search helpers

**Files:**
- Modify: `Model.js`, `Search.js`, `tests/model.mjs`, `tests/search.mjs`

**Step 1:** Add the six Model helpers in the frozen contract, following the
`serviceStateRank`/`worstServiceLevel` style, with `arrayLike` guards and no
fabricated zero. `linkStateText` must never print `"undefined"`.

**Step 2:** Add `Search.shares` and `Search.interfaces`, copying `Search.disks`
including its copy semantics and junk-row tolerance.

**Step 3:** `tests/model.mjs`: one test group per helper; for each, the
unknown/absence case (`null`, `""`, non-list, a row with no link state) proving
it does not become `0` or `"undefined"`, plus the rank ordering
up/down/unknown. `tests/search.mjs`: the same block of cases `disks` has for
each new filter (matched fields, case-insensitivity, order preserved, copy not
identity, empty needle returns all, non-list returns `[]`, junk rows do not
throw), including an address match for `interfaces`.

**Step 4:** `./tests/run.sh`.

**Step 5: Commit** - `feat: add share and interface helpers`.

---

## Task C: Shares view, Panel tab, Menu row

**Files:**
- Create: `Views/Shares.qml`
- Modify: `Panel.qml`, `Menu.qml`, `tests/cases/17-qml-structure.sh` (no change
  expected; it must keep passing)

Run after A and B. `17-qml-structure.sh` cross-links the `Panel.qml` tab keys,
the `Panel.qml` `viewComponents` map and the `Menu.qml` view rows; all three must
gain `shares` (lowercase, exact indentation) or it fails.

**Decision - one combined view, read-only.** One `shares` tab holds a Shares
block and a Network block instead of adding two tabs: the tab row is a single
non-wrapping `Row`, and two more tabs crowd the default 460px panel, while
shares and interfaces are both "what the NAS serves and over what link". The
view is read-only. The design's "Writes (full control)" list names alert, service
and app writes and the protection run-now writes; it does not name shares, and
`docs/03-features.md` puts creating or editing shares explicitly out of scope.
Toggling `enabled` would need a `PUT /sharing/smb/{id}` carrying the whole share
document plus a write-verb and confirmation path, all of which the design does
not demand, so M5 ships read-only and the toggle is deferred (open questions).

**Step 1:** `Views/Shares.qml`, modelled on `Views/Services.qml`: read
`view.panel.state`, guard `state.shares` and `state.network` with `arrayLike`, a
`warnings` lookup for each of `smb`, `nfs`, `iscsi` and `network`, and an
`emptyText`/`warningLine` pair per block (a failed section says why, never "0
shares"). The Shares block draws an SMB, an NFS and an iSCSI sub-list with a
`FilterField` + `Search.shares`; each card shows the name (SMB and iSCSI) or path
(NFS), the path, and `enabled`/`locked`/`readonly` markers where the type has
them. The Network block draws one card per interface with `linkStateText`, the
media line, and the addresses formatted `address/netmask`. A link-out line uses
`Links.sharesUrl(view.panel.baseUrl)`. No actions, so no `requestConfirm`.

**Step 2:** `Panel.qml`: add `{ key: "shares", label: "Shares" }` between `apps`
and `alerts`, the `"shares": sharesView` entry in `viewComponents`, and the
`Component { id: sharesView; Views.Shares { panel: root } }` registration.

**Step 3:** `Menu.qml`: add the `shares` and `network` list properties, the four
warning lookups, a `sharesText` detail property that prints the counts or the
section's failure sentence (gated on the warnings, like `servicesText`), and the
`{ kind: "view", args: ["shares"], label: "Shares", detail: root.sharesText }`
row between `apps` and `alerts`.

**Step 4:** `17-qml-structure.sh` keeps passing once all three lists match.

**Step 5:** `./tests/run.sh`; `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell"
./*.qml Views/*.qml Ui/*.qml` with 0 errors.

**Step 6: Commit** - `feat: add the Shares view`.

---

## Task D: `truenasctl shares` and `truenasctl network`

**Files:**
- Modify: `bin/truenasctl`, `tests/cases/14-ctl.sh`

Run after A.

**Step 1:** Add `cmd_shares` and `cmd_network` mirroring `cmd_services`: the
`[[ -s $file ]]` guard, the `jq -e 'type == "object"'` unreadable guard, the
per-section `state_unknown_reason "$file" smb|nfs|iscsi` / `network` gate, then
the `jq -r` table. Extend the `state_unknown_reason` header comment with the four
new section names, add the two dispatch arms, and add the two usage lines.

**Step 2:** `tests/cases/14-ctl.sh`: hand-build a `state.json` with a `shares`
object and a `network` list and assert the two tables, the `yes`/`no`/`unknown`
formatting, the `-` for a field a type does not have, the address formatting, an
empty list printing just the header, and the unknown path when a section warning
is present.

**Step 3:** `./tests/run.sh`, `bash -n bin/truenasctl`.

**Step 4: Commit** - `feat: add the truenasctl shares and network verbs`.

---

## Task E: Docs and version

**Files:**
- Modify: `docs/02-truenas-api.md`, `docs/03-features.md`,
  `docs/plans/2026-09-13-truenas-plugin-design.md`, `manifest.json`,
  `README.md`, `docs/04-handoff.md`, `.agent/WORKLOG.md`

Run last, after the code tasks merge, and **after milestone 4's docs task
merges**: this task and M4's docs task both edit `docs/02`, `docs/03`, the design
doc, `README.md` and `manifest.json`, so rebase on the M4 result first and land
this one on top.

- `docs/02-truenas-api.md`: a milestone-5 section with the verified endpoint
  table, the four corrections (the `/interface` route and the nested `state`,
  WebDAV dropped, SMB sessions dropped, iSCSI under `/iscsi`), the two share
  vocabularies, the `422 {"data":[{"message","errno"}]}` create-route shape, the
  meta cache keys, and the "not verified" list (iSCSI shape, non-up link states,
  bridge/VLAN interfaces, locked shares).
- `docs/03-features.md`: a "Milestone 5, what ships" section (Shares view with
  the Network block, `truenasctl shares` / `network`, meta-cadence caching) and
  remove the M5 paragraph from **Planned**.
- `docs/plans/2026-09-13-truenas-plugin-design.md`: amend the meta cadence list
  (`/sharing/smb`, `/sharing/nfs`, `/iscsi/target`, `/interface`; no
  `sharing/webdav`, no `smb/status`), the `state.json` sketch (`shares` as rows,
  `sessions` removed, the `network` row shape), the Files view list, and note
  that no bar variant is added in M5.
- `manifest.json`: version `0.3.0` → `0.4.0`.
- `README.md`: remove shares and network from the **Planned** sentence.
- `docs/04-handoff.md`: mark M5 done, update the data flow and the live
  environment notes with the four routes.
- `.agent/WORKLOG.md`: append the M5 entry (date, machine, branch, what changed,
  next, blocked).

**Verify:** `jq empty manifest.json`, then `./tests/run.sh`.

**Commit** - `docs: document milestone 5 and bump the version`.

---

## Execution

Wave layout (worktrees from the handoff recipe, one branch per task):

```bash
cd ~/Projects/omarchy-truenas
git worktree add -q /tmp/opencode/tn-m5-<slug> -b agent/desk/m5-<slug> master
# dispatch one implementer per task against its worktree
# reviewer (read-only) checks the branch, implementer fixes, reviewer re-checks
git merge --no-ff agent/desk/m5-<slug> -m "Merge Task <X>: <title>"
git worktree remove /tmp/opencode/tn-m5-<slug> --force
```

- **Wave 1, parallel:** A (read path), B (Model/Search).
- **Wave 2, parallel:** C (view/panel/menu, after A + B), D (`truenasctl`,
  after A).
- **Wave 3:** E (docs, after A to D, and after M4's docs merge).
- Reviews after each wave: spec-compliance reviewer, then code-quality reviewer,
  both read-only; a reviewer's finding goes back to the implementer and the same
  reviewer re-checks. No task merges with an open finding.
- After every merge run `./tests/run.sh` on master.

### Live verification steps

Against the live NAS (`https://nas.example:4433`, `insecureTLS` true):

1. `./scripts/dev-install --restart` on the desk.
2. `bin/truenas-poll --quiet --force-meta` writes `state.json`; confirm it has
   `shares.smb` (three rows), `shares.nfs` (one row), `shares.iscsi` (`[]`, the
   real zero), `network` (one `enp4s0` row) and no `sessions` or `shares.webdav`.
3. `bin/truenasctl shares` and `bin/truenasctl network` print the tables.
4. `bin/truenasctl poll` twice and confirm the warm poll spends two requests and
   the version of the meta sections does not change.
5. Open the panel, click Views and check the Shares tab renders both blocks;
   the interface shows its link, media and addresses, and no MAC.
6. Confirm the dropped routes are still 404 with the recon recipe
   (`/sharing/webdav`, `/smb/status`, `/network/interface`) so the plan's claims
   match the box.
7. `./tests/run.sh` green; `qmllint` 0 errors; `omarchy plugin validate` clean on
   a tree without `.agent`.

**Definition of done for M5:** all suites green; `qmllint` 0 errors;
`omarchy plugin validate` clean on a tree without `.agent`; `./scripts/dev-install
--restart`; against the live NAS the poll writes the three share types and the
interface, `truenasctl shares` and `truenasctl network` print them, and the panel
renders the Shares tab; no write verb and no notification added; `.agent/WORKLOG.md`
and `docs/04-handoff.md` updated; `git push hub master`.

## Open questions and risks

- **The iSCSI row shape is unverified.** The box has zero targets, so the field
  names and types come from the v25.10.5 reference and the test fixture is
  synthetic. The first box with a target is the first real measurement. M5 drops
  `groups` and `iscsi_parameters`, so auth method is not shown; a later milestone
  that wants it caches those fields.
- **Non-up link states are unverified.** Only `LINK_STATE_UP` was observed; the
  `LINK_STATE_DOWN` and `LINK_STATE_UNKNOWN` spellings are from the TrueNAS
  enum. `Model.linkStateRank` treats any unrecognized word as unknown so a new
  spelling never reads as down.
- **Bridge, VLAN and link-aggregation interfaces are unverified.** Only one
  `PHYSICAL` interface exists. The normalizer reads the same nested paths for
  every type, so an unknown shape degrades to empty strings, not a crash.
- **`locked` was only ever seen false.** No locked dataset exists on the box.
- **No network deep link.** `Links.js` has no `networkUrl`, and the recon did not
  check the 25.10 web UI route for the network page, so the Network block has no
  link-out. The Shares block uses the existing `Links.sharesUrl`. Adding a route
  later is a one-line `Links.js` change plus a test.
- **The SMB global header is out of M5.** `GET /api/v2.0/smb` (`netbiosname`,
  `workgroup`, `encryption`) would add a fifth meta call and a cache key. Left
  for a later milestone if the Shares view wants a header.
- **Rate limit.** A cold poll now spends eleven requests in one burst (the alert,
  pool and nine slow routes), against roughly twenty per 60s. It stays under the
  limit, but no further meta routes should be added without re-checking it.
- **Docs conflict with M4.** Both M5's docs task and M4's touch the same docs and
  `manifest.json`; land M4 first and rebase. The M5 state and cache keys assume
  M4 did not change `meta_is_stale`, the `fetch` shape table or the state
  assembly; if it did, re-read `bin/truenas-poll` before Task A.
