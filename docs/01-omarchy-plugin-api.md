# How Omarchy plugins work

Sources: <https://omarchyplugins.com/develop.html>, plus the installed shell at
`/usr/share/omarchy/shell` (read directly, so the notes below are verified
against this machine rather than the docs alone).

## Runtime shape

`omarchy-shell` is one long-running [Quickshell](https://quickshell.org/) (QML)
process per graphical session. The bar, panels, overlays and background switcher
are all plugins inside it. A plugin is a directory with `manifest.json` plus the
QML files its `entryPoints` name.

- Third-party plugins live in `~/.config/omarchy/plugins/<manifest-id>/`.
- Saving any file under that tree hot-reloads plugin code.
- `omarchy-shell shell rescanPlugins` forces a rescan.
- Plugins run unsandboxed, in-process, with full user permissions. There is no
  capability system. Whatever we ship, the user is running as themselves.

## Manifest

Required: `schemaVersion: 1`, `id`, `name`, `version`, `author`, `license`,
`description`, `kinds`, `entryPoints`. Validation (`omarchy plugin validate`)
checks that JSON parses, every declared kind has an entry point, every
referenced file exists at a safe relative path, the id does not start with
`omarchy.`, and the folder holds no symlinks.

Kinds and their entry point keys:

| Kind | Key | Meaning |
| --- | --- | --- |
| `bar-widget` | `barWidget` | item the active bar drops into a section |
| `panel` | `panel` | floating surface |
| `overlay` | `overlay` | fullscreen surface |
| `menu` | `menu` | summoned menu surface |
| `service` | `service` | headless singleton, no UI |
| `bar` | `bar` | full bar replacement, one active at a time |

A `bar-widget` adds a `barWidget` object: `displayName`, `description`,
`category`, `aliases`, `allowMultiple`, `defaultSection`, `defaults`, and a
`schema` array. `schema` entries are what Omarchy renders in Setup > Plugins as
the settings form. Types seen in the wild: `string`, `integer` (with
`min`/`max`/`step`), `boolean`, `enum` (with `options`). Each entry takes
`key`, `label`, `description`, `defaultValue`.

Reference manifests worth copying from, all installed here:
`~/.config/omarchy/plugins/jankeesvw.notification-center/manifest.json` (rich
schema, badge enum), `io.github.kristoferlund.webcam` (bar widget plus panel),
`/usr/share/omarchy/shell/plugins/services/battery/manifest.json` (service).

## What the host injects

`Ui/BarWidget.qml` is the base every bar widget extends. The host sets exactly
three properties on it:

- `bar` (the host Bar instance: `bar.run(cmd)`, `bar.vertical`, `bar.barSize`,
  `bar.moduleWidgets(id)`)
- `moduleName` (canonical widget id)
- `settings` (the inline entry from `shell.json`, read with `setting(key, fallback)`)

Plus two helpers: `setting(name, fallback)` and `broadcast(method)`.

`broadcast` exists because **a bar surface is instantiated per monitor**, so a
widget with two displays is two live objects. That is the single most important
constraint for us: a naive `Timer` in the widget polls once per monitor and
notifies once per monitor.

Services are created in `shell.qml` `ensureService()` and get `omarchyPath`,
`shell`, `manifest`, `barWidgetRegistry`, `pluginRegistry` injected. They do
**not** get `settings`. Panels paired with a service get `item.service` set
(`shell.qml:637`), but bar widgets do not (`plugins/bar/Bar.qml:385` only
injects `settings`). So a bar widget cannot reach its own plugin's service
object directly.

## Enable semantics

`shell.json` is the one user config file. A third-party plugin is enabled iff
its id appears in it. `PluginRegistry.setEnabled` (`services/PluginRegistry.qml:455`)
puts a `bar-widget` into `bar.layout.<section>` and anything else into
`plugins[]`. `shell.qml:_syncServices` then loads every installed plugin that
declares kind `service` and passes `pluginRegistry.isEnabled(id)`, and
`isEnabled` is satisfied by the layout entry. **A plugin declaring both
`bar-widget` and `service` therefore gets its service loaded off the bar layout
entry alone.** That is the combination this plugin wants.

Per-widget settings are inline on the layout entry, no sub-object:

```json
{ "id": "io.github.h4ad.truenas", "variant": "Default", "panelWidth": 460 }
```

## Building blocks we will use

From `/usr/share/omarchy/shell/Ui/`: `BarIconButton`, `BarIndicator`,
`KeyboardPanel`, `PanelKeyCatcher`, `PanelSectionHeader`, `PanelSeparator`,
`PanelActionButton`, `PanelToolTip`, `Button`, `ButtonGroup`, `TextField`,
`NumberField`, `Toggle`, `ToggleSwitch`, `Dropdown`, `SearchableDropdown`,
`ConfirmDialog`, `PopupCard`. From `Commons/`: `Style`, `Color`, `Util`.

Contracts to honor (from the docs and from `plugins/panels/weather/BarWidget.qml`):

- BarWidget: expose `opened` and `popoutSwitchClosing` as readonly bools, and
  `open()`, `close()`, `toggle()`, `closeForPopoutSwitch()`. Load the panel in a
  `Loader`, call an `injectPanel()` on `onBarChanged`, `onSettingsChanged`, and
  `onLoaded` plus a `Qt.callLater` repeat.
- Panel: `manageIpc: false` when hosted by a widget, `anchorItem`, `hostWidget`,
  wrap content in `KeyboardPanel` plus `PanelKeyCatcher` for Escape and tab
  switching.

## HTTP, subprocesses, timers, persistence

There is no HTTP client in the shell. Every network call in the tree is
`Quickshell.Io.Process` running `curl` with a `StdioCollector`, for example
`plugins/panels/weather/Panel.qml:333` running
`["curl","-fsS","--max-time","10","https://wttr.in/..."]`. Polling is a plain
`Timer { interval; running; repeat; triggeredOnStart }`
(`plugins/bar/widgets/SystemUpdate.qml`, 6h; `plugins/services/battery/Service.qml`, 30s).

Persistence has two flavors:

- `PersistentProperties { reloadableId: "..." }` for small state that must
  survive a hot reload (battery uses it for "already warned").
- `FileView { path; watchChanges: true; onLoaded: ...; atomicWrites: true }` for
  files, including cross-process state. This is how a widget can watch a file a
  helper script writes.

## Notifications

`omarchy-notification-send` is on `PATH`. It is not a wrapper over
`notify-send`: the installed binary calls `busctl --user call
org.freedesktop.Notifications /org/freedesktop/Notifications
org.freedesktop.Notifications Notify` directly, and its comments say "never
notify-send", because `busctl` takes each value as one typed D-Bus parameter
instead of reinterpreting a headline as an option or hint. Options come first,
then the positionals, then `--exec` last, with the command as separate argv
words rather than one quoted string:

```
omarchy-notification-send [--app-name <name>] [-g <glyph>]
                          [-u low|normal|critical] [-i <icon>] [-t <ms>]
                          [-r <id>] [-p] [--image <path-or-uri>]
                          <headline> [description] [--exec <program> [args...]]
```

It tags the toast with `-a <app-name>` so it pops through do-not-disturb, and
`--exec` records a click command that the shell runs itself. Note the deliberate
design in the notification stack: the shell does not run a command that came in
on the notification, because a stored notification command is an attacker's
command waiting for a click. We apply the same rule to URLs coming from the
TrueNAS API (see [02-truenas-api.md](02-truenas-api.md), and the origin gate in
`Links.js`).

## Dev loop

```bash
omarchy plugin clone omarchy.clock --edit          # scaffold from a built-in
omarchy plugin validate ~/.config/omarchy/plugins/<id>
# Qt 6 by path: the bare qmllint on Arch is Qt 5, which exits 255 with no
# message at all on the typed function signature an IpcHandler needs.
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" <id>/BarWidget.qml <id>/Panel.qml
omarchy plugin list --json | jq '.[] | select(.id == "<id>")'
omarchy-shell shell rescanPlugins
omarchy-shell shell summon <id> '{}'
omarchy-shell shell hide <id>
qs log -p "$OMARCHY_PATH/shell" --tail 100         # QML errors land here
```

Install path for users, once published: a plugin is just a git repo with a
manifest at its root.

```bash
omarchy plugin add https://github.com/h4ad/omarchy-truenas.git --enable
```

Before release: replace any cloned id, drop `omarchy.clonedFrom`, add `README.md`,
`LICENSE`, `preview.png`, then submit to the marketplace issue form.
