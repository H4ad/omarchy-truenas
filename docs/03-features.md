# Features

What milestones 1 to 4 ship, and what the design defers. The split is the
design's: bar value against cost (API unknowns plus QML work). The design is
[plans/2026-09-13-truenas-plugin-design.md](plans/2026-09-13-truenas-plugin-design.md);
the task-by-task versions are
[plans/2026-09-13-truenas-milestone-1.md](plans/2026-09-13-truenas-milestone-1.md),
[plans/2026-09-13-truenas-milestone-2.md](plans/2026-09-13-truenas-milestone-2.md),
[plans/2026-09-13-truenas-milestone-3.md](plans/2026-09-13-truenas-milestone-3.md)
and [plans/2026-09-14-truenas-milestone-4.md](plans/2026-09-14-truenas-milestone-4.md).
The endpoints are in [02-truenas-api.md](02-truenas-api.md), and the traps that
have already cost time are in [11-pitfalls.md](11-pitfalls.md).

## Milestone 1, what ships

**Bar variants.** One widget, six variants chosen in Setup > Plugins:

| Variant | What the bar prints |
| --- | --- |
| `Default` | the active alert count when anything is firing, otherwise the fullest pool's capacity |
| `Icon` | the glyph alone, tinted by the worst state |
| `Alerts` | the active alert count |
| `Capacity` | the fullest pool's percentage |
| `Pool` | the worst pool's status word |
| `Full` | alerts plus capacity |

A zero is not printed: "no alerts" is the absence of a number, not a `0` on the
bar. An unreachable NAS overrides every variant with a plug and an unconfigured
one with a cog, so "nothing is wrong" and "I cannot tell" never look the same.
`hideWhenHealthy` hides the item, and a dimmed glyph is how you tell the plugin
is alive and reaching the NAS.

**Health view.** Connection state and last-poll age, hostname, version, uptime,
pool capacity bars, and alert counts by level. An unknown number is a sentence,
never `0` or a loading dash.

**Pools view.** A capacity bar per pool, status tinted, allocated/free, scrub
state and age, and vdev error counts when non-zero. A pool with no scrub data
says "no scrub on record" rather than inventing a date.

**Alerts view.** A row per alert: level glyph, text, node, age, and `dismiss` /
`restore` where the alert allows it. The write verbs go through `bin/truenas-api`:
dismiss behind a confirmation, restore straight out. The panel re-polls with
`--force-meta` before it believes them.

**Config view.** The bar settings plus a read-out of the NAS setup. Only two
fields are writable in the panel: `variant`, written back to `shell.json`, and
the API key, entered through a masked `SecretField`, written on stdin and never
shown back. `pollSeconds`, `timeoutSeconds` and `insecureTLS` are displayed but
not editable here; change them in `~/.config/omarchy/truenas/config.json` or with
`truenasctl config set`.

**Notifications.** A toast when an alert starts firing, one when it clears, and
one when a pool leaves or returns to `ONLINE`. Deduped in `seen.json` by a
stable key so a network blip does not replay every alert as new; severity maps
to urgency; a critical toast never sticks by default. A failed poll leaves
`seen.json` untouched.

**`truenasctl`.** The terminal side: `login` (key on stdin, stored at mode 600),
`logout`, `test [-v]` (step by step, distinguishing TLS / no key / key rejected
/ forbidden / not JSON / timed out), `status`, `alerts`, `pools`, `poll`,
`config list|set|set-key`, `open` and `purge`.

**Menu.** A `TrueNAS` summon menu that reaches the popout, each view, poll-now
and the NAS UI.

## Milestone 2, what ships

**Disks view.** One card per disk: the device name and its temperature, tinted
when the reading is `critical` or `warning`; the model; a `type · size · pool ·
bus` line with the empty pieces dropped; and `critical at 60 °C` when the poll
reported a threshold. A disk with no reading says `temperature unknown`, never
`0 °C`, and a failed details or temperatures fetch prints which one could not be
read. The filter field matches name, model, type, pool and bus.

**`Temp` bar variant.** A seventh variant: the hottest known disk's temperature,
rounded with a degree sign (`54°`), tinted by the worst disk state, and blank
when no disk reports one. It is selectable in Setup > Plugins alongside the
other six.

**Temperature notifications.** A toast when a disk crosses into the warning or
critical band (`Disk sda is hot` / `61 °C, critical at 60 °C`) and one when it
cools back to `ok` (`Disk sda cooled` / `38 °C`). Deduped in `seen.json` under
`.disks.<name>` so a disk that stays hot does not toast twice; a failed disk or
temperature fetch leaves that half of `seen.json` untouched, so a network blip
does not replay every disk on recovery. There are no SMART toasts: the API
dropped SMART tests after 24.10 and `smart/test/results` is `404` on 25.10.6.

**`truenasctl disks`.** `NAME  TYPE  SIZE  POOL  TEMP`, where `TEMP` is
`38 °C` or `unknown`; a failed disk or temperatures section prints the
unknown-reason sentence instead of an empty table.

## Milestone 3, what ships

**Services view.** One card per service: the name and its state, tinted by
`serviceStateRank` so a blank state is dim `unknown` and never a stopped
service, and the enabled flag. Start, stop and restart each go through the
panel's single confirmation because a misclick drops connections; the
inapplicable verb is not offered, and restart is always available. A failed
services request says why and never renders as a NAS that runs nothing. The
filter matches name, state and id.

**Apps view.** One card per app: `appLabel`, state tinted by `appStateRank` so a
transitional deploy is dim and not down, the version and train, and an update
marker when the NAS reports one. Start, stop and redeploy are each confirmed,
redeploy being the restart-like verb because the API has no app restart route. A
portal the poll reported opens through `Links.safeUrl`; otherwise the card falls
back to the apps page. The filter matches name, title, state, train, appVersion
and version.

**Control writes.** Six verbs behind confirmation: `service-start`,
`service-stop`, `service-restart`, `app-start`, `app-stop` and `app-redeploy`.
Each is one queued `bin/truenas-api` call followed by a forced re-poll, so the
panel reads the NAS back rather than trusting the verb's own answer. A service
control answers `true` synchronously; an app control answers a job id and lands
asynchronously, and the next poll catches up rather than fabricating a state.

**Down and recovery notifications.** A toast when a service or app leaves its
running state and one when it returns, deduped in `seen.json` under
`.services.<name>` / `.apps.<name>` by the last decisive state and a stable
`down` boolean. A blank or transitional poll carries both forward, so it cannot
erase the signal, and a failed services or apps fetch leaves that half of
`seen.json` untouched.

**Meta-cadence caching.** `/service` and `/app` join `/system/info`,
`disk/details` and `disk/temperatures` on the meta cadence: a cold poll spends
seven requests and a warm poll two. The cache holds only the wire fields the
plugin consumes; service `pids`, app `notes` and the workload details are
dropped before the write.

**`truenasctl services` / `truenasctl apps`.** `SERVICE  STATE  ENABLED` and
`APP  STATE  VERSION  UPDATE`, with `unknown` for an `ENABLED` or `UPDATE` flag
that was never learned, and the section's failure sentence instead of an empty
table.

## Milestone 4, what ships

**Protection view.** One tab with four sections. Replication tasks show the
name, direction, transport, target dataset, schedule, the last job state and
its finish time. Cloud sync tasks show the name, direction, transfer mode, path,
schedule and last job. Periodic snapshot tasks show the dataset, naming schema,
schedule and the last snapshot, or `no snapshot on record` when the task is
`PENDING`. Scrub tasks show the pool, whether it is enabled, its threshold and
schedule; a pool's scrub progress itself stays on the Pools view, read from
`pool.scan`. Every row's state is tinted by `Model.protectionStateRank`, so a
blank or `RUNNING` job is dim `unknown` and never a failure. Each section has
its own filter; a failed section says why and never renders as a NAS with no
protection tasks.

**Run-now writes.** Four verbs behind the panel's single confirmation:
`replication-run <id>`, `cloudsync-sync <id>`, `snapshot-run <id>` and
`scrub-start <pool>`. Each is one queued `bin/truenas-api` call followed by a
forced re-poll, so the panel reads the NAS back. Replication and cloud sync runs
answer a job id and land asynchronously; the snapshot task run answers `null`
synchronously; the scrub start answers a job id. The scrub verb is the async
`pool/scrub/scrub` with `action: START`, not the due-gated `pool/scrub/run`,
because a run-now button that may quietly do nothing reads as broken.

**Protection failure and recovery notifications.** A toast when a replication or
cloud sync job enters `FAILED`, `ERROR` or `ABORTED`, or when a replication
task's `state.warnings` is non-empty, and one when it returns to a success
state. Deduped in `seen.json` under `.replication.<id>` / `.cloudSync.<id>` by
the last decisive job state and a stable `failed` boolean; a `RUNNING`, `PENDING`
or blank poll carries both forward, so it cannot erase the signal. A failed
replication or cloud sync fetch leaves that half of `seen.json` untouched.
Snapshot tasks and scrub tasks carry no job and do not toast.

**Meta-cadence caching.** `/replication`, `/cloudsync`, `/pool/snapshottask` and
`/pool/scrub` join the meta cadence: a cold poll spends eleven requests and a
warm poll two. The cache holds only the wire fields the plugin consumes, with
the nested `state`/`job` reduced and the schedule whitelisted; replication SSH
credentials and encryption keys, cloud sync credentials and encryption secrets,
and job log excerpts never reach disk. `meta_is_stale` now requires all nine
sections.

**`truenasctl replication` / `cloudsync` / `snapshots` / `scrubs`.**
`NAME  DIRECTION  STATE  LAST RUN`, `NAME  DIRECTION  STATE  LAST RUN`,
`DATASET  STATE  LAST SNAPSHOT` and `POOL  ENABLED  THRESHOLD  SCHEDULE`, with
`unknown` for a value that was never learned and the section's failure sentence
instead of an empty table.

## Planned

Each of these is its own milestone and its own plan when it is reached.

**M5 Shares and network.** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
`/network/interface`; counts, sessions, link state.

**M6 Polish.** Menu completeness, the glossary behind the `?`, the preview
image, and the marketplace submission.

## Screenshot

`preview.png` is a live screenshot of the bar item and the Health popout taken
against a real TrueNAS (25.10.6) on 2026-09-13, during the milestone-1 live
verification. It shows the Default bar variant (`3` active alerts and `6%` of the
fullest pool) and real pool capacity. The disk serial in the alert text is
cropped out on purpose. Regenerate it only from a real run.

## Explicitly out of scope

- Creating or editing pools, datasets or shares. A popout is the wrong place for
  a storage wizard, and the NAS UI already does it well.
- Bulk destructive actions. Every write is one confirmed action; there is no
  "stop all apps".
- A shell on the NAS. `midclt` runs on the box and would mean SSH; this plugin
  speaks the HTTP API from the desktop.
