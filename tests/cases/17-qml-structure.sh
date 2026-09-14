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
# and cannot see this wiring, so the call has to be pinned here.
check "BarWidget routes the single tint through BarVariants.soleSeverity" "1" \
  "$(grep -c 'BarVariants.soleSeverity(root.segments)' "$ROOT/BarWidget.qml")"

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

# Every write to contentY goes through jumpTo, which cancels a running flick and
# clamps into range; a raw assignment elsewhere could rest outside it until
# StopAtBounds walked it back.
check "only jumpTo writes contentY" "1" \
  "$(grep -c 'root.flickable.contentY =' "$ROOT/Ui/ScrollIndicator.qml")"
