# shellcheck shell=bash
# Task 18: QML structure. The failures no other suite in this repo can see,
# because nothing else reads QML at all.
#
# A QML file that declares the same `function` twice at one scope fails to
# compile as a whole, and silently: the file loads as an empty item while every
# check that reads the source goes on passing. And a shared script without
# `.pragma library` is a private copy per importer, which no node suite can
# observe because node loads the file exactly once.
#
# These are greps over the source rather than behaviour, which is weak, and it is
# what is available: Ui/Card.qml and the rest of Ui pull in qs.Commons, whose
# Quickshell core plugin lives inside the quickshell binary and is not loadable
# by qml6. The one thing that can be run for real is a script with no QML types,
# and 18-qml-runtime.sh runs exactly that. Each check below pins the source line
# it is about, so a failure names the file and the line.

test_case "QML structure"

qml_files=$(find "$ROOT" -name '*.qml' -not -path '*/.git/*' | sort)

# ------------------------------------------------------------------- scripts
# `.pragma library` is load-bearing, not decoration. Without it every QML file
# that imports a script gets its own private copy of it, so a write in one
# importer is invisible to another. The directive has to be the first line of
# the file. Behaviour check in 18-qml-runtime.sh.
for script in Model.js Links.js Search.js BarVariants.js; do
  check "$script has .pragma library as line 1" \
    ".pragma library" "$(head -n 1 "$ROOT/$script")"
done

# --------------------------------------------------------------- bar tint path
# The single-tint path paints the whole item one colour. It has to come from
# the segments' own severity, or a lone hot disk keeps the alert count's colour
# and a hot bar reads as a quiet one. The node suites load BarVariants.js alone
# and cannot see this wiring, so it is pinned here twice. The declaration alone
# is not enough: reverting only the foreground binding to severityColor leaves
# the property declared and every other suite green, which is how the tint got
# lost once already.
check "BarWidget declares the single tint's severity" "1" \
  "$(grep -c 'BarVariants.soleSeverity(root.segments)' "$ROOT/BarWidget.qml")"
check "BarWidget guards the single tint on that severity" "1" \
  "$(grep -c 'root.soleSeverity !== ""' "$ROOT/BarWidget.qml")"
check "BarWidget tints the single tint with that severity" "1" \
  "$(grep -c 'root.colorForSeverity(root.soleSeverity)' "$ROOT/BarWidget.qml")"

# --------------------------------------------------------------- bar chart path
# The chart variants draw with Rectangles in the icon slot. The node suites load
# BarVariants.js alone and cannot see this wiring, so the renderer is pinned here:
# the widget must ask the JS for the kind, build the spec, and hand a component to
# the slot. If the renderer goes missing the chart variants silently fall back to
# the text path and draw nothing while every model test still passes.
check "BarWidget asks for the chart kind" "1" \
  "$(grep -c 'BarVariants.chartKind(root.variantChoice)' "$ROOT/BarWidget.qml")"
check "BarWidget builds the chart spec" "1" \
  "$(grep -c 'BarVariants.chartFor(root.variantChoice, root.barView)' "$ROOT/BarWidget.qml")"
check "BarWidget gives the icon slot the chart or composed component" "1" \
  "$(grep -c 'iconComponent: root.composed' "$ROOT/BarWidget.qml")"
check "BarWidget sizes the chart from the sizing twin" "2" \
  "$(grep -c 'chartSizer.implicitWidth' "$ROOT/BarWidget.qml")"
check "one chart piece component is declared" "1" \
  "$(grep -c 'id: chartPiece' "$ROOT/BarWidget.qml")"
check "BarWidget sizes the composed item from its twin" "2" \
  "$(grep -c 'composedSizer.implicitWidth' "$ROOT/BarWidget.qml")"

# ------------------------------------------------------------------ functions
# Two `function` declarations with the same name in one object collide, and the
# whole file fails to load rather than the second one losing. Root-scope members
# of a QML object sit at two spaces here, which is what makes it greppable.
qml_func_dupes=$(printf '%s\n' "$qml_files" | while IFS= read -r file; do
  awk '
    /^  function / {
      name = $2
      sub(/\(.*/, "", name)
      if (count[name]++)
        printf "%s:%d duplicates an earlier declaration of %s at line %d\n", FILENAME, FNR, name, line[name]
      else
        line[name] = FNR
    }' "$file"
done)
check "no QML object declares the same function twice" "" "$qml_func_dupes"

# ----------------------------------------------------------------- mouseareas
# A MouseArea that covers something and does not accept hover does not consume a
# hover event, so the rows underneath keep receiving them: a tooltip from a card
# nobody can see floats over the scrim covering it. Measured with the cursor
# parked on a covered card, containsMouse stayed true through the scrim. Every
# MouseArea here that sets anchors.fill is one of those.
qml_hover_missing=$(printf '%s\n' "$qml_files" | while IFS= read -r file; do
  awk '
    /MouseArea[[:space:]]*\{/ { inblock = 1; start = FNR; fill = ""; hover = ""; depth = 0 }
    inblock {
      opens = gsub(/\{/, "", $0)
      closes = gsub(/\}/, "", $0)
      depth += opens - closes
      if ($0 ~ /anchors\.fill[[:space:]]*:/) fill = FNR
      if ($0 ~ /hoverEnabled[[:space:]]*:[[:space:]]*true/) hover = FNR
      if (depth <= 0) {
        if (fill != "" && hover == "")
          printf "%s:%d covering MouseArea (anchors.fill at line %d) lacks hoverEnabled: true\n", FILENAME, start, fill
        inblock = 0
      }
    }' "$file"
done)
check "every covering MouseArea accepts hover" "" "$qml_hover_missing"

# --------------------------------------------------------------- panel dialogs
# A dialog declared at Panel.qml's root scope renders nowhere: BarWidget.qml
# loads that root into a `Loader { visible: false }`, and the panel you can see
# is a separate layer-shell window. Arming it sets `opened = true` and stalls
# there, and `keyCatcher.blocked` sticks true, which kills Escape for the rest of
# the session. Root-scope children sit at two spaces, which is the grep.
check "no ConfirmAction at Panel.qml root scope" "" \
  "$(grep -nE '^  (Local\.)?ConfirmAction[[:space:]]*\{' "$ROOT/Panel.qml")"

check "no HelpModal at Panel.qml root scope" "" \
  "$(grep -nE '^  (Local\.)?HelpModal[[:space:]]*\{' "$ROOT/Panel.qml")"

check "no dialog at Panel.qml root scope" "" \
  "$(grep -nE '^  (Local\.)?ConfirmDialog[[:space:]]*\{' "$ROOT/Panel.qml")"

# The one dialog lives inside the key catcher, which owns Keys.onPressed for the
# whole panel and is what drives it.
check "ConfirmAction is declared inside the panel's key catcher" "1" \
  "$(awk '/^    PanelKeyCatcher \{/ { inside = 1 }
          inside && /(Local\.)?ConfirmAction \{/ { found += 1 }
          END { print found + 0 }' "$ROOT/Panel.qml")"

# The key catcher owns Escape, so the dialog has to be answered from the
# catcher's own signal before the panel is closed out from under it.
check "Escape answers the dialog before it closes the panel" "1" \
  "$(grep -c 'if (confirmAction.opened) confirmAction.canceled()' "$ROOT/Panel.qml")"

# -------------------------------------------------------------------- manifest
# The manifest names the three files omarchy-shell loads. A rename that misses
# the manifest is a plugin that never starts, and nothing else here reads it.
qml_missing=""
while IFS= read -r entry; do
  [[ -n "$entry" && ! -f "$ROOT/$entry" ]] && qml_missing="$qml_missing $entry"
done < <(jq -r '.entryPoints[]' "$ROOT/manifest.json")
check "every manifest entryPoint file exists" "" "${qml_missing# }"

# The widget can sit on the bar more than once, and every instance shares the
# module id, so a settings write keyed on the id alone would edit the first item.
# The panel locates its own entry and writes by {section, index} selector; the
# bar item relays an IPC verb to the instance the bar would open.
check "the manifest allows more than one bar item" "true" \
  "$(jq -r '.barWidget.allowMultiple' "$ROOT/manifest.json")"
check "the panel locates its own layout entry" "1" \
  "$(grep -c 'Model.entryLocation(bar.layoutConfig' "$ROOT/Panel.qml")"
check "the panel writes a widget setting by selector" "1" \
  "$(grep -c 'registry.setBarWidget(' "$ROOT/Panel.qml")"
check "the bar item relays ipc to the opened instance" "1" \
  "$(grep -c 'root.bar.findPanelWidget(root.moduleName)' "$ROOT/BarWidget.qml")"

# The Custom variant composes pieces into one item. The composer is in
# BarVariants.js, the shared chart in Ui/BarChartPiece.qml, the toggles in the
# manifest schema and the panel's switch list, and the bar item draws the tokens.
check "the shared chart piece exists" "yes" \
  "$([[ -f "$ROOT/Ui/BarChartPiece.qml" ]] && echo yes)"
check "the widget draws charts through the shared piece" "2" \
  "$(grep -c 'Local.BarChartPiece {' "$ROOT/BarWidget.qml")"
check "the composer is wired into the bar item" "1" \
  "$(grep -c 'BarVariants.customItems(root.barView' "$ROOT/BarWidget.qml")"
check "the config view lists one toggle per custom piece" "13" \
  "$(grep -c '{ key: "show' "$ROOT/Views/Config.qml")"
check "the manifest declares one key per custom piece" "13" \
  "$(jq -r '[.barWidget.schema[] | select(.key | startswith("show"))] | length' "$ROOT/manifest.json")"

# Every variant the JS resolves must be selectable in the manifest, and the
# manifest must not offer one the JS would fall back to Default for. Both lists
# come from their source, and the check names the side each missing entry is on.
bar_variants=$(sed -n 's/^var VARIANTS = \[\(.*\)\];$/\1/p' "$ROOT/BarVariants.js" \
  | tr ',' '\n' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
manifest_variants=$(jq -r '.barWidget.schema[] | select(.key == "variant") | .options[]' "$ROOT/manifest.json")
qml_variant_missing=""
while IFS= read -r variant; do
  [[ -n "$variant" ]] || continue
  grep -qx "$variant" <<<"$manifest_variants" \
    || qml_variant_missing="$qml_variant_missing js:$variant"
done <<<"$bar_variants"
while IFS= read -r variant; do
  [[ -n "$variant" ]] || continue
  grep -qx "$variant" <<<"$bar_variants" \
    || qml_variant_missing="$qml_variant_missing manifest:$variant"
done <<<"$manifest_variants"
check "the manifest offers exactly the variants the JS resolves" "" \
  "${qml_variant_missing# }"

# --------------------------------------------------------- view registration
# The tabs list, the viewComponents map and Menu.qml's view rows all name the
# same set of views. A view present in one and missing from another is a tab
# that renders nothing or a menu row that opens nothing, and nothing else here
# can see it: both files compile and lint clean. The three lists are regular
# enough to compare as text, and a pattern that stops matching fails the check
# rather than passing over empty sets.
qml_tab_keys=$(sed -n 's/^    { key: "\([a-z]*\)", label:.*/\1/p' "$ROOT/Panel.qml")
qml_view_keys=$(sed -n 's/^    "\([a-z]*\)": [A-Za-z]*View.*$/\1/p' "$ROOT/Panel.qml")
qml_menu_keys=$(sed -n 's/^      { kind: "view", args: \["\([a-z]*\)"\].*/\1/p' "$ROOT/Menu.qml")
qml_registration_missing=""
[[ -n "$qml_tab_keys" ]] || qml_registration_missing="$qml_registration_missing Panel.qml:tabs"
[[ -n "$qml_view_keys" ]] || qml_registration_missing="$qml_registration_missing Panel.qml:viewComponents"
[[ -n "$qml_menu_keys" ]] || qml_registration_missing="$qml_registration_missing Menu.qml:views"
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  grep -qx "$key" <<<"$qml_view_keys" \
    || qml_registration_missing="$qml_registration_missing viewComponents:$key"
  grep -qx "$key" <<<"$qml_menu_keys" \
    || qml_registration_missing="$qml_registration_missing menu:$key"
done <<<"$qml_tab_keys"
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  grep -qx "$key" <<<"$qml_tab_keys" \
    || qml_registration_missing="$qml_registration_missing tabs:$key"
done <<<"$qml_view_keys
$qml_menu_keys"
check "every view is registered in the tabs, viewComponents and menu" "" \
  "${qml_registration_missing# }"

# -------------------------------------------------------------- scroll surface
# A child of a Flickable is content, so a scroll indicator declared inside one
# scrolls away with the rows it is describing. Both are declared as a sibling and
# name their Flickable instead. The examples in ScrollIndicator.qml's own header
# are comments, so they do not start with the component name and are not counted.
qml_indicators=$(grep -rhoE '^ *(Local\.)?ScrollIndicator \{' --include='*.qml' "$ROOT" | awk 'END { print NR + 0 }')
qml_flickables=$(grep -rhoE '^ *flickable: ' --include='*.qml' "$ROOT" | awk 'END { print NR + 0 }')
check "every scroll indicator names the Flickable it belongs to" \
  "$qml_indicators" "$qml_flickables"

# Held open whether or not the bar is drawn, or every sentence in the view
# re-wraps at the moment the list grows long enough to scroll.
check "the panel body reserves the scrollbar's lane" "1" \
  "$(grep -c 'anchors.rightMargin: bodyBar.width' "$ROOT/Panel.qml")"

check "the help sheet reserves it too" "1" \
  "$(grep -c 'anchors.rightMargin: bodyBar.width' "$ROOT/Ui/HelpModal.qml")"

# MouseArea does not handle the wheel at all, and the panel body behind the sheet
# is a Flickable, so the scrim needs its own handler or a scroll over it moves
# the view behind the sheet.
check "the help scrim swallows the wheel" "1" \
  "$(grep -c 'WheelHandler {' "$ROOT/Ui/HelpModal.qml")"

# body is anchored top-to-bottom inside the sheet, so its height comes from the
# sheet. Sizing the sheet from body.height is a layout cycle that leaves the
# glossary a one-line box; only the intrinsic content height is safe to read.
check "the help sheet sizes from the content height, not the viewport" "1" \
  "$(grep -c '+ body.contentHeight)' "$ROOT/Ui/HelpModal.qml")"
check "the help sheet does not size from body.height" "" \
  "$(grep -n '+ body.height)' "$ROOT/Ui/HelpModal.qml")"

# Nine tabs do not fit one line at the default width. The strip must be a
# wrapping Flow: a Row clips the last tab ("Config") with no visual hint.
check "the panel tab strip wraps instead of clipping" "1" \
  "$(grep -c '^        Flow {' "$ROOT/Panel.qml")"
check "the tab strip no longer clips in a Row" "" \
  "$(grep -n 'spacing: Style.space(14)' "$ROOT/Panel.qml")"

# Every write to contentY goes through jumpTo, which cancels a running flick and
# clamps into range; a raw assignment elsewhere could rest outside it until
# StopAtBounds walked it back.
check "only jumpTo writes contentY" "1" \
  "$(grep -c 'root.flickable.contentY =' "$ROOT/Ui/ScrollIndicator.qml")"

# -------------------------------------------------------------- helper callers
# The two helpers Task C keeps each need a live caller, or the only match in the
# repo is the library definition.
check "the Apps view gives appsUpgradeable a caller" "1" \
  "$(grep -c 'Model.appsUpgradeable(view.apps)' "$ROOT/Views/Apps.qml")"
check "the Shares view gives unknownInterfaces a caller" "1" \
  "$(grep -c 'Model.unknownInterfaces(view.network)' "$ROOT/Views/Shares.qml")"

# ---------------------------------------------------------------- state lines
# Each data view declares `readonly property string emptyText|statusLine` or a
# `function emptyFor`. Views/Config.qml is the one exemption: it reads no polled
# list. The declaration must start the line so a commented-out one cannot pass.
qml_state_missing=""
qml_state_scanned=0
for file in "$ROOT"/Views/*.qml; do
  name=$(basename "$file")
  [[ $name == "Config.qml" ]] && continue
  [[ -f "$file" ]] || continue
  qml_state_scanned=$((qml_state_scanned + 1))
  grep -qE '^[[:space:]]*readonly property string (emptyText|statusLine)|^[[:space:]]*function emptyFor' "$file" \
    || qml_state_missing="$qml_state_missing $name"
done
[[ $qml_state_scanned -gt 0 ]] || qml_state_missing="$qml_state_missing Views:no-files-scanned"
check "every data view declares a state line (Views/Config.qml exempt: no polled list)" \
  "" "${qml_state_missing# }"

# The contract's unconfigured sentence, in every data view but Config. A view
# that folds "not configured" into the offline branch prints "No answer from the
# NAS: not configured yet" instead. The check names each offending file.
qml_unconfigured_missing=""
for file in "$ROOT"/Views/*.qml; do
  name=$(basename "$file")
  [[ $name == "Config.qml" ]] && continue
  [[ -f "$file" ]] || continue
  grep -qF 'not configured yet · run truenasctl login <url>' "$file" \
    || qml_unconfigured_missing="$qml_unconfigured_missing $name"
done
check "every data view names the not-configured sentence (Views/Config.qml exempt)" \
  "" "${qml_unconfigured_missing# }"
