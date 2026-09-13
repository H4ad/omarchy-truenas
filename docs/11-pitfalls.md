# Pitfalls

Everything in this file cost real time at least once. Most of it was found by a
test or a live run rather than by reading, and a few were found only because
somebody went back and checked a claim that had already been written down as
true.

Each entry says what it looks like when it happens, because that is the part
that is hard to recognise the second time.

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
healthy system with nothing firing. Found twice, independently, by two tasks.

Do: use the `arrayLike` helper in `Model.js`, never `Array.isArray`, on anything
that crossed the QML boundary. There are regression assertions on all twelve
sites.

### A sum that lost half its inputs and says it is complete

`signoz-api` reports failure as `{error, message}` with **no `ok` field at all**,
which is what unreachable, unauthenticated and a rejected card all produce, and
the panel passes that object straight through. Testing `answer.ok === false`
alone counts it as usable.

Looks like: `partial: false`, `missing: 0`, and a number that is quietly half of
what it should be.

Do: test `answer.ok === false || answer.error`. Assert it, because the shape that
breaks it is the common failure and not the rare one.

### jq's `//` is not a default

`//` is the alternative operator and treats `false` exactly like absent, so
`(.enabled // true)` is **true** for something explicitly turned off.

Looks like: a disabled instance still being polled.

Do: compare explicitly, `.enabled != false`. Same for anything where `false` is
meaningful rather than missing.

### A test suite that is registered and absent

`tests/run.sh` skips a suite whose file does not exist. A suite named in the loop
but not yet written passes by not running.

Looks like: `all suites green` with one suite's assertions never executed. The
`links` suite sat in this state.

Do: the loop now fails on a missing named suite instead of continuing. If you add
a suite name, add the file in the same change.

### A write patched into the list nobody is drawing

There are two rules lists. Narrowed to one instance, `Views/Rules.qml` draws
`panel.rulesData`. Under **All** it draws its own per instance fan-out,
`fanResults`, and `panel.rulesData` is null. `setRuleEnabled` only ever patched
`panel.rulesData`, so under All the patch went nowhere. Worse,
`(null || []).map()` is `[]`, so it wrote an empty list over the null as well.

Looks like: the toggle sends the write, the instance accepts it, the row keeps
its old switch and stays in its old state group. Reads as a control that did not
take, and inviting a second click on a write that already landed. Nothing is red,
and the narrow scope works perfectly, which is the scope a single-instance
machine is always in.

Do: the panel owns the queue, so it announces the write (`signal ruleChanged`)
and each list patches itself. The patch is `Model.patchRule`, shared by both, and
it answers **null** rather than a copy when the rule is not in that list, so one
instance's write does not rebuild every instance's rows.

### A write verb that answers with nothing

`signozctl star` and `unstar` write the favorites file and print **nothing at
all**, not even a sentence. `Panel.toggleStar` assigned the callback's argument
to `root.favorites`, and for a silent write that argument is `finishApi`'s
`{ok: true, output: ""}` placeholder.

Looks like: the star glyph never changes, the STARRED block on the home view
disappears, and clicking again stars instead of unstarring, because `isStarred`
has lost the document it decides from. The file on disk was correct the whole
time, so the state is right and only the screen is wrong.

The comment above the function claimed these verbs "answer with the whole
document". They never did. Every existing test sent their output to `/dev/null`,
which is how nobody noticed.

Do: read a write back, the way the config view does. And when a callback assigns
whatever it was handed to a property a view decides from, check what the verb
actually prints: `out=$(cmd); echo "len=${#out}"`.

### A pinned card that does not say it is pinned

A card carrying `"instance"` is fetched from that instance whatever the panel is
scoped to. `docs/09-round-three.md` specifies that such a card "is always shown,
carries its origin tag, and does not refetch when the scope changes". Only the
third of those was implemented, and `share/cards` ships three worked examples
that pin `staging`, so a copied card inherits the pin without inheriting a way to
see it.

Looks like: cards that never change when you switch instance, and never sum under
All. Which is correct behaviour, reported as a bug, because the card is showing
one instance's number under another instance's name with nothing saying so. The
combining code was fine throughout: two live instances summed 106,912 and 179,976
to 286,888 the moment the `instance` line came out.

Do: `Model.originTag` beside the title whenever the widget watches more than one
instance. Gate it on `panel.multiInstance` and never on the scope, which has one
member exactly when the tag is the thing doing the explaining.

### An empty file parses fine

`jq .` on an empty file exits 0 and prints nothing. So does a `jq` filter over
nothing.

Do: check the file has content before believing a successful parse.

### A new config field that `config list` does not include

`cmd_config_list` in `signozctl` builds a new object with explicit fields. A
field added to the config schema but not to this jq query is missing from
`configData`, so the UI cannot read it.

Looks like: setting a field via `config set` works, `jq` on the file shows the
value, and the UI shows nothing or the fallback. Editing the field in the UI
fails with "could not update" because `writeLanded` compares `configData.field`
(undefined) against `spec.field` (the value just written).

Do: when adding a config field, update all three places in one change:

1. `sz_load_config` in `signoz-lib.sh` (so the poller sees it)
2. `cmd_config_set` in `signozctl` (so the CLI can write it)
3. `cmd_config_list` in `signozctl` (so the UI can read it back)

Add a test that sets the field and checks both `config list` output and the
raw file.

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
no-op. `Panel.qml` carried two copies of `cardInstanceObjectsFor`, identical
bodies, at lines 323 and 416.

Looks like: the bar item paints normally, the tooltip is right, and clicking it
does nothing at all. `BarWidget.qml` compiled fine; it was `root.toggle()`
reaching a null `panelLoader.item`. Nothing is red anywhere on screen, and the
only trace is one line in the shell log:

```
WARN scene: file://…/io.signoz.omarchy/Panel.qml[416:12]: Duplicate method name
```

Confirmed against Qt 6 rather than assumed: `qml6` on a file with two same-name
functions exits 2 and creates nothing, the same file with one exits 0. `qmllint`
does not report it, under either Qt.

Do: read the shell log first when a click does nothing, because a dead panel and
a panel that opens off-screen look identical from the bar. A grep catches the
whole class before a restart does:

```bash
for f in $(git ls-files '*.qml'); do
  grep -oP '^  function \K\w+' "$f" | sort | uniq -d | sed "s|^|$f: duplicate |"
done
```

Two-space indent only, so root-scope functions are compared with each other and
a nested `IpcHandler`'s `open()` is not a false positive.

### A dialog declared where nothing is drawn

`BarWidget.qml` loads `Panel.qml` into a `Loader { visible: false }`, and the
panel you can see is a separate layer-shell window that `KeyboardPanel` creates.
So a visual child declared at `Panel.qml`'s **root scope** is a sibling of that
window rather than a child of it, and it renders nowhere: `anchors.fill: parent`
fills an invisible zero-sized item inside the bar. `ConfirmDialog` sat there.

Looks like: the switch that disables a rule does nothing. It sets
`confirmDialog.opened = true`, the dialog is asked for, no dialog appears, no
request is sent, and nothing is red. `opened` then stays true for the rest of the
session, and because the old code carried `blocked: confirmDialog.opened`, Escape
stopped closing the panel too, one symptom hiding behind another. The enable
direction kept working, which is what makes the control look intermittent rather
than broken.

Do: declare anything visual inside the `PanelKeyCatcher`, which is inside the
panel window, and raise it with `z`. The clipboard and menu plugins both put
their `ConfirmDialog` inside the visible card for the same reason.

And a dialog there cannot be answered from the keyboard by itself:
`PanelKeyCatcher` owns `Keys.onPressed` for the whole panel, so
`ConfirmDialog.handleKey` is never reached. Drive it from the catcher's
`onCloseRequested`, `onReturnRequested` and `onMoveRequested` instead. `blocked`
is the wrong tool: it silences the catcher, which is the only thing still
receiving the keys.

### qmllint exits 255 with no message

The bare `qmllint` on this machine is **Qt 5**, which exits 255 with nothing on
stdout or stderr when it meets a typed function signature (`function ping(): void`),
and that is exactly what an `IpcHandler` requires.

This repo believed for two rounds that the cause was `IpcHandler` itself, or
passing two files at once. Both were wrong, and the wrong diagnosis was passed to
twelve parallel tasks as fact.

Do: use `/usr/lib/qt6/bin/qmllint`. It takes the whole repo in one invocation and
reports real errors with a message.

A stray brace produces the same silent 255 under Qt 5. If Qt 6 is unavailable and
lint goes quiet, count braces.

### A callback that outlives its view

The panel's process queue outlives a view. Switching tab or scope while a
fan-out is in flight has the `Loader` destroy the view, and the queued callback
then runs against a destroyed object where **every property read throws**.

Looks like: `TypeError: Cannot read property 'x' of null` in the shell log, on
every such switch, with nothing wrong on screen. Nothing in CI catches it,
because nothing in CI runs QML.

Do: `if (!root) return` at the top of every queued callback, and guard the
one-liners as `if (root) root.something()`.

### A scrim that does not accept hover is not a scrim

A `MouseArea` blocks presses whether or not it is `hoverEnabled`, and blocks
hover only if it is. So a full-screen dismissal scrim written the obvious way,
`MouseArea { anchors.fill: parent; onClicked: close() }`, stops every click and
lets every hover through to whatever it is covering.

Looks like: the panel behind an open sheet keeps hovering. Its rows highlight
under a scrim nobody can click, and because `PanelToolTip` is a
`QtQuick.Controls` `ToolTip`, which is a `Popup` drawn in the window's own
overlay rather than in the item tree, **the tooltip of a card hidden behind the
sheet is drawn on top of the sheet**. It reads as the sheet failing to render
over the panel, which sends you looking at `z` and at stacking order, where
there is nothing wrong.

Do: `hoverEnabled: true` on any MouseArea whose job is to cover something. Add
`WheelHandler { onWheel: function(event) { event.accepted = true } }` beside it,
because MouseArea does not handle wheel at all and the panel body is a
`Flickable`. `Ui/HelpModal.qml` does both, and `tests/cases/17-qml-structure.sh`
counts every MouseArea in that file against the number that accept hover.

Confirmed rather than reasoned: with the cursor parked on a covered card by
`hyprctl dispatch 'hl.dsp.cursor.move(...)'`, which needs no client and presses
nothing, the card's MouseArea reported `containsMouse` **true** through the
scrim, and false once the line was added. The wheel half is reasoned from Qt's
event rules and was not measured, because nothing installed here emits a wheel
event.

Upstream `ConfirmDialog` has the same shape and has not been changed.

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
unless its first line is `.pragma library`. Without the directive, `Model.js`
state written by `BarWidget.qml` is written into BarWidget's private copy, and
`Views/Home.qml`, `Ui/Card.qml` and the rest each read their own copy, which
nothing ever filled.

Looks like: exactly the symptom the version counter below is supposed to fix,
and the counter does not fix it. Tags update in the tab that wrote them (its rows
come from `config list`, not from the cache) and every other view keeps drawing
the id-derived fallback, forever, across restarts. Adding more version counters
does nothing, because the cache being read is not the cache being written.

Do: keep `.pragma library` as the first line of `Model.js`. A library script has
no component context, so it must never touch QML: no ids, no signals, no
`parent`. Node loads the same file with `new Function`, and `.pragma` is not
JavaScript, so every `tests/*.mjs` loader strips
`/^\.(pragma|import)\b.*$/gm` before evaluating.

Checked by `tests/cases/17-qml-structure.sh` (the directive is line one) and
`tests/cases/18-qml-runtime.sh`, which runs two throwaway components under
`qml6` and asserts the reader sees what the writer stored. That runtime check is
the only one that can see this class of bug: the node suites load the file once,
so sharing is all they can observe.

### QML bindings do not track plain JS variables

A binding like `text: Model.originTag(id)` re-evaluates only when its QML
dependencies change. If `originTag` reads from a module-level JS variable
(`TAG_CACHE`), QML has no way to know the variable was updated, and the binding
stays stale.

Looks like: updating a field via the config UI works, the poll rewrites
`state.json` with the new value, and every view except the one that wrote it
keeps showing the old value until the panel is closed and reopened.

Do: add a version counter that increments whenever the cache is rebuilt
(`TAG_CACHE_VERSION`). Return the new version from the rebuild function, store
it in a QML property (`tagCacheVersion`), and include it in every binding that
reads the cached value:

```qml
text: (panel.tagCacheVersion, Model.originTag(id))
```

The comma expression forces a dependency on the version while still evaluating
to the function's return value. When the version changes, QML re-evaluates the
whole expression.

Checklist for a new cached field:

1. Confirm `Model.js` still starts with `.pragma library`, or none of the rest
   matters (see above)
2. Add a version counter in `Model.js` beside the cache variable
3. Increment and return it from the rebuild function
4. Store the returned version in `BarWidget.tagCacheVersion`, **before** the
   assignment that triggers `injectPanel`, and re-inject on the counter too:
   `onTagCacheVersionChanged: injectPanel()`. Assigning `state` first hands the
   panel the previous version and leaves it a poll behind
5. Pass it through `Panel.tagCacheVersion`
6. Pass it to any component that reads the field (`Card`, `InstancePicker`, etc.)
7. Wrap every binding that calls the getter in `(panel.tagCacheVersion, ...)`
8. Find the bindings that build a **list** of precomputed values rather than
   calling the getter per row (`Model.homeStats`, Config's `rows`) and read the
   counter there as well. A `Repeater` drawing `modelData.tag` is only as fresh
   as the list binding that produced it

### One Process cannot launch two long-lived children

`Process` starts nothing while its previous child is alive.
`startProcessIfReady` returns early on `this->process != nullptr`
(quickshell `src/io/process.cpp:181`), and `setCommand` only stores the new argv
before calling it again. So one shared `Process { id: openProc }`, reused per
click, is a queue of depth one.

`xdg-open` is exactly such a child. The shell's environment carries no
`BROWSER`, so `xdg-open` runs Chrome itself and waits on the browser it
launched, which means the child lives as long as the window does.
`omarchy-launch-config-editor` behaves the same way for as long as the editor is
open.

Looks like: the first card link opens, every later one does nothing, and nothing
is red and nothing is logged. Then the stale one fires: `onFinished` calls
`startProcessIfReady` once more (`src/io/process.cpp:286`), so when the browser
finally quits, the widget opens whichever URL was set last, minutes after the
click that set it.

Do: `Quickshell.execDetached(["xdg-open", safe])`. It holds no handle, so it has
nothing to be busy with, and the argv form still keeps a shell out of it. Only
reach for a `Process` when the output or the exit code is wanted.

A `Process` is right for a child that exits on its own: `wl-copy` forks into the
background, and `signoz-poll` returns, so `clipProc` and `pollProc` are never
holding anything when the next call arrives.

### The shell caches compiled QML per URL

Editing a view and reopening the panel shows the old code.

Do: `./scripts/dev-install --restart`, or `omarchy-restart-shell`.

## The install and the tree

### A hardcoded copy list drops new files

`scripts/dev-install` copies a fixed list of paths. A new `.js` or `.qml` that is
not in it is missing from the installed tree.

Looks like: works perfectly here, fails at runtime on somebody else's machine.
`omarchy plugin validate` catches a missing entry point but not a missing import.

This has happened twice: `Search.js` and `BarVariants.js` in round two, then
`Links.js` and `Menu.qml` in round three.

### An untracked file that committed code imports

`Ui/InstancePicker.qml` was imported by `Views/Home.qml` and had never been
`git add`ed, so the tree built here and nowhere else.

Do: after any change that adds a file, check `git status` for untracked imports
before believing the tree is complete. A missing QML import is not a build error,
it is a view that fails to load somewhere else.

## SigNoz API

### 200 with HTML means the route does not exist

SigNoz Cloud serves the SPA shell for unknown paths, so a status code alone
cannot prove an endpoint is there.

### Muted alerts are still in the list, and only one field says so

`GET /api/v1/alerts` returns muted alerts. The only marker is `status.state`
reading `suppressed`. `silencedBy` and `inhibitedBy` stay **empty** throughout,
and the flip takes roughly thirty seconds after the window starts.

Looks like: muting a rule changes no count anywhere, so the bar badge, the
severity cells and the notification decision are all inflated by whatever is
muted. Muting fails at the one job it has.

Do: derive `silenced` from `status.state == "suppressed"` as well as from
`silencedBy`. Keep muted alerts visible in the list and out of the counts, and
carry a count of them so a number never shrinks with nothing explaining why.

### `rowsScanned` on a time_series request is cumulative

Both `rowsScanned` and `bytesScanned` grow with every repeated identical
`time_series` query. Nothing found resets them: not a changed window, not a new
process, not time. A 1h query sitting at 120,900 answered 230,087 on the first
call its 59m form had ever made, which is that 120,900 plus its own increment.
The counter is shared with any earlier query of the same shape from any source,
the web UI included.

Looks like: an authoritative-looking cost figure that is several times the real
one. This repo carried "43MB" for a round as the cost of one trivial one-hour
`count()`. Measured as a `scalar` it is 6.62MB, stable across three runs. The
figure had propagated into eight places, including a spec that used it to justify
a design.

Do: cost a series card by sending its query once as a `number`. Never quote a
`time_series` reading as the cost of a call, even a first one.

### A metrics scalar needs `reduceTo`

A metrics card of type `number` or `table` becomes a scalar request, which is
rejected with 400 unless the aggregation carries `reduceTo`. The validation is
attached only to the scalar request type, and an empty string is not accepted.

### `rowsScanned: 0` does not diagnose a zero

A nonexistent value and a genuinely quiet window both report 0 rows. A
nonexistent **field name** answers 0 after scanning tens of thousands of rows,
and never errors.

So the number tells you nothing about why the answer was zero, and a typo in a
field name is invisible. An earlier version of the authoring skill claimed the
opposite and sent readers looking in the wrong place.

### A rule-scoped downtime schedule cannot be deleted

`DELETE` answers `already_exists` with "cannot delete planned maintenance because
it is referenced by associated rules", so an unmute exits non-zero and leaves the
mute in force.

Do: `PUT` the schedule with `alertIds: []` **and the window moved into the past**,
then `DELETE`. Moving the window is not cosmetic: an empty `RuleIDs` means *every*
rule, so clearing the ids alone widens a one-rule mute to the whole instance for
the gap before the delete, and permanently if the delete is refused.

### Dashboard `name` is a slug

On `/api/v2/dashboards`, `.name` is a slug with a random suffix. The human title
is `.spec.display.name`. Display names are not unique.

### Explorer URLs

`compositeQuery` is encoded **twice** on purpose: the explorer reads it with
`decodeURIComponent` on a value `URLSearchParams` has already decoded once.
Encoding once silently opens an unfiltered explorer, and an unfiltered explorer
looks exactly like a link that worked.

`relativeTime` is matched against `/^(\d+)(months?|[mhdw])$/` and throws on
anything else, while a card range allows seconds. Seconds is the whole overlap
gap, so a seconds range needs an explicit `startTime` and `endTime`.

### A service-account token is not a UI session

The token authenticates every bootstrap endpoint the app hits except
`/api/v2/users/me`, which 401s, and that is the call the frontend gates login on.
A headless browser carrying the token lands on the login page.

So the traces and metrics explorer templates cannot be captured the way the logs
one was. They are derived from the frontend's own `initialQueriesMap`, and they
say so. If you derive a template, cross-check the derivation by re-deriving one
you *did* capture and matching it byte for byte.

### `alias` comes back as `__result_0`

A card's title has to come from its own config, not from the response.

## Security

### A prefix test is not an origin test

`candidate.indexOf(base) !== 0`, and jq's `startswith($base)`, both accept a
different host that merely begins with the configured one. With a base of
`https://prod.example.com` that includes
`https://prod.example.com.attacker.test/steal`, the glued
`https://prod.example.comevil.test/x`, and the userinfo form
`https://prod.example.com@evil.test`.

The URL being checked is the server's own `generatorURL`, so this was reachable
with data the plugin does not control, and the check sits directly in front of
`xdg-open`.

Do: require that the character after the base **ends the host**, which only a
path, a query or a fragment does. `@` deliberately is not in that set.

### The API key

It never enters argv, a shell string, or `shell.json`. It travels on stdin to
`signozctl config set-key`, which is the only writer, and lives only in the
credentials file at mode 600. A saved key is never read back into the UI and
there is no reveal control. `config list` reports whether a key is set, never its
value.

Watch the file modes: `config.json` has drifted from 600 to 644 twice, both times
because something restored it with a plain copy instead of the atomic write that
chmods before renaming.

### Input synthesis is not free

`ydotool` ships a udev rule, and on a machine where the user is already in the
`input` group, installing it grants every process that user runs machine-wide
input synthesis. A bar plugin has no business requiring that. The wlr virtual
pointer protocol goes through the compositor and needs nothing installed.

## Hashing and drawing

### djb2 modulo a small power of two is not hashing

djb2's multiplier 33 is 1 modulo 8, so `hash % 8` collapses to the sum of the
character codes with the order thrown away. `prod` and `staging` came out the same
colour, and so did all 24 orderings of `prod`.

Do: fold the high bits down with a 32-bit finalizer before the modulo. And note
that eight colours cannot separate more than eight ids, so the honest claim is a
bound, not uniqueness. The tag beside the swatch is the identity.

### Min-max normalisation is wrong for bars

Normalising a series to its own window minimum is right for a line and wrong for
a bar: the lowest bucket becomes a sliver, and a flat window of 10000, 10001,
10002 draws as nothing, half, full, a tenfold swing that never happened.

Do: scale bars from zero, keep a one pixel floor for anything measured, and give a
gap its slot with nothing drawn so a hole stays a hole.

## Working with parallel tasks

### Ownership has to be enforced, not just written down

Round three fixed every shared signature in a spec and gave each task a file
list. `Panel.qml` was still edited by a task that did not own it. The changes
were correct and needed, and they went in unreviewed by the owner, which was only
noticed while reading the diff to split it into commits.

### Tasks leave real state changed

Across one round: notifications left paused indefinitely **twice** by two
different tasks testing the pause path, an instance label renamed, and
`display.barVariant` rewritten by a picker test. Each was restored, and each was
caught by checking rather than by being reported.

Do: check the real state after any round of parallel work. Do not rely on a task
restoring what it changed, even when it was told to.

### A synthesised click drives the real pointer

There is no sandbox. A targeting miss clicks whatever is under the cursor: one
misfire landed in a browser window and navigated a page the user was reading.

Also, a naive motion, press, release lands on the panel's full-screen dismissal
area and closes it. The working recipe is paced: motion off target, 300ms, motion
to target, 300ms, press, 100ms hold, release.

### A checkbox ticked in bulk is not evidence

Round three's tracker rows were marked done with one blanket substitution, which
asserts completion without checking any of it. That is how a specified, reported,
unimplemented feature survived: unstar from the home view, where the star glyph
did nothing at all.

The audit that found it also found eight table rows and about thirty boxes that
were done and still marked open, and two boxes carrying claims that had since
been disproven.

Every one of those findings was invisible to the test suite, which was green
throughout.

### Verify your own claims before repeating them

Three figures in this repo were stated confidently, repeated, and wrong: the 43MB
card cost, a rendered value of `5.48s` that is really `5.31s`, and the cause of
the qmllint 255. Each survived because it was quoted from an earlier write-up
rather than re-measured.

## TrueNAS

The entries below are specific to `io.github.h4ad.truenas`. The rest of this file
is copied from the SigNoz plugin it was modelled on, and its lessons still apply;
where a path says `signoz`, read it as history rather than as code in this repo.

### A self-signed certificate is the default, and `insecureTLS` is never guessed

TrueNAS ships a self-signed web certificate (iXsystems, `CN=localhost` on the
box this was checked against), so `curl` fails before the request is sent, with
exit 60 and no HTTP status at all. The generic `unreachable` message hides the
one fix that works.

Looks like: `truenasctl test` reports nothing useful, every endpoint fails
identically, and the plugin looks broken rather than misconfigured.

Do: `tn_insecure_args` in `bin/truenas-lib.sh` adds `-k` only when the config's
`insecureTLS` is exactly `true`. It is type-guarded, never `// false`, because
`//` treats an explicit `false` as absent. `truenasctl login` inspects the
certificate and prints the fix (`set "insecureTLS": true in ...`) rather than
enabling it quietly, and `tn_http_request` consults `tn_insecure_args` itself so
no call path can forget it. Verified live: the certificate is self-signed and
`/api/v2.0/...` answers `401` rather than `404`, which is also how the base URL
was confirmed.

### REST `/api/v2.0` is deprecated, and the seam is one function

REST was deprecated in TrueNAS 25.04 and is removed in 26; the replacement is
JSON-RPC 2.0 over WebSocket at `/api/current`, where the same work is
`system.info`, `alert.list`, `pool.query`, `alert.dismiss`. Every call in this
repo goes through one request helper, `tn_http_request` (called as
`tn_http_get`; the design names this shim `tn_call`), and `tn_dialect()` reports
the generation a poll used (`rest-v2.0`), recorded in
`state.connection.dialect`.

Do: keep every `curl` inside `tn_http_request`. A second call site is a second
thing to migrate, and the whole point of the shim is that the migration is a
change to one function rather than a rewrite.

### The rate limit forces two cadences

TrueNAS allows roughly 20 auth or unauthenticated requests per 60 s, then a
10-minute cooldown, and every route here is authenticated. One poll must not hit
every endpoint. The design splits them: `alert/list`, `pool` and `core/get_jobs`
every `pollSeconds` (floor 15, default 30); `system/info`, `disk`, `service`,
`app` and the rest on a ~300 s meta cadence cached in `meta.json`, refreshed by
`--force-meta` after a write.

Do: a new slow endpoint belongs on the meta list, never on the fast poll, or the
plugin rate-limits itself into a cooldown that no retry shortens.

### The notification `--exec` argv form

`omarchy-notification-send` takes options, then the headline and optional
description, then `--exec <program> [args...]` as the last thing, with the
command as separate argv words:

```
omarchy-notification-send [options] <headline> [description] --exec xdg-open <url>
```

The reference passed `--exec "xdg-open <url>"`: one argv word holding a space.
The real sender rejects that outright, and because the call ended in `|| true`
every toast silently no-op'd. `bin/truenas-poll` inherited the shape and it was
only caught in review. Its `notify()` now builds the options
(`--app-name truenas -u <urgency> -g <glyph>`), then the headline and body, then
`--exec xdg-open "$url"` -- and never builds `--exec`'s command as one string.

### Check the real binary, not just the stub

The first test stub logged whatever it was handed, so the malformed `--exec`
passed and the bug shipped. A stub proves only what it chooses to check.

Do: `tests/stubs/omarchy-notification-send` reimplements the real sender's
argument contract -- it rejects no headline, `--exec` with no command, a
one-word `--exec` command containing whitespace, and junk after the description
-- and only logs an invocation that validates. When another external binary is
stubbed, read its actual argument handling first; a too-lenient stub is a green
test over a broken call.
