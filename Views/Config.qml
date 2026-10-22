import QtQuick
import qs.Commons
import qs.Ui
import "../Ui" as Local
import "../Model.js" as Model
import "../Redact.js" as Redact

// Configuration for this bar item. Two different things live here and the view
// keeps them apart:
//
//   WIDGET  variant, hideWhenHealthy and panelWidth come from shell.json, so
//           they belong to the bar item. Only the variant is editable here,
//           through the same picker the reference plugin uses; the other two
//           are shown as they are.
//   NAS     baseUrl, insecureTLS, pollSeconds and whether a key is set come from
//           truenasctl config list. The base URL is set by `truenasctl login`,
//           and the key is the one thing this view writes, on stdin.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  property string keyError: ""
  property string keyNotice: ""
  property string outputError: ""

  // The panel owns config loading: it calls loadConfig() from showView("config")
  // (and from the refresh and key-save paths), so this view must not issue a
  // second `config list` of its own.
  readonly property var config: view.panel.configData

  function keyStatusText() {
    if (!view.config) return "reading config…"
    if (view.config.keySet === true) return "a key is set"
    return "no key set"
  }

  function baseUrlText() {
    if (!view.config) return "reading config…"
    if (!view.config.instance) return "not configured; run truenasctl login"
    return String(view.config.instance.baseUrl || "")
  }

  function configValueText(name, fallback) {
    if (!view.config) return "…"
    var value = view.config[name]
    return value === undefined || value === null ? String(fallback) : String(value)
  }

  function redactLevel() {
    return Redact.normalize(view.config ? view.config.redact : "off")
  }

  // One setting, written the same way the CLI writes it, so a recording can be
  // set up from here and undone from a terminal.
  function setRedact(value) {
    view.keyError = ""
    view.keyNotice = ""
    view.panel.runCtl(["config", "set", "redact", value], function() {
      view.panel.loadConfig()
    }, function(result) {
      view.keyError = result && result.message
        ? String(result.message)
        : "could not change the redaction level"
    })
  }

  // The output-check list. `expectOutput` is the source of the toggle, and the
  // state is the source of which tasks exist and which are covered. Snapshot
  // tasks are covered; replication is covered only when its target is local.
  // The lookup is a loop, not a Set or an Array method, so it works on whatever
  // array wrapper the panel's JSON produced.
  function outputChecked(key) {
    var list = (view.config && Model.arrayLike(view.config.expectOutput))
      ? view.config.expectOutput : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i]) === key) return true
    }
    return false
  }

  function buildOutputTasks() {
    var out = []
    var state = view.panel.state
    if (!state) return out
    var rep = Model.arrayLike(state.replication) ? state.replication : []
    for (var r = 0; r < rep.length; r++) {
      var row = rep[r]
      if (!row || row.id === null || row.id === undefined) continue
      var direction = String(row.direction || "").toUpperCase()
      var transport = String(row.transport || "").toUpperCase()
      if (direction !== "PULL" && transport !== "LOCAL") continue
      var repKey = "replication:" + String(row.id)
      out.push({
        key: repKey,
        label: Model.protectionLabel(row) || "unnamed task",
        on: view.outputChecked(repKey)
      })
    }
    var tasks = Model.arrayLike(state.snapshotTasks) ? state.snapshotTasks : []
    for (var s = 0; s < tasks.length; s++) {
      var task = tasks[s]
      if (!task || task.id === null || task.id === undefined) continue
      var snapKey = "snapshotTasks:" + String(task.id)
      out.push({
        key: snapKey,
        label: Model.protectionLabel(task) || "unnamed task",
        on: view.outputChecked(snapKey)
      })
    }
    return out
  }

  readonly property var outputTasks: view.buildOutputTasks()

  function setOutputCheck(key, on) {
    view.outputError = ""
    view.panel.runCtl(["expect", key, on ? "on" : "off"], function() {
      // The config is the toggle's only source, so a reopen must read it back.
      // No refreshAfterWrite: a config toggle changes nothing the NAS returns,
      // and a forced meta poll would spend fifteen requests for nothing.
      view.panel.loadConfig()
    }, function(result) {
      view.outputError = result && result.message
        ? String(result.message)
        : "could not change the output check"
    })
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: view.width
    implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: label
      color: view.panel.dimForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      id: rowValue
      anchors.left: rowLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: value
      color: view.panel.contentForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: text !== ""
    text: {
      if (view.keyError !== "") return view.keyError
      if (view.panel.actionError !== "") return view.panel.actionError
      if (view.keyNotice !== "") return view.keyNotice
      if (view.panel.actionNotice !== "") return view.panel.actionNotice
      return ""
    }
    color: (view.keyError !== "" || view.panel.actionError !== "")
      ? view.panel.urgentColor : view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "WIDGET"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "the bar item's own settings; the variant is written back to shell.json here"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Local.VariantPicker {
    width: parent.width
    value: view.panel.setting("variant", "Default")
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    urgentColor: view.panel.urgentColor
    accentColor: Color.accent
    fontFamily: view.panel.contentFontFamily
    onPicked: function(variant) { view.panel.setWidgetSetting("variant", variant) }
  }

  // The Custom variant's pieces. The order here is the order the bar draws them,
  // so the list doubles as the documentation of the composition.
  PanelSectionHeader {
    text: "CUSTOM"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Pick the Custom variant to draw these pieces in one item, in this "
      + "order, text and charts mixed. A piece with nothing to say is dropped."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: [
      { key: "showGlyph", label: "state glyph", fallback: true },
      { key: "showSeverity", label: "alert buckets" },
      { key: "showAlerts", label: "alert count" },
      { key: "showDown", label: "services and apps down" },
      { key: "showProtection", label: "protection problems" },
      { key: "showCapacity", label: "capacity percent" },
      { key: "showCapacityBar", label: "capacity bar" },
      { key: "showPool", label: "pool status word" },
      { key: "showPools", label: "pool squares" },
      { key: "showDiskHeat", label: "disk heat" },
      { key: "showTemp", label: "hottest disk" },
      { key: "showSparkline", label: "capacity sparkline" },
      { key: "showUptime", label: "uptime" }
    ]

    Toggle {
      required property var modelData
      width: view.width
      label: String(modelData.label)
      checked: view.panel.setting(modelData.key, modelData.fallback === true) === true
      foreground: view.panel.contentForeground
      accent: Color.accent
      fontFamily: view.panel.contentFontFamily
      onClicked: view.panel.setWidgetSetting(
        modelData.key,
        !view.panel.setting(modelData.key, modelData.fallback === true))
    }
  }

  InfoRow {
    label: "hide when healthy"
    value: view.panel.setting("hideWhenHealthy", false) ? "on" : "off"
  }

  InfoRow {
    label: "panel width"
    value: String(view.panel.setting("panelWidth", 460))
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "NAS"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  InfoRow {
    label: "base url"
    value: view.baseUrlText()
  }

  InfoRow {
    label: "key"
    value: view.keyStatusText()
  }

  InfoRow {
    label: "insecure tls"
    value: view.config && view.config.insecureTLS === true ? "on" : "off"
  }

  InfoRow {
    label: "poll seconds"
    value: view.configValueText("pollSeconds", 30)
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Replacing the key runs truenasctl config set-key. It is read on stdin and "
      + "stored at mode 600; it is never passed as an argument or shown here."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Local.SecretField {
    width: parent.width
    ctlPath: view.panel.ctlPath
    placeholderText: view.config && view.config.keySet === true
      ? "replace the API key" : "paste the API key"
    foreground: view.panel.contentForeground
    accent: Color.accent
    fontFamily: view.panel.contentFontFamily
    onSaved: {
      view.keyError = ""
      view.keyNotice = "key stored"
      view.panel.loadConfig()
      view.panel.refreshAfterWrite()
    }
    onFailed: function(message) {
      view.keyNotice = ""
      view.keyError = message
    }
    onCanceled: {}
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "PROTECTION DATA CHECKS"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Off by default. A checked task reports NO DATA when its last successful run "
      + "produced no new snapshot, or when the snapshot it named is gone. Mark only a "
      + "task that always writes data; an incremental backup may legitimately write "
      + "nothing."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.panel.state === null
    text: "The list fills after the first poll."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.panel.state !== null && view.outputTasks.length === 0
    text: "No covered tasks reported. Remote replication, cloud sync and scrub tasks "
      + "have no local snapshot output to check."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.outputTasks

    Toggle {
      required property var modelData
      width: view.width
      label: String(modelData.label) + "  " + String(modelData.key)
      checked: modelData.on === true
      foreground: view.panel.contentForeground
      accent: Color.accent
      fontFamily: view.panel.contentFontFamily
      onClicked: view.setOutputCheck(String(modelData.key), modelData.on !== true)
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.outputError !== ""
    text: view.outputError
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "A check compares the run's named snapshot against the snapshots that exist. "
      + "A dataset that another task also snapshots has no per-task delta: mark only a "
      + "task that owns its dataset."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "RECORDING"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Hide identifying values while you record or screenshot. Display only: "
      + "the state and credential files keep the real values, and links still "
      + "open the real NAS."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    width: parent.width
    spacing: Style.space(12)

    Repeater {
      model: Redact.LEVELS

      Text {
        textFormat: Text.PlainText
        required property var modelData
        readonly property bool active: view.redactLevel() === modelData
        text: modelData
        color: active
          ? Color.accent
          : (redactMouse.containsMouse ? view.panel.contentForeground : view.panel.dimForeground)
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: active

        MouseArea {
          id: redactMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.setRedact(modelData)
        }
      }
    }
  }

  InfoRow {
    label: "hides"
    value: Redact.describe(view.redactLevel())
  }
}
