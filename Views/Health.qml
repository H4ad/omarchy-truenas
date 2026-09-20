import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model

// The Health view: one screen that answers "is the NAS okay, and if not, why".
//
// It reads only `panel.state` and re-renders on `panel.nowTick`, so every age
// here moves without a fresh poll. The one rule it keeps throughout is the
// plugin's whole contract: an unknown fact is a sentence, never a zero and
// never a loading dash. A missing pool list is a warning, not "0 pools"; a
// failed alert call is "counts unknown", not a column of zeros; and a null
// `system` is "system state unknown", not an uptime of 0s.
Column {
  id: view
  required property var panel
  spacing: Style.space(10)

  // ------------------------------------------------------------------- state

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)

  // Model.mode only says "unconfigured" when there is no schema at all, but the
  // poller still writes `schema: 1` when there is nothing to log in to and puts
  // the reason in connection.error instead. Both are setup states, not a NAS
  // that went away, so both get the login sentence rather than the plug.
  readonly property bool unconfigured: view.panel.mode === "unconfigured"
    || !!(view.connection && String(view.connection.error || "") === "unconfigured")

  readonly property var system: (view.nasState && view.nasState.system) || null
  readonly property var counts: (view.nasState && view.nasState.counts) || null

  readonly property var pools: {
    if (!view.nasState || !Model.arrayLike(view.nasState.pools)) return []
    return view.nasState.pools
  }

  readonly property var warnings: {
    if (!view.nasState || !Model.arrayLike(view.nasState.warnings)) return []
    return view.nasState.warnings
  }

  // A section that did not answer contributes no rows and no zeroes, so the
  // counts and the pools are only shown once their own call and the whole
  // normalization are known to have succeeded. `normalize` covers the one case
  // where every fetch returned but the payload could not be built.
  readonly property bool normalizeWarned: view.sectionWarned("normalize")
  readonly property bool countsKnown: view.connected && !view.normalizeWarned
    && !view.sectionWarned("alert")
  readonly property bool poolsKnown: view.connected && !view.normalizeWarned
    && !view.sectionWarned("pool")

  readonly property string pollAgeText: (view.panel.nowTick,
    Model.ageText(Model.ageSeconds(view.nasState ? view.nasState.updatedAt : null)))

  // The one line that says which of the four states this view is in. Without
  // it an unconfigured NAS, an unreachable one and a healthy one all look
  // like the same empty screen. Data counts are never printed here: only the
  // connection and, when partial, how many sections are missing.
  readonly property string statusLine: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (view.unconfigured)
      return "not configured yet · run truenasctl login <url>"
    if (!view.connected)
      return "No answer from the NAS: "
        + (Model.errorSentence(view.connection) || "the poll failed")
    var host = view.system ? String(view.system.hostname || "") : ""
    var where = host !== "" ? " to " + host : ""
    if (view.warnings.length > 0) {
      return "Connected" + where + " · " + view.warnings.length
        + (view.warnings.length === 1 ? " section did not answer" : " sections did not answer")
    }
    return "Connected" + where + " · all sections answered · checked "
      + view.pollAgeText + " ago"
  }

  readonly property color statusColor: {
    if (!view.nasState) return view.panel.dimForeground
    if (view.unconfigured) return Color.accent
    if (!view.connected) return view.panel.urgentColor
    if (view.warnings.length > 0) return Color.accent
    return view.panel.dimForeground
  }

  // Hostname, version and uptime, in that order. Built as a list so the whole
  // block disappears in a sentence when `system` is null rather than showing
  // three "unknown" rows or, worse, an uptime of zero.
  readonly property var facts: {
    if (!view.system) return []
    var rows = []
    var host = String(view.system.hostname || "")
    rows.push({ label: "hostname", value: host !== "" ? host : "unknown" })
    var version = String((view.connection && view.connection.version)
      || view.system.version || "")
    rows.push({ label: "version", value: version !== "" ? version : "unknown" })
    var uptime = view.system.uptimeSeconds
    var uptimeKnown = uptime !== null && uptime !== undefined && uptime !== ""
      && isFinite(Number(uptime))
    rows.push({
      label: "uptime",
      value: uptimeKnown ? "up " + Model.ageText(Number(uptime)) : "unknown"
    })
    return rows
  }

  // One cell per severity, in Model's fixed worst-first order. A count that is
  // not a number is null, which the delegate draws as "?" rather than 0.
  readonly property var levelCells: {
    var cells = []
    for (var i = 0; i < Model.SEVERITY_ORDER.length; i++) {
      var level = Model.SEVERITY_ORDER[i]
      var value = view.counts ? view.counts[level] : null
      cells.push({
        level: level,
        count: (typeof value === "number" && isFinite(value)) ? value : null
      })
    }
    return cells
  }

  // The first few alerts, worst first then oldest. Nothing is listed while the
  // alert section is unknown, because the sort would be over rows that are not
  // there and the empty list would read as "nothing firing".
  readonly property var worstRows: {
    if (!view.countsKnown) return []
    return Model.alertRows(view.nasState ? view.nasState.alerts : null).slice(0, 4)
  }

  // ----------------------------------------------------------------- helpers

  function sectionWarned(name) {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === name) return true
    }
    return false
  }

  function sectionLabel(section) {
    switch (String(section || "")) {
      case "alert":     return "alerts"
      case "pool":      return "pools"
      case "system":    return "system info"
      case "normalize": return "the response"
      default:          return String(section || "") !== "" ? String(section) : "a section"
    }
  }

  // A warning entry carries `section`, `error` and `message`, which is the same
  // shape errorSentence reads, so the reason is named the same way the offline
  // line names it.
  function warningSentence(warning) {
    var reason = Model.errorSentence(warning)
    if (reason === "") reason = "did not answer"
    return "could not read " + view.sectionLabel(warning && warning.section)
      + ": " + reason
  }

  function levelColor(level) {
    switch (String(level || "")) {
      case "critical":
      case "error":   return view.panel.urgentColor
      case "warning": return Color.accent
      default:        return view.panel.dimForeground
    }
  }

  // ONLINE is the only good status; every other word, including the empty one
  // the poll writes when it cannot say, is drawn in the alarm colour.
  function poolStatusColor(status) {
    if (String(status || "").toUpperCase() === "ONLINE") return Color.accent
    return view.panel.urgentColor
  }

  function alertText(alert) {
    var text = String((alert && (alert.text || alert.formatted)) || "")
    if (text !== "") return text
    var node = String((alert && alert.node) || "")
    return node !== "" ? node : "untitled alert"
  }

  function alertAgeText(alert) {
    var seconds = Model.ageSeconds(alert && alert.datetime)
    return seconds < 0 ? "" : Model.ageText(seconds)
  }

  // ------------------------------------------------------------------ render

  // The status sentence, tinted by the connection rather than by the data:
  // green-ish for a healthy poll, urgent for no answer, accent for setup and
  // for a partial answer.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.statusLine
    color: view.statusColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  // One sentence per failed section, named and with the reason. This is what
  // the pools and alerts blocks below point at instead of "0 pools".
  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: view.warnings.length > 0

    Repeater {
      model: view.warnings

      Text {
        textFormat: Text.PlainText
        required property var modelData
        width: parent.width
        wrapMode: Text.WordWrap
        text: "• " + view.warningSentence(modelData)
        color: view.panel.urgentColor
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Local.Card {
    width: parent.width
    title: "SYSTEM"
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    fontFamily: view.panel.contentFontFamily
    visible: view.nasState !== null && !view.unconfigured

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      visible: view.system === null
      text: "system state unknown"
      color: view.panel.dimForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: view.facts

      InfoRow {
        required property var modelData
        label: modelData.label
        value: modelData.value
      }
    }
  }

  Local.Card {
    width: parent.width
    title: "POOLS"
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    fontFamily: view.panel.contentFontFamily
    // Hidden while the pool call is unknown: the warning above already says
    // why there is nothing here, and an empty card labelled POOLS would say
    // the NAS has no pools.
    visible: view.poolsKnown

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      visible: view.pools.length === 0
      text: "no pools on this NAS"
      color: view.panel.dimForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: view.pools

      Column {
        required property var modelData
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: String(modelData.status || "") !== ""
            ? String(modelData.status) : "status unknown"
          color: view.poolStatusColor(modelData.status)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Local.CapacityBar {
          width: parent.width
          name: String(modelData.name || "")
          allocated: modelData.allocated
          size: modelData.size
          usedPct: modelData.usedPct
          foreground: view.panel.contentForeground
          dimForeground: view.panel.dimForeground
          accentColor: Color.accent
          urgentColor: view.panel.urgentColor
          fontFamily: view.panel.contentFontFamily
        }
      }
    }
  }

  Local.Card {
    width: parent.width
    title: "ALERTS"
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    fontFamily: view.panel.contentFontFamily
    visible: view.connected

    Row {
      id: levelRow
      width: parent.width
      spacing: Style.space(4)
      visible: view.countsKnown
      readonly property real cellWidth: Math.floor(
        (width - spacing * (view.levelCells.length - 1)) / view.levelCells.length)

      Repeater {
        model: view.levelCells

        Column {
          required property var modelData
          width: levelRow.cellWidth
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: modelData.count === null ? "?" : String(modelData.count)
            // A zero is a real zero here and is dimmed; a null is unknown and
            // is dimmed for the same reason, never painted in an alarm colour
            // it has not earned.
            color: (modelData.count === null || modelData.count === 0)
              ? view.panel.dimForeground
              : view.levelColor(modelData.level)
            font.family: view.panel.contentFontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: modelData.level
            color: view.panel.dimForeground
            font.family: view.panel.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      visible: !view.countsKnown
      text: "Alert counts are unknown until the alerts section answers."
      color: view.panel.urgentColor
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Local.Card {
    width: parent.width
    title: "WORST RIGHT NOW"
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    fontFamily: view.panel.contentFontFamily
    visible: view.worstRows.length > 0

    Repeater {
      model: view.worstRows

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: worstText.implicitHeight + Style.space(6)

        Text {
          textFormat: Text.PlainText
          id: worstLevel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: String(modelData.level || "")
          color: view.levelColor(modelData.level)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          id: worstText
          anchors.left: worstLevel.right
          anchors.leftMargin: Style.space(6)
          anchors.right: worstAge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: view.alertText(modelData)
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          id: worstAge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          // The tick is a dependency: the age is recomputed every time it
          // moves, without a fresh poll.
          text: (view.panel.nowTick, view.alertAgeText(modelData))
          color: view.panel.dimForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // One label/value row inside a Card. The value is right-aligned and elided,
  // so a long hostname never pushes the label off the card.
  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
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
}
