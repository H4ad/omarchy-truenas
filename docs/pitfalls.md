# Pitfalls

Everything in this file cost real time at least once, on this plugin or the one
it was modelled on. Most of it was found by a test or a live run rather than by
reading, and a few were found only because somebody went back and checked a
claim that had already been written down as true.

Each entry says what it looks like when it happens, because that is the part that
is hard to recognise the second time.

## The rule the rest of this file serves

**Never turn "I cannot tell" into a number.** An instance that did not answer
contributes no zero. A card whose fetch failed does not show the dash that means
"still loading". A partial sum says it is partial. Most of the correctness bugs
below are one of these three wearing a different hat, which is why the rule is
worth stating separately from them.

## Silent failures

These are the expensive ones. Nothing errors, nothing is red, and the wrong
answer looks exactly like the right one.

### A count that should be "unknown"

`Array.isArray` is **false** for the QVariantList sequence wrapper that a QML
`var` property hands to a plain JavaScript function. It iterates like an array
and is not one.

Looks like: every severity count reads zero, which is indistinguishable from a
healthy system with nothing firing.

Do: use the `arrayLike` helper in `Model.js`, never `Array.isArray`, on anything
that crossed the QML boundary. There are regression assertions on every site.

### jq's `//` is not a default

`//` is the alternative operator and treats `false` exactly like absent, so
`(.enabled // true)` is **true** for something explicitly turned off.

Looks like: a disabled instance still being polled, or `insecureTLS` turning
itself back on for a config that says `false`.

Do: compare explicitly, `.enabled != false`. Same for anything where `false` is
meaningful rather than missing. `tn_load_config` echoes `insecureTLS` and the
three `notify` booleans through an explicit `type == "boolean"` guard for this
reason.

### A test suite that is registered and absent

`tests/run.sh` skips a suite whose file does not exist. A suite named in the loop
but not yet written passes by not running.

Looks like: `all suites green` with one suite's assertions never executed. The
`links` suite sat in this state.

Do: the loop now fails on a missing named suite instead of continuing. If you add
a suite name, add the file in the same change.

### An empty file parses fine

`jq .` on an empty file exits 0 and prints nothing. So does a `jq` filter over
nothing.

Do: check the file has content before believing a successful parse. `tn_read_json`
owns this: it falls back to `{}` for a missing, empty or unparsable file, so a
later `--argjson` cannot fail on an empty string.

### A new config field that `config list` does not include

`cmd_config_list` builds a new object from explicit fields. A field added to the
config schema but not to this jq query is missing from the UI's view of the
config, so the UI cannot read it.

Looks like: setting a field via `config set` works, `jq` on the file shows the
value, and the UI shows nothing or the fallback. Editing the field in the UI then
fails with "could not update", because the write check compares the UI's
(undefined) value against the value just written.

Do: when adding a config field, update every reader in one change: `tn_load_config`
in `bin/truenas-lib.sh` (so the poller sees it), `cmd_config_set` in
`bin/truenasctl` (so the CLI can write it) and `cmd_config_list` (so the UI can
read it back). Add a test that sets the field and checks both `config list` output
and the raw file.

## Shell and jq

### An apostrophe inside a single-quoted jq program

A comment containing `jq's` inside a single-quoted jq program in bash closes the
quote and breaks the entire file. This once took out 186 assertions at a stroke.

Looks like: `syntax error near unexpected token '('` from a line nowhere near the
comment.

Do: run `bash -n <file>` on every shell file you touch. For long programs prefer
a quoted heredoc fed to `jq -f /dev/stdin`, where an apostrophe cannot end
anything.

### ARG_MAX

`--argjson` with a large payload hits `ARG_MAX`.

Do: `--slurpfile`, or make the payload jq's input file rather than an argument.

### Test cases share one shell

`tests/cases/*.sh` are sourced in name order into **one** shell and share the
`PASS` and `FAIL` counters.

Do: never reset them, and never put a check on the right-hand side of a pipe or
inside a subshell, where the increment is lost. The same applies to any helper
that `export`s a variable the command under test reads: on the right of a pipe
the export lands in the subshell and the override never arrives, so the test
silently reads the user's real config.

## QML

### Two functions with one name kill the whole file

Declaring the same function twice in one QML object is a compile error, not a
shadow and not a warning-level complaint. The object is never created, so a
`Loader` pointing at it leaves `item` null and every call through that item is a
no-op.

Looks like: the bar item paints normally, the tooltip is right, and clicking it
does nothing at all. The widget compiled fine; it was `root.toggle()` reaching a
null `panelLoader.item`. Nothing is red anywhere on screen, and the only trace is
one line in the shell log:

```
WARN scene: file://…/io.github.h4ad.truenas/Panel.qml[416:12]: Duplicate method name
```

Confirmed against Qt 6 rather than assumed: `qml6` on a file with two same-name
functions exits 2 and creates nothing; the same file with one exits 0. `qmllint`
does not report it, under either Qt.

Do: read the shell log first when a click does nothing, because a dead panel and
a panel that opens off-screen look identical from the bar. A grep catches the
whole class before a restart does:

```bash
for f in $(git ls-files '*.qml'); do
  grep -oP '^  function \K\w+' "$f" | sort | uniq -d | sed "s|^|$f: duplicate |"
done
```

Two-space indent only, so root-scope functions are compared with each other and a
nested `IpcHandler`'s `open()` is not a false positive.

### A dialog declared where nothing is drawn

`BarWidget.qml` loads `Panel.qml` into a `Loader`, and the panel you can see is a
separate layer-shell window that `KeyboardPanel` creates. A visual child declared
at `Panel.qml`'s **root scope** is a sibling of that window rather than a child of
it, and renders nowhere: `anchors.fill: parent` fills an invisible zero-sized
item inside the bar.

Looks like: a control does nothing. The handler sets `opened = true`, the dialog
is asked for, no dialog appears, no request is sent, and nothing is red. `opened`
then stays true for the rest of the session.

Do: declare anything visual inside the `PanelKeyCatcher`, which is inside the
panel window, and raise it with `z`. `Ui/ConfirmAction.qml` and `Ui/HelpModal.qml`
both carry this note and are both declared inside the catcher.

And a dialog there cannot be answered from the keyboard by itself:
`PanelKeyCatcher` owns `Keys.onPressed` for the whole panel, so a child's
`handleKey` is never reached. Drive it from the catcher's `onCloseRequested`,
`onReturnRequested` and `onMoveRequested` instead.

### qmllint exits 255 with no message

The bare `qmllint` on this machine is **Qt 5**, which exits 255 with nothing on
stdout or stderr when it meets a typed function signature (`function ping(): void`),
and that is exactly what an `IpcHandler` requires.

The cause was believed for two rounds to be `IpcHandler` itself, or passing two
files at once. Both were wrong.

Do: use `/usr/lib/qt6/bin/qmllint`. It takes the whole repo in one invocation and
reports real errors with a message.

A stray brace produces the same silent 255 under Qt 5. If Qt 6 is unavailable and
lint goes quiet, count braces.

### A callback that outlives its view

The panel's process queue outlives a view. Switching tab while a write is in
flight has the `Loader` destroy the view, and the queued callback then runs
against a destroyed object where **every property read throws**.

Looks like: `TypeError: Cannot read property 'x' of null` in the shell log, on
every such switch, with nothing wrong on screen. Nothing in CI catches it, because
nothing in CI runs QML.

Do: `if (!root) return` at the top of every queued callback, and guard the
one-liners as `if (root) root.something()`.

### A scrim that does not accept hover is not a scrim

A `MouseArea` blocks presses whether or not it is `hoverEnabled`, and blocks hover
only if it is. So a full-screen dismissal scrim written the obvious way,
`MouseArea { anchors.fill: parent; onClicked: close() }`, stops every click and
lets every hover through to whatever it is covering.

Looks like: the panel behind an open sheet keeps hovering. Its rows highlight
under a scrim nobody can click, and because `PanelToolTip` is a
`QtQuick.Controls` `ToolTip`, which is a `Popup` drawn in the window's own overlay
rather than in the item tree, the tooltip of a card hidden behind the sheet is
drawn on top of the sheet. It reads as the sheet failing to render over the panel,
which sends you looking at `z` and at stacking order, where there is nothing
wrong.

Do: `hoverEnabled: true` on any MouseArea whose job is to cover something. Add
`WheelHandler { onWheel: function(event) { event.accepted = true } }` beside it,
because MouseArea does not handle wheel at all and the panel body is a
`Flickable`. `Ui/HelpModal.qml` does both, and `tests/cases/17-qml-structure.sh`
counts every MouseArea in that file against the number that accept hover.

### Overlapping mouse areas

A later-declared `MouseArea` wins the press. A row-wide handler declared after a
control inside the row swallows that control's clicks.

Looks like: a control that visibly highlights on hover and does nothing when
clicked.

Do: give the inner control `z: 1`, or declare it after.

### Layout

A `Row` skips invisible children, so an all-invisible `Row` collapses to zero
height and takes its spacing with it. Anchors are not allowed on `Row` children.

### An imported JS file without `.pragma library` is copied per importer

A `.js` file imported by QML is instantiated once **per importing component**
unless its first line is `.pragma library`. Without the directive, state written
by `BarWidget.qml` goes into BarWidget's private copy, and every view reads its
own copy, which nothing ever filled.

Looks like: a cache that updates in the component that wrote it and stays stale
everywhere else, across restarts, no matter how many version counters are added,
because the cache being read is not the cache being written.

Do: keep `.pragma library` as the first line of `Model.js`. A library script has
no component context, so it must never touch QML: no ids, no signals, no `parent`.
Node loads the same file with `new Function`, and `.pragma` is not JavaScript, so
every `tests/*.mjs` loader strips `/^\.(pragma|import)\b.*$/gm` before evaluating.

Checked by `tests/cases/17-qml-structure.sh` (the directive is line one) and
`tests/cases/18-qml-runtime.sh`, which runs two throwaway components under `qml6`
and asserts the reader sees what the writer stored.

### One Process cannot launch two long-lived children

`Process` starts nothing while its previous child is alive.
`startProcessIfReady` returns early on `this->process != nullptr`
(quickshell `src/io/process.cpp:181`), and `setCommand` only stores the new argv
before calling it again. So one shared `Process`, reused per click, is a queue of
depth one.

`xdg-open` is exactly such a child. The shell's environment carries no `BROWSER`,
so `xdg-open` runs Chrome itself and waits on the browser it launched, which means
the child lives as long as the window does.

Looks like: the first link opens, every later one does nothing, and nothing is red
and nothing is logged. Then the stale one fires when the browser finally quits,
opening whichever URL was set last, minutes after the click that set it.

Do: `Quickshell.execDetached(["xdg-open", safe])`. It holds no handle, so it has
nothing to be busy with, and the argv form still keeps a shell out of it. Only
reach for a `Process` when the output or the exit code is wanted. A `Process` is
right for a child that exits on its own, which is what `truenas-poll` does.

### The shell caches compiled QML per URL

Editing a view and reopening the panel shows the old code.

Do: `./scripts/dev-copy --restart`, or `omarchy-restart-shell`.

## The install and the tree

### A copy list that names what to include drops new files

An install script that copies a fixed list of paths leaves a new `.js` or `.qml`
out of the installed tree.

Looks like: works perfectly here, fails at runtime on somebody else's machine.
`omarchy plugin validate` catches a missing entry point but not a missing import.

Do: `scripts/dev-copy` copies every top-level entry except a small deny-list
(`.git`, `.agent`, `docs`, `tests`, `scripts`, `preview.png`, `.gitignore`), so a
new runtime file is included by default. A deny-list has the opposite failure
mode: a directory that should not ship has to be named, so review the list when
the tree grows one.

### An untracked file that committed code imports

A `.qml` file imported by a committed view but never `git add`ed builds here and
nowhere else.

Do: after any change that adds a file, check `git status` for untracked imports
before believing the tree is complete. A missing QML import is not a build error,
it is a view that fails to load somewhere else.

## Security

### A prefix test is not an origin test

`candidate.indexOf(base) !== 0`, and jq's `startswith($base)`, both accept a
different host that merely begins with the configured one. With a base of
`https://prod.example.com` that includes
`https://prod.example.com.attacker.test/steal`, the glued
`https://prod.example.comevil.test/x`, and the userinfo form
`https://prod.example.com@evil.test`.

The URL being checked can come from the NAS itself, and the check sits directly
in front of `xdg-open`.

Do: require that the character after the base **ends the host**, which only a
path, a query or a fragment does. `@` deliberately is not in that set.
`Links.safeUrl` is the one gate; every link, including an app portal, goes
through it.

### The API key

It never enters argv, a shell string, `shell.json` or a log. It travels on stdin
to `truenasctl login` and `config set-key`, the only writers, and lives only in
the credentials file at mode 600 inside a 700 directory. A saved key is never
read back into the UI and there is no reveal control. `config list` reports
whether a key is set, never its value. `tn_creds_mode_ok` refuses a credentials
file readable by others.

Watch the file modes: a plain `cp` restores a file without the modes `tn_write_atomic`
sets. Anything that touches the credentials or config file has to go through the
atomic write, which chmods before renaming.

### A field map cannot see prose

Redaction substitutes a value it has seen as a field, and a value written only
inside free-form text is invisible to that map. An alert body that lists the
clients hitting the REST API names addresses that exist nowhere else in the
state, so they survived every level while the NAS's own addresses in the same
sentence were faked.

Do: keep the prose pass in `Redact.js` (`maskProse`), which runs over every
free-form text value before the field map does: a URL authority goes through
`redactUrl`, a dotted quad and an IPv6 literal through `ipName`. A new free-form
field needs a `text` entry in `kindFor` to reach it. Two shapes stay readable on
purpose: loopback and `0.0.0.0` name no host, and a clock time or a three-part
version is not an address. Test with an address that is in no field, or the
suite passes while the leak is live.

## TrueNAS

### A self-signed certificate is the default, and `insecureTLS` is never guessed

TrueNAS ships a self-signed web certificate (iXsystems, `CN=localhost` on the box
this was checked against), so `curl` fails before the request is sent, with exit
60 and no HTTP status at all. A generic `unreachable` message hides the one fix
that works.

Looks like: `truenasctl test` reports nothing useful, every endpoint fails
identically, and the plugin looks broken rather than misconfigured.

Do: `tn_insecure_args` in `bin/truenas-lib.sh` adds `-k` only when the config's
`insecureTLS` is exactly `true`. It is type-guarded, never `// false`, because `//`
treats an explicit `false` as absent. `truenasctl login` inspects the certificate
and prints the fix (`set "insecureTLS": true`) rather than enabling it quietly, and
`tn_http_request` consults `tn_insecure_args` itself so no call path can forget it.
Verified live: `/api/v2.0/...` answers `401` rather than `404`, which is also how
the base URL was confirmed.

### REST `/api/v2.0` is deprecated, and the seam is one function

REST was deprecated in TrueNAS 25.04 and is removed in 26; the replacement is
JSON-RPC 2.0 over WebSocket at `/api/current`, where the same work is
`system.info`, `alert.list`, `pool.query`, `alert.dismiss`. Every call goes
through one request helper, `tn_http_request` (called as `tn_http_get`), and
`tn_dialect()` reports the generation a poll used (`rest-v2.0`), recorded in
`state.connection.dialect`.

Do: keep every `curl` inside `tn_http_request`. A second call site is a second
thing to migrate, and the whole point of the shim is that the migration is a
change to one function rather than a rewrite. See
[websocket-migration.md](websocket-migration.md).

### The rate limit forces two cadences

TrueNAS allows roughly 20 authenticated requests per 60 s, then a 10-minute
cooldown, and every route here is authenticated. One poll must not hit every
endpoint. The split: `alert/list` and `pool` every `pollSeconds` (floor 15,
default 30); `system/info`, the disks, services, apps, protection, shares and
interfaces on a ~300 s meta cadence cached in `meta.json`, refreshed by
`--force-meta` after a write.

Do: a new slow endpoint belongs on the meta list, never on the fast poll, or the
plugin rate-limits itself into a cooldown that no retry shortens.

### The notification `--exec` argv form

`omarchy-notification-send` takes options, then the headline and optional
description, then `--exec <program> [args...]` as the last thing, with the command
as separate argv words:

```
omarchy-notification-send [options] <headline> [description] --exec xdg-open <url>
```

A single argv word holding a space (`--exec "xdg-open <url>"`) is rejected
outright, and because the call ended in `|| true` every toast silently no-op'd.

Do: `bin/truenas-poll`'s `notify()` builds the options
(`--app-name truenas -u <urgency> -g <glyph>`), then the headline and body, then
`--exec xdg-open "$url"`, and never builds `--exec`'s command as one string. Alert
text is passed only as an argv element, never as a shell string.

### Check the real binary, not just the stub

The first test stub logged whatever it was handed, so the malformed `--exec`
passed and the bug shipped. A stub proves only what it chooses to check.

Do: `tests/stubs/omarchy-notification-send` reimplements the real sender's
argument contract (it rejects no headline, `--exec` with no command, a one-word
`--exec` command containing whitespace, and junk after the description) and only
logs an invocation that validates. When another external binary is stubbed, read
its actual argument handling first; a too-lenient stub is a green test over a
broken call.
