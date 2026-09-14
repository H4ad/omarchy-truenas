import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model
import "../Search.js" as Search

// One card per disk: the device name and its temperature, the model, the
// type/size/pool/bus line, and the critical threshold when the poll knows it.
//
// The same refusals Pools.qml makes, for the same reason:
//   * a failed details or temperatures request leaves `disks` empty or unknown,
//     and `warnings` names which. Without the warning sentence an unread disk
//     list would render as a NAS with no disks.
//   * a disk with no temperature says so in words; a missing reading is never
//     rounded down to 0 °C.
//   * the threshold line appears only when the poll reported it, because
//     "critical at unknown °C" is worse than no line at all.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property var disks: (view.nasState && Model.arrayLike(view.nasState.disks))
    ? view.nasState.disks : []
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings))
    ? view.nasState.warnings : []

  property string query: ""
  readonly property var rows: Search.disks(view.disks, view.query)

  // Disk details and disk temperatures fail independently, so each section gets
  // its own lookup and the sentence names the one that did not answer.
  readonly property var diskWarning: {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === "disk")
        return view.warnings[i]
    }
    return null
  }
  readonly property var diskTempWarning: {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === "diskTemp")
        return view.warnings[i]
    }
    return null
  }

  readonly property string warningLine: {
    var lines = []
    var details = view.warningSentence(view.diskWarning, "disk list")
    var temps = view.warningSentence(view.diskTempWarning, "disk temperatures")
    if (details !== "") lines.push(details)
    if (temps !== "") lines.push(temps)
    return lines.join("\n")
  }

  // Empty only while there is something to show: the warning line already says
  // why the list is missing, and a filter that matches nothing says so itself.
  readonly property string emptyText: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (view.disks.length > 0 && view.rows.length === 0) return "no disks match the filter"
    if (view.disks.length > 0) return ""
    if (view.diskWarning) return ""
    return "no disks reported"
  }

  function warningSentence(warning, label) {
    if (!warning) return ""
    var reason = String(warning.message || warning.error || "")
    return "the " + label + " could not be read" + (reason !== "" ? ": " + reason : "")
  }

  function tempText(disk) {
    var text = Model.formatTemp(disk && disk.tempC)
    return text !== "" ? text : "temperature unknown"
  }

  function tempColor(disk) {
    switch (String(disk && disk.tempState || "unknown")) {
      case "critical": return view.panel.urgentColor
      case "warning":  return Color.accent
      case "ok":       return view.panel.contentForeground
      default:         return view.panel.dimForeground
    }
  }

  // type · size · pool · bus, each drawn only when the poll reported it. A
  // missing size leaves the line short rather than reading as 0 B.
  function detailText(disk) {
    if (!disk || typeof disk !== "object") return ""
    var parts = []
    var type = String(disk.type || "")
    var size = Model.formatBytes(disk.size)
    var pool = String(disk.pool || "")
    var bus = String(disk.bus || "")
    if (type !== "") parts.push(type)
    if (size !== "") parts.push(size)
    if (pool !== "") parts.push(pool)
    if (bus !== "") parts.push(bus)
    return parts.join(" · ")
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter disks"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.query = value }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLine !== ""
    text: view.warningLine
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyText !== ""
    text: view.emptyText
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.rows

    Local.Card {
      id: diskCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string tempLabel: view.tempText(modelData)
      readonly property string detailLine: view.detailText(modelData)
      readonly property string thresholdLine: Model.tempThresholdText(modelData)

      Item {
        width: parent.width
        implicitHeight: Math.max(diskName.implicitHeight, diskTemp.implicitHeight)

        Text {
          id: diskName
          anchors.left: parent.left
          anchors.right: diskTemp.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: String(modelData.name || "unnamed disk")
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: diskTemp
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: diskCard.tempLabel
          color: view.tempColor(modelData)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        width: parent.width
        visible: String(modelData.model || "") !== ""
        elide: Text.ElideRight
        text: String(modelData.model || "")
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: diskCard.detailLine !== ""
        text: diskCard.detailLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: diskCard.thresholdLine !== ""
        text: diskCard.thresholdLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
