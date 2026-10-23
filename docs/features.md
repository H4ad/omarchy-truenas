# Features

The plugin is one poller plus three surfaces: a bar item, a summoned menu and a
popout. This file describes what each surface covers. The API behind it, and the
cadence it polls at, are in [truenas-api.md](truenas-api.md).

## The bar item

One widget, sixteen variants, chosen in Setup > Plugins. Every item shares the
one poll, and the item can be added to the bar more than once, each entry with
its own variant.

### Text variants

| Variant | What it prints |
| --- | --- |
| `Default` | the active alert count when anything is firing, otherwise the fullest pool's capacity |
| `Icon` | the glyph alone, tinted by the worst state |
| `Alerts` | the active alert count |
| `Capacity` | the fullest pool's used percent |
| `Pool` | the worst pool's status word |
| `Temp` | the hottest known disk's temperature |
| `Full` | alerts plus capacity |
| `Severity` | the worst two alert buckets, each tinted by its own level |
| `Down` | how many services and apps are not running |
| `Protection` | how many protection tasks have failed, are overdue or ran empty |
| `Uptime` | the time since the NAS booted |

A zero is the absence of a number, not a `0` on the bar. An unknown temperature
or a partial sum drops its body rather than printing a value the plugin cannot
vouch for.

### Chart variants

The charts draw in the icon slot.

| Variant | What it draws |
| --- | --- |
| `CapacityBar` | cells filled to the fullest pool's used percent, with the percent beside them |
| `Pools` | one square per pool, coloured by status |
| `DiskHeat` | one square per disk, coloured by its temperature band |
| `Sparkline` | a micro column chart of the fullest pool's recent capacity |

A chart with nothing to draw is empty, and the offline and unconfigured modes
still replace any variant with a plug or a cog.

### Custom

`Custom` composes any mix of the text pieces and charts above, switched on
individually in the manifest. The state glyph, the eleven text pieces and the
four charts draw in a fixed order with a separator between two pieces, each
dropped when it has nothing to say. One item can show, for example, a capacity
bar plus the pool status and the hottest disk.

### State override

An unreachable NAS overrides every variant with a plug and an unconfigured one
with a cog, so "nothing is wrong" and "I cannot tell" never look the same.
`hideWhenHealthy` hides the item when everything is healthy; the default keeps a
dimmed glyph, which is also how you tell the plugin is alive.

## The popout

Nine tabs.

**Health.** Connection state and last-poll age, hostname, version, uptime, pool
capacity and alert counts, broken down by severity.

**Pools.** A capacity bar per pool, status, allocated and free space, scrub state
and age, and vdev error counts when non-zero. A pool with no scrub data says "no
scrub on record" rather than inventing a date.

**Disks.** One card per disk: the device name and its temperature, tinted when
the reading is `critical` or `warning`, the model, a `type · size · pool · bus`
line, and the critical threshold when the poll reported one. A disk with no
reading says "temperature unknown", never `0 °C`. A failed details or
temperatures fetch says which one could not be read.

**Services.** One card per service: the name, its state and the enabled flag.
Start, stop and restart each go through a confirmation, because a misclick drops
connections. The inapplicable verb is not offered.

**Apps.** One card per app: the label, state, version and train, and an update
marker when the NAS reports one. Start, stop and redeploy are each confirmed;
redeploy covers the missing app restart route. A portal the poll reported opens
through the origin-gated link builder.

**Protection.** Replication, cloud sync, periodic snapshot and scrub tasks, with
the schedule and last job state for each, and run-now behind a confirmation.
Every row's state is tinted so a blank or running job is dim "unknown" and never
a failure. A task that is enabled and scheduled but has not finished a run
within its schedule plus a six hour grace is badged `OVERDUE` in the urgent
colour, and its card shows how long ago it last ran. The schedule bound is
conservative (hourly, daily, weekly, monthly), so a DST change or a 31-day month
cannot make a healthy task look late. A replication task that runs off its
periodic snapshot schedules instead of its own cron is judged on those
schedules. A scrub task also respects its threshold: a weekly schedule with a
35-day threshold is expected to stay quiet between scrubs. A task that has never
run starts its grace at the first poll that saw it, so a newly created task is
not overdue before its first run. A failed section says why and never renders as
a NAS with no protection tasks.

**Output checks.** An opt-in, per-task check that a successful run produced new
data. A checked task whose last successful run named a snapshot that is gone, or
whose snapshot wrote zero bytes, is badged `NO DATA` in the urgent colour, and
the card says `last run wrote 0 B`, `last snapshot missing` or `output not
checked`. The check is off by default because an incremental backup can
legitimately write nothing; mark only a task that should always produce data.
It covers periodic snapshot tasks and local replication targets. Cloud sync,
remote replication, scrub tasks, and a dataset that another task or a manual
snapshot also snapshots have no per-task delta and are not covered. `written` is
the space written since the previous snapshot on that dataset, so a shared
dataset is documented, not detected. A recursive task sums its children; the
name-wide query costs about 20 s and is capped at one per warm poll, while a
non-recursive task is one exact, cheap lookup. A missing snapshot on an
`allow_empty: false` task reads as empty, because zettarepl deletes the empty
snapshot after the run. A probe that failed, was skipped by the cap, or ran on a
cold poll is `unknown`: it keeps the previous badge and never reads as healthy.
A task that is failed or overdue is not checked; its badge keeps the stronger
signal.

**Shares.** A Shares block with SMB, NFS and iSCSI sub-lists, and a Network block
with one card per interface: the link state, negotiated media and every
`address/netmask`. Read-only.

**Alerts.** A row per alert: level, text, node, age, and dismiss or restore
where the alert allows it. Dismiss is confirmed.

**Config.** The bar item's settings plus a read-out of the NAS setup. The variant
is written back to `shell.json`; the API key is entered through a masked field,
written on stdin, and never shown back. `pollSeconds`, `timeoutSeconds`,
`insecureTLS` and `redact` are displayed and changed through `truenasctl config
set` or the controls here. The per-task output checks are toggled here and
written by `truenasctl expect`.

**Recording.** A `redact` level hides identifying values while you record or
screenshot: `network` (addresses, hostnames, the base URL), `names` (adds pools,
datasets, shares, apps, disks, interfaces and tasks) or `all` (adds the version
and hides free-form alert text). Each hidden value prints as a stable fake, so
the same pool is the same token everywhere. An address or a URL host written
inside prose is faked too, because that is where an alert lists the clients that
hit the API and those appear in no field. It is display only: the state and
credential files keep the real values and links still open the real NAS.

Every list view has a filter, and every data view names the not-configured state
separately, so a NAS with no key never looks like a NAS with nothing on it. A
failed fetch prints why; it never renders as an empty list.

## Notifications

A toast when an alert starts firing or clears, when a pool leaves or returns to
`ONLINE`, when a disk crosses into the warning or critical band and cools back,
when a service or app goes down or returns, when a replication or cloud sync
task fails or recovers, when an output check enters or leaves `NO DATA`, and
when any scheduled protection task becomes overdue
or runs again. Severity maps to urgency. Toasts are deduped in
`seen.json` by a stable key, so a network blip does not replay them as new. A
failed poll leaves `seen.json` untouched. A critical toast does not stick on
screen by default; that is opt-in through `notify.stickyCritical`.

A toast names the kind of event, not the thing: "A pool is DEGRADED", "A disk is
hot", "A service is STOPPED", with counts, temperatures and state transitions.
Alert text, pool, disk, service, app and task names, and the NAS's own error
words live in the state files and the panel instead, because a notification
argument is readable by other local users through `/proc`. Clicking a toast
summons the plugin's menu, which opens the popout with the details; the
configured base URL is never passed on a command line.

There are no SMART toasts: the API dropped SMART tests after 24.10 and
`smart/test/results` is `404` on 25.10.6.

## The CLI

`truenasctl` is the terminal side.

| Command | What it does |
| --- | --- |
| `login <url>` | read the key on stdin, write config and credentials |
| `logout` | remove the credentials |
| `test [-v]` | check the connection, naming each step with `-v` |
| `status` | connection, hostname, version, uptime, alert counts |
| `poll` | run one poll by hand |
| `alerts`, `pools`, `disks`, `services`, `apps` | one table each |
| `replication`, `cloudsync`, `snapshots`, `scrubs`, `shares`, `network` | one table each |
| `config list\|set\|set-key` | read and write the config, key on stdin |
| `open` | open the NAS UI in the browser |
| `purge` | delete the config, credentials and state |

`test -v` distinguishes TLS, no key, key rejected, forbidden, not JSON and timed
out rather than reporting one generic failure. A table never invents a value: an
unread field is `unknown`, and a failed section prints its failure sentence
instead of an empty table.

## Custom and multiple bar items

The manifest sets `allowMultiple`, so the widget can sit on the bar more than
once, each entry with its own variant. Every instance shares the one poller and
the one state file, so it is still one poll per machine and one notification per
event. Settings stay per item. Add another in Bar Settings, or:

```
omarchy bar set io.github.h4ad.truenas variant Temp --section right --index N
```

Two items with byte-identical settings are indistinguishable, so an in-panel
change lands on the first; give each a different variant, or use Bar Settings.

## Explicitly out of scope

- Creating or editing pools, datasets or shares. A popout is the wrong place for
  a storage wizard, and the NAS UI already does it well.
- Bulk destructive actions. Every write is one confirmed action; there is no
  "stop all apps".
- A shell on the NAS. `midclt` runs on the box and would mean SSH; this plugin
  speaks the HTTP API from the desktop.

## Screenshot

`preview.png` is the Health tab of the popout, taken against a real TrueNAS
25.10.6 at `redact: network`: the connection line, the system block, the pool
capacity bars and the alert counts. It is byte-identical to
`docs/screenshots/health.png`, and it is the image the marketplace shows as the
plugin card.

`docs/screenshots/` holds one capture per popout tab, and the README shows all
of them: Health alone, then a strip of the other eight. They were taken over IPC,
one `omarchy-shell ... view <tab>` call each, then the card cropped out of a
full-screen capture, because the panel is a full-screen layer surface and
`slurp` would mean nine manual drags.

`scripts/screenshot` opens the panel over IPC and captures a region you drag with
`slurp`; run it by hand on a real session to refresh the image. It is a desk
helper, not part of the installed tree.
