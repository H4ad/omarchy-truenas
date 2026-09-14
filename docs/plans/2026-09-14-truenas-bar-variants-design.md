# Bar variants design

Date: 2026-09-14. Scope: the bar item's selectable variants. Approved by the
owner, who asked for more useful bar options than the seven text variants.

## Problem

The bar item offers seven variants, all text: Default, Icon, Alerts, Capacity,
Pool, Temp, Full. There is no at-a-glance shape, no per-pool or per-disk view,
and no way to see a trend.

## Variants after this change (15)

Text variants, drawn through the existing segment renderer:

| Variant | Prints | Source |
| --- | --- | --- |
| Default, Icon, Alerts, Capacity, Pool, Temp, Full | unchanged | unchanged |
| Severity | one segment per non-empty alert bucket, worst two, e.g. `2▲ 1●`, each tinted by its bucket | `counts` |
| Down | the number of services plus apps not running, tinted; nothing when zero | `downServices`+`downApps` |
| Protection | the number of failed replication, cloud-sync, snapshot and scrub jobs, tinted; nothing when zero | `protectionStateRank` over the four lists |
| Uptime | `up 18h` | `system.uptimeSeconds` via the age formatter |

Chart variants, drawn with Rectangles in the icon slot (no Canvas):

| Variant | Draws | Source |
| --- | --- | --- |
| CapacityBar | N cells filled to the fullest pool's used percent, plus the percent | `capacityPct` |
| Pools | one small square per pool, coloured by status rank | `pools[].status` |
| DiskHeat | one small square per disk, coloured by its temperature band | `disks[].tempState` |
| Sparkline | a micro column chart of the fullest pool over the last samples | `history.json` |

## Rules (unchanged from the rest of the plugin)

- Unknown is blank, never `0` and never `0%`. A chart with nothing to draw is
  empty, not a zero-length bar.
- A failed section is empty, and the tooltip still names the plugin, not a value
  it did not get.
- Severity, not color, is the contract between `BarVariants.js` and the QML: the
  JS names a level and the widget maps it to the theme.
- `BarVariants.js` stays free of QML types and keeps every "what does the bar
  say" decision, so it stays node-testable. The widget passes plain data.

## History for the sparkline

The one new datum. `bin/truenas-poll` appends the fullest pool's used percent to
`~/.local/state/omarchy/truenas/history.json` on each poll:

```json
{ "capacityPct": [6, 6, null, 7, 7], "at": ["2026-09-14T12:00:00Z", "..."] }
```

- Capped at 60 samples, oldest dropped.
- `null` when capacity is unknown, so a gap stays a gap instead of a fake zero.
- Written atomically, the same way state.json is.
- Read by the widget through its own FileView; a missing or malformed file is an
  empty sparkline, never a crash.

## Rendering

- Text variants keep `segmentsFor` and the multi-colour Row path.
- `BarVariants.chartKind(variant)` returns `""` for text and `bar|dots|heat|spark`
  for a chart. `chartFor(variant, view)` returns the spec:
  - `{ kind:"bar", filled, total, label, severity }`
  - `{ kind:"dots", items:[{severity}] }`
  - `{ kind:"heat", items:[{severity}] }`
  - `{ kind:"spark", columns:[0..1|null], severity }`
- The widget renders each kind with a small Row of Rectangles (spark is a Row of
  thin columns) and sets `fixedWidth` from a hidden sizing twin, the same way the
  multi-colour text row already sizes itself.

## Sizes

- CapacityBar: 6 cells, 4px wide, 8px tall, 2px gap, then the percent text.
- Pools / DiskHeat: one 5px square per row, 2px gap, capped so a large NAS does
  not eat the bar (overflow collapses to a `+N` count in the tooltip).
- Sparkline: 40px wide, 10px tall, 30 columns max.

## Tests

- `tests/model.mjs`: `protectionFailures`, `downTotal`, `capacityBarFill`,
  `sparkColumns`, and the pool/disk dot severity mapping.
- `tests/bar-variants.mjs`: every new variant, empty input, unknown input, and
  the override modes still winning over a chart variant.
- `tests/cases/10-poll.sh` and `13-meta.sh`: history append, cap, null gap, and
  no history write when the poll fails.
- `tests/cases/17-qml-structure.sh`: the chart renderer path exists and the
  manifest lists every variant the JS resolves.

## Documentation

`docs/03-features.md` gains a section, `README.md` names the new options, and
`manifest.json` lists all 15 with descriptions.
