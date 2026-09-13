import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Masked entry for the one API key this plugin stores.
//
// There is no reveal control and no way to read the typed value back out of
// this component. `truenasctl config list` reports that a key is set, never the
// key itself, so a readable field would make the panel the only place the
// secret can be copied from.
//
// This is the one place the "never spawn a Process from a view" rule is
// suspended: `panel.runCtl` serialises argv through one shared process and
// cannot carry a secret on stdin, and a key in argv is readable in `ps` by
// every process of this user for the lifetime of the call. So the field owns a
// Process whose only command is `truenasctl config set-key`, with the key
// written to stdin and dropped in the same statement.
Item {
  id: root

  required property string ctlPath
  property string placeholderText: "paste the API key"
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Off when a surrounding form owns the buttons and calls submit() itself.
  property bool showActions: true

  // Length only. The value leaves this component down the pipe and nowhere
  // else, so a caller cannot log, copy or bind to it by accident.
  readonly property bool hasSecret: field.text.length > 0
  readonly property bool busy: setKey.running

  signal saved()
  signal failed(string message)
  signal canceled()

  implicitWidth: Style.space(220)
  implicitHeight: Math.max(field.implicitHeight, actions.visible ? actions.implicitHeight : 0)

  function submit() {
    if (setKey.running) return
    if (root.ctlPath === "" || field.text === "") return
    setKey.problem = ""
    setKey.secret = field.text
    field.text = ""
    setKey.command = [root.ctlPath, "config", "set-key"]
    setKey.running = true
  }

  function clear() {
    field.text = ""
  }

  function focusField() {
    field.forceActiveFocus()
  }

  // The helper writes its complaints to stderr prefixed with "truenas: ". The
  // last non-empty line is the one that says what went wrong; the earlier ones
  // are usually context.
  function reportFailure() {
    var lines = String(setKey.problem || "").split("\n").filter(function(line) {
      return line.trim() !== ""
    })
    var last = lines.length ? lines[lines.length - 1].replace(/^truenas:\s*/, "").trim() : ""
    setKey.problem = ""
    root.failed(last !== "" ? last : "truenasctl could not store the key")
  }

  TextField {
    id: field
    anchors.left: parent.left
    anchors.right: actions.visible ? actions.left : parent.right
    anchors.rightMargin: actions.visible ? Style.space(6) : 0
    anchors.verticalCenter: parent.verticalCenter
    enabled: !setKey.running
    password: true
    placeholderText: root.placeholderText
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    verticalPadding: Style.space(4)
    onAccepted: root.submit()
    Keys.onEscapePressed: function(event) {
      root.clear()
      root.canceled()
      event.accepted = true
    }
  }

  Row {
    id: actions
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    visible: root.showActions
    spacing: Style.space(6)

    Button {
      text: setKey.running ? "saving…" : "save"
      enabled: root.hasSecret && !setKey.running
      opacity: enabled ? 1 : 0.5
      bordered: true
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      verticalPadding: Style.space(3)
      onClicked: root.submit()
    }

    Button {
      text: "cancel"
      enabled: !setKey.running
      opacity: enabled ? 1 : 0.5
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      verticalPadding: Style.space(3)
      onClicked: {
        root.clear()
        root.canceled()
      }
    }
  }

  // The only command this Process is ever given, and the only writer of a key
  // in the whole panel. `secret` is written to stdin and dropped in the same
  // statement, so nothing holds it once the CLI has it.
  Process {
    id: setKey
    property string secret: ""
    property string problem: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: setKey.problem = String(text || "")
    }
    onExited: function(exitCode, exitStatus) {
      setKey.secret = ""
      if (exitCode === 0) {
        setKey.problem = ""
        root.saved()
        return
      }
      // exited and the stderr collector are not ordered against each other,
      // so the message is read one tick later.
      Qt.callLater(root.reportFailure)
    }
  }
}
