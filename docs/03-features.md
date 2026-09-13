# Features

What milestone 1 ships, and what the design defers. The split is the design's:
bar value against cost (API unknowns plus QML work). The design is
[plans/2026-09-13-truenas-plugin-design.md](plans/2026-09-13-truenas-plugin-design.md);
the task-by-task version is
[plans/2026-09-13-truenas-milestone-1.md](plans/2026-09-13-truenas-milestone-1.md).
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
`restore` where the alert allows it. The write verbs are planned, not yet
implemented in this build (there is no `bin/truenas-api` yet): when they land,
writes will go through it behind a confirmation, and the panel will re-poll with
`--force-meta` before it believes them.

**Config view.** The bar settings plus the credentials flow: `pollSeconds`,
`timeoutSeconds`, `insecureTLS` and the API key, the key entered through a
masked `SecretField` and written on stdin, never shown back.

**Notifications.** A toast when an alert starts firing, one when it clears, and
one when a pool leaves or returns to `ONLINE`. Deduped in `seen.json` by a
stable key so a network blip does not replay every alert as new; severity maps
to urgency; a critical toast never sticks by default. A failed poll leaves
`seen.json` untouched.

**`truenasctl`.** The terminal side: `login` (key on stdin, stored at mode 600),
`logout`, `test [-v]` (step by step, distinguishing TLS / no key / key rejected
/ forbidden / not JSON / timed out), `status`, `alerts`, `pools`, `poll`,
`config list|set|set-key`, `open` and `purge`.

**Menu.** A `TrueNAS` summon menu that reaches the popout, each view, poll-now,
notification pause/resume and the NAS UI.

## Planned

Each of these is its own milestone and its own plan when it is reached.

**M2 Disks.** `/api/v2.0/disk`, `/disk/temperatures`, `/smart/test/results`; a
Disks view, and temperature/SMART notifications.

**M3 Apps and services.** `/api/v2.0/service`, `/app`; state, and
start/stop/restart writes behind confirmation.

**M4 Protection.** `/api/v2.0/replication`, `/cloudsync`, `/pool/snapshottask`,
`/pool/scrub`; states, last run, and run-now writes.

**M5 Shares and network.** `/sharing/{smb,nfs,iscsi,webdav}`, `/smb/status`,
`/network/interface`; counts, sessions, link state.

**M6 Polish.** Menu completeness, the glossary behind the `?`, the preview
image, and the marketplace submission.

## Screenshot

`preview.png` does not exist yet. It is a live screenshot of the finished bar
item and popout, pending verification against a real NAS (Task 20, blocked on an
API key). Do not add a placeholder: a doctored preview is worse than none.

## Explicitly out of scope

- Creating or editing pools, datasets or shares. A popout is the wrong place for
  a storage wizard, and the NAS UI already does it well.
- Bulk destructive actions. Every write is one confirmed action; there is no
  "stop all apps".
- A shell on the NAS. `midclt` runs on the box and would mean SSH; this plugin
  speaks the HTTP API from the desktop.
