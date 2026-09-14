# TrueNAS plugin for Omarchy — design

Date: 2026-09-13
Status: approved, ready for implementation planning
Plugin id: `io.github.h4ad.truenas`
Repo: `~/Projects/omarchy-truenas` (WIP to `hub`, finished work to GitHub)

## Problem

The NAS is the one machine whose failure is silent until it is expensive: a pool
degrades, a disk runs hot, a replication task stops landing, an app crashes, and
nothing tells you until you happen to open the TrueNAS web UI. The bar should
answer *is the NAS healthy right now* at a glance, and the popout should answer
*what changed, and why*.

## Scope

Single NAS. Full control (reads plus writes). One instance, one API key.
Sections in v1: System, Pools, Alerts, Disks, Apps & Services, Protection
(replication / cloud-sync / snapshots / scrub), Shares & Network, Jobs.
Notifications for: new/cleared alerts, pool state changes, task finished,
disk temp/SMART, app/service down, update available.

## References

Modelled on `~/Projects/omarchy-signoz` for architecture and its
`docs/01-omarchy-plugin-api.md` and `docs/11-pitfalls.md`. `robzolkos.github`
is the simpler reference for a bar-widget-only plugin; we deliberately take the
SigNoz split instead.

## Architecture

One `service` singleton per shell owns the poll and the notifications. The bar
widget is a read-only watcher of a state file. That split exists because a bar
surface is instantiated once **per monitor**: a `Timer` in the widget would poll
once per screen and notify once per screen.

```
 desktop session          omarchy-shell (one process per session)
 +---------------------------------------------------------------+
 |  bar monitor 1 -+                                             |
 |  bar monitor 2 -+---> BarWidget.qml  FileView(ro) --+         |
 |  bar monitor N -+     never polls                    |         |
 |                                                      v         |
 |                    Service.qml (singleton) --> state.json      |
 |                        | Timer pollSeconds                     |
 |                        v                                       |
 |                    Process: bin/truenas-poll                   |
 +------------------------+--------------------------------------+
                          | curl + jq; Bearer key on stdin, never argv
                          v
               https://<nas>:<port>/api/v2.0/...
```

Writes are the panel's job, through one depth-one process queue, followed by a
forced re-poll:

```
click [dismiss / start / run] -> ConfirmAction (inside PanelKeyCatcher)
    -> truenas-api POST -> refresh-after-write (truenas-poll --force-meta)
```

## Data access

Primary: REST `/api/v2.0` (`Authorization: Bearer <key>`), curl + jq, matching
the SigNoz helper style. Verified live on this box: `https://nas.example:4433`
returns `401 Unauthorized` (not 404) for `/api/v2.0/system/version`, and the
certificate is self-signed (iXsystems, CN=localhost).

REST is deprecated starting TrueNAS 25.04 and slated for removal. So every call
goes through one shim, `bin/truenas-lib.sh` `tn_call`, which records the dialect
(`rest-v2.0` for now) from a cached `system.info` probe. Migrating to JSON-RPC
over `/api/current` later is a change to that one function, not a rewrite.

Rejected: WS-only (needs a websocket client not guaranteed on the desktop);
`midclt` (runs on the NAS, not the desktop, and would mean SSH).

### TLS

TrueNAS revokes API keys sent over plain HTTP, and self-signed certs are the
norm. `insecureTLS` is an explicit boolean in `config.json`, default **false**.
`truenasctl login` inspects the certificate, and when it is self-signed it says
so and tells the user to set `insecureTLS` — it is never quietly enabled.

### Rate limiting

The API allows roughly 20 auth / unauthenticated requests per 60 s, then a
10-minute cooldown. One poll therefore never hits every endpoint. Two cadences:

```
every pollSeconds (floor 15, default 30):
    alert/list · pool · core/get_jobs
every ~300s (META_MAX_AGE):
    system/info · disk · disk/temperatures · smart/test/results
    service · app · replication · cloudsync · pool/snapshottask
    pool/scrub · sharing/{smb,nfs,iscsi,webdav} · smb/status
    network/interface · update
```

Static answers live in `meta.json` beside the poll, exactly as SigNoz caches
`/service_accounts/me` and `/rules`.

## Files

```
manifest.json          Schema for the bar widget settings.
Service.qml            Singleton: Timer + Process(truenas-poll), IpcHandler "truenas".
BarWidget.qml          Read-only: FileView on state.json, bar variants, panel Loader.
Panel.qml              Popout shell, tabs, write queue (apiQueue/pumpApi).
Menu.qml               Keybind summon menu.
Model.js               .pragma library. All pure rules; no QML types.
BarVariants.js         Bar segment definitions per variant.
Links.js               Origin-checked URL building (our base only).
Search.js              List filtering.
Views/                 Health Pools Alerts Disks Apps Protection Shares Config
Ui/                    Card Chip FilterField SecretField ConfirmAction CapacityBar
                       ScrollIndicator Sparkline HelpModal VariantPicker
bin/truenas-lib.sh     Config load, credential resolve, tn_call, classify.
bin/truenas-poll       Read path: poll, normalize, write state.json, notify.
bin/truenas-api        Write path: one verb per call, JSON on stdout.
bin/truenasctl         login / logout / test / status / alerts / pools / disks /
                       apps / services / protect / shares / dismiss / open / purge
share/normalize.jq     Version-variable API shapes -> one stable schema.
docs/plans/            This document and the implementation plan.
tests/                 run.sh + cases/*.sh (bash) + *.mjs (node) + qml6 runtime.
scripts/dev-install    Copy the tree into ~/.config/omarchy/plugins and restart.
```

## state.json

```json
{
  "schema": 1,
  "updatedAt": "2026-09-13T22:00:00Z",
  "pollSeconds": 30,
  "connection": {
    "ok": true, "httpStatus": 200, "latencyMs": 42,
    "error": null, "message": null,
    "consecutiveFailures": 0, "lastOkAt": "...",
    "version": "25.04.2", "dialect": "rest-v2.0"
  },
  "system":   { "hostname": "", "version": "", "uptimeSeconds": 0, "cores": 0,
                "physmem": 0, "loadavg": [], "updateAvailable": false },
  "counts":   { "critical": 0, "error": 0, "warning": 0, "notice": 0,
                "info": 0, "total": 0, "dismissed": 0 },
  "alerts":   [ { "uuid": "", "level": "", "text": "", "formatted": "",
                  "node": "", "datetime": "", "dismissed": false,
                  "dismissable": true } ],
  "pools":    [ { "name": "", "status": "", "healthy": true, "size": 0,
                  "allocated": 0, "free": 0, "usedPct": 0,
                  "scan": { }, "vdevErrors": { } } ],
  "disks":    [ { "name": "", "model": "", "type": "", "size": 0, "pool": "",
                  "bus": "", "tempC": null, "tempCriticalC": null,
                  "tempState": "unknown" } ],
  "services": [ { "id": "", "service": "", "state": "", "enable": false } ],
  "apps":     [ { "id": "", "name": "", "state": "" } ],
  "replication": [ ], "cloudsync": [ ], "snapshots": [ ],
  "shares":   { "smb": 0, "nfs": 0, "iscsi": 0, "webdav": 0 },
  "sessions": { "smb": [ ] },
  "network":  [ { "name": "", "linkState": "", "addresses": [ ] } ],
  "jobs":     [ { "id": 0, "method": "", "state": "", "percent": 0,
                  "description": "" } ],
  "warnings": [ { "section": "", "error": "", "message": "" } ]
}
```

`disks[].tempState` is computed once, in `share/normalize.jq`, and read by both
the bash notifier and the QML views: `unknown` when either the temperature or
its critical threshold is missing, `critical` at `tempC >= tempCriticalC`,
`warning` from ten degrees below critical, otherwise `ok`.

`warnings` is the partial-failure channel: if the disk call failed and pools
succeeded, pools render and the Disks view prints the reason. `connection.error`
with no answer never becomes a zero count.

## Bar variants

```
Icon        glyph alone, tinted by worst state
Alerts      active alert count
Capacity    fullest pool percentage
Pool        worst pool status word
Temp        hottest disk
Full        alerts + capacity
Quiet       dimmed when all green (the "I am alive" proof)
```

M1 shipped `Default`, `Icon`, `Alerts`, `Capacity`, `Pool` and `Full`; M2 adds
`Temp`, the hottest disk's temperature (blank when no disk reports one). `Quiet`
remains deferred, and the manifest carries no option for it yet.

Offline / unconfigured still overrides every variant with a plug or cog glyph,
so "nothing is wrong" and "I cannot tell" never look the same.

## Writes (full control)

Dismiss alert · restore alert · start/stop/restart service · start/stop/redeploy
app · run scrub · run replication · run cloud-sync · run snapshot task.

Guardrails: every write is one queued `Process`; destructive ones pass through a
`ConfirmAction` declared inside `PanelKeyCatcher` (a dialog at root scope
renders nowhere — see pitfalls); after any write the poll runs with
`--force-meta` before the panel believes anything; and the panel reads its write
back rather than trusting the verb's stdout.

## Notifications

Deduped in `seen.json`, namespaced by stable key:

| Event | Key | Urgency |
| --- | --- | --- |
| Alert new / cleared | `alert:<uuid>` | critical/error urgent, warning normal |
| Pool state change | `pool:<name>:<status>` | worsening urgent, recovery low |
| Scrub / replication / cloudsync finished | `scrub:<pool>:<start>`, `<task>:<id>:<state>` | failure urgent, success low |
| Disk temp | `disk:<name>:temp` | warning/critical normal, cooled low |
| App / service down | `app:<id>:state`, `service:<id>:state` | normal |
| Update available | `update:<version>` | low |

There is no `disk:<name>:smart` row: SMART test results are not available on
25.04+ (`GET /api/v2.0/smart/test/results` is `404` on the live 25.10.6, and the
API reference lists no `smart.*` method at all -- SMART tests were dropped after
24.10), so M2 ships temperature toasts only.

A failed poll leaves `seen.json` untouched, so a network blip does not replay
every alert as new on recovery. Notification levels map the way SigNoz maps
them: critical never sticks by default.

## Correctness rules (from docs/11-pitfalls)

1. Never turn "I cannot tell" into a number or a dash that means loading.
2. `arrayLike`, never `Array.isArray`, across the QML boundary.
3. `.pragma library` is line 1 of `Model.js`; cached fields carry a version
   counter and every binding reads `(panel.version, Model.getter(...))`.
4. One poll process; `Process` is depth-one; links use `Quickshell.execDetached`.
5. argv only, never a shell string; API key through curl stdin config, never
   argv, `ps`, `shell.json`, or a log line.
6. A prefix test is not an origin test: `Links.js` requires the character after
   the base to end the host.
7. `qmllint` by `/usr/lib/qt6/bin/qmllint`; restart the shell (compiled QML is
   cached per URL); read the shell log first when a click does nothing.
8. A config field must be added in all of `sz_load_config`, `config set`,
   `config list` in one change.

## Secrets

```
~/.config/omarchy/truenas/config.json    baseUrl, pollSeconds, insecureTLS,
                                         timeoutSeconds, notify{}, apiKeyCommand
~/.config/omarchy/truenas/credentials    TRUENAS_API_KEY=<key>   mode 600
~/.local/state/omarchy/truenas/          state.json, seen.json, meta.json
```

Key resolution order: `apiKeyCommand` (never stored), then `apiKeyFile`, then
`TRUENAS_API_KEY` in the credentials file, then a bare key. Files with any group
or other bit set are refused with `credentials_permissions`. `truenasctl login`
reads the key on stdin; `config list` reports that a key is set, never its value;
`purge` removes config, key and state.

## Testing

- `tests/run.sh` sources `cases/*.sh` into one shell; a suite named in the loop
  but missing fails instead of skipping.
- `tests/*.mjs` load `Model.js` / `Links.js` under node with `.pragma` stripped.
- `17-qml-structure.sh`: duplicate function names, `.pragma` on line 1, every
  MouseArea accepts hover; `18-qml-runtime.sh`: `qml6` cache-sharing check.
- Fixtures are sanitized snapshots of the real box plus synthetic failure
  states (degraded pool, faulted disk, crashed app, unreachable host, 401).
  No serial numbers, no keys, no hostnames committed.

## Milestones

1. Skeleton, manifest, poll, config/credentials, `truenasctl test`, Health,
   Pools, Alerts, bar variants, alert + pool notifications.
2. Disks + temp/SMART.
3. Apps + Services + writes.
4. Protection + run-now writes.
5. Shares + Network.
6. Menu, help/glossary, README, preview image, release.

Each milestone ends usable and is committed on its own.

## Open questions / risks

- Exact endpoint shapes vary by version; every shape is normalized in
  `share/normalize.jq` and probed by `truenasctl test` rather than assumed.
- `disk/temperatures` — resolved: POST-only, the parameter is `name` (singular,
  an array), and the answer is `[tempC, criticalC]` per disk, or a bare number
  when the disk reports no threshold; normalize both. Verified on the live
  25.10.6, see `docs/02-truenas-api.md`.
- REST removal: mitigated by the `tn_call` shim.
- Full-control writes: a misclick restarts a service. Mitigated by confirmation,
  a single-write queue, and read-after-write. No bulk destructive action without
  the armed-confirm pattern.
- TrueNAS rate limit: enforced by the two-cadence design and a poll floor.
