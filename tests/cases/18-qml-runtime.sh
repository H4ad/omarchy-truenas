# shellcheck shell=bash
# Task 18: the one thing in this repo a grep cannot check: whether two QML
# components that import Model.js are looking at the same copy of it.
#
# A JS file imported by QML is instantiated per importing component unless it
# declares `.pragma library`, so without the directive every QML file gets a
# private copy and a write in one is invisible to another. Model.js keeps no
# mutable state, so the difference is invisible to the node suites, which load
# the file exactly once, and to the structure greps, which cannot say what the
# engine does with it. The observable difference is object identity: with the
# directive both importers see the same function objects, without it they see
# different ones. Two throwaway components are enough to measure it.
#
# 17-qml-structure.sh asserts the directive is present; this is the check that
# the engine honours it, and the only one that catches it being removed.

test_case "the QML scripts are one copy per engine"
setup

qml_bin=""
if command -v qml6 >/dev/null 2>&1; then
  qml_bin=$(command -v qml6)
elif [[ -x /usr/lib/qt6/bin/qml6 ]]; then
  qml_bin=/usr/lib/qt6/bin/qml6
fi

if [[ -z "$qml_bin" ]]; then
  # Reported, not skipped, for the same reason run.sh reports a missing node: a
  # suite that quietly stops checking the thing it exists to check is worse than
  # one that fails.
  check "qml6 is installed to run the QML runtime suite" yes no
else
  mkdir -p "$WORK/qml"

  # A tiny library with mutable state, so one component can set a value and the
  # other can read it back. This measures the directive directly.
  cat >"$WORK/qml/SharedState.js" <<'JS'
.pragma library
var value = "unset"
function set(next) { value = String(next) }
function read() { return value }
JS

  # Each also imports the repo's real Model.js: it holds no QML types, so unlike
  # Ui/Card.qml the engine can load it headlessly, and each component exposes one
  # of its functions. Identity across the two components is what a missing
  # directive changes.
  cat >"$WORK/qml/Writer.qml" <<QML
import QtQuick
import "SharedState.js" as Shared
import "$ROOT/Model.js" as Model
Item {
  property var arrayLike: Model.arrayLike
  function fill() { Shared.set("CRED") }
}
QML
  cat >"$WORK/qml/Reader.qml" <<QML
import QtQuick
import "SharedState.js" as Shared
import "$ROOT/Model.js" as Model
Item {
  property var arrayLike: Model.arrayLike
  function read() { return Shared.read() }
}
QML
  cat >"$WORK/qml/main.qml" <<'QML'
import QtQuick
Item {
  Writer { id: writer }
  Reader { id: reader }
  Component.onCompleted: {
    // Before anything writes, both sides read the script's own default, so an
    // empty answer here means the reader is not reading at all.
    console.log("BEFORE " + reader.read())
    writer.fill()
    console.log("AFTER " + reader.read())
    // true only when both importers share one copy of Model.js.
    console.log("IDENT " + (writer.arrayLike === reader.arrayLike))
    Qt.exit(0)
  }
}
QML

  # qml6 writes to stderr through the Qt logger, which is silent unless it is
  # told the stream is a console. The timeout keeps a component that fails to
  # exit from hanging the whole suite.
  qml_out=$(QT_ASSUME_STDERR_HAS_CONSOLE=1 QT_QPA_PLATFORM=offscreen \
    timeout 30 "$qml_bin" "$WORK/qml/main.qml" 2>&1)

  check "the reader sees no value before the writer sets one" unset \
    "$(printf '%s\n' "$qml_out" | sed -n 's/^.*BEFORE \(.*\)$/\1/p')"
  check "and sees the value the other component set" CRED \
    "$(printf '%s\n' "$qml_out" | sed -n 's/^.*AFTER \(.*\)$/\1/p')"
  check "Model.js is one shared copy, not one per importer" true \
    "$(printf '%s\n' "$qml_out" | sed -n 's/^.*IDENT \(.*\)$/\1/p')"
fi

teardown
