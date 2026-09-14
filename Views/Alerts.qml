import QtQuick
import qs.Commons
import "../Model.js" as Model
import "../Links.js" as Links

// The alerts tab: one row per alert, worst first, and the one write a row
// offers. A row is a report, not a form, so the only thing it can do is silence
// the alert or bring it back, and both go through the panel's single write
// queue.
//
// Dismiss is destructive, because it stops the notification stream for that
// alert, so it is armed through the panel's ConfirmAction first. Restore is not,
// so it goes straight out. Neither trusts the write's own answer: the callback
// asks for a forced re-poll and the list redraws from that state.
//
// The link out is built from the panel's configured base, never from alert
// text, so a row can point at the NAS and nowhere else.
Column {
  id: view
  required property var panel
  spacing: Style.space(8)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property var alerts: (view.nasState && Model.arrayLike(view.nasState.alerts)) ? view.nasState.alerts : []
  readonly property var rows: Model.alertRows(view.alerts)
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings)) ? view.nasState.warnings : []

  // The poller names a failed section in `warnings`, and only a failed alert
  // request turns the whole list into "I could not tell": a warning from another
  // section leaves the alerts themselves trustworthy.
  readonly property var alertWarning: {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === "alert")
        return view.warnings[i]
    }
    return null
  }
  readonly property bool alertFailed: view.alertWarning !== null

  // Re-read the clock when the panel's timer ticks, so an age on screen is the
  // age now rather than the age when the state last moved.
  readonly property var now: (view.panel.nowTick, Date.now())

  readonly property string alertsUrl: Links.alertsUrl(view.panel.baseUrl)

  // A failed alert section and an empty list are different facts, and only one
  // of them may be shown. Each sentence is empty exactly when the other is not,
  // so "I could not tell" can never read as "nothing is wrong".
  readonly property string warningLine: {
    if (!view.alertFailed) return ""
    var warning = view.alertWarning
    var sentence = Model.errorSentence({
      connection: { error: String(warning.error || ""), message: String(warning.message || "") } })
    return "The alert list did not answer: " + (sentence || String(warning.error || "the request failed"))
  }
  readonly property string statusLine: {
    if (view.alertFailed) return ""
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (view.rows.length === 0) {
      var dismissed = (view.nasState.counts && view.nasState.counts.dismissed) || 0
      if (dismissed > 0) return "Nothing is firing; " + dismissed + " dismissed"
      return "Nothing is firing"
    }
    return ""
  }

  function levelGlyph(level) {
    switch (String(level || "")) {
      case "critical":
      case "error":   return Model.GLYPH.critical
      case "warning": return Model.GLYPH.degraded
      default:        return Model.GLYPH.firing
    }
  }

  function levelColor(level) {
    switch (String(level || "")) {
      case "critical":
      case "error":   return view.panel.urgentColor
      case "warning": return Color.accent
      default:        return view.panel.dimForeground
    }
  }

  // Everything the state can say about a row in one line: the level as a word,
  // so colour is not the only thing carrying it, the node that raised it, how
  // long ago, and when. A missing datetime reads "never" through ageText rather
  // than a fabricated zero.
  function metaLine(alert) {
    var parts = []
    if (alert.level) parts.push(String(alert.level).toUpperCase())
    if (alert.node) parts.push(String(alert.node))
    parts.push("age " + Model.ageText(Model.ageSeconds(alert.datetime, view.now)))
    if (alert.datetime) parts.push("since " + String(alert.datetime))
    if (alert.dismissed) parts.push("dismissed")
    return parts.join(" · ")
  }

  function act(alert, verb) {
    if (!alert || !alert.uuid) return
    view.panel.runApi([verb, String(alert.uuid)], function() {
      view.panel.actionNotice = verb === "dismiss" ? "alert dismissed" : "alert restored"
      view.panel.refreshAfterWrite()
    })
  }

  function runDismiss(alert) {
    // Silencing an alert stops notifying about it until it is restored, so it
    // goes through the one ConfirmAction instead of a single click.
    view.panel.requestConfirm(
      "Dismiss \"" + String(alert.text || "this alert") + "\"? It stops notifying until it is restored.",
      function() { view.act(alert, "dismiss") },
      "Dismiss")
  }

  function runRestore(alert) {
    view.act(alert, "restore")
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.alertsUrl !== ""
    text: Model.GLYPH.link + "  Open alerts in TrueNAS"
    color: openMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.openUrl(view.alertsUrl)
    }
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
    visible: view.statusLine !== ""
    text: view.statusLine
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Column {
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: view.rows

      Item {
        id: alertRow
        required property var modelData
        readonly property var alertData: modelData
        // A plain alert has a dismiss action; a dismissed one has restore. An
        // alert the NAS marked not dismissable has neither, and the row keeps
        // its ordinary shape.
        readonly property bool canAct: alertData.dismissed || alertData.dismissable
        width: parent.width
        implicitHeight: rowContent.implicitHeight + Style.space(6)

        Column {
          id: rowContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(4)
          anchors.rightMargin: Style.space(4)
          spacing: Style.space(2)

          Item {
            width: parent.width
            implicitHeight: Math.max(levelText.implicitHeight, bodyText.implicitHeight, actionText.implicitHeight)

            Text {
              id: levelText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: view.levelGlyph(alertRow.alertData.level)
              color: view.levelColor(alertRow.alertData.level)
              font.family: view.panel.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: bodyText
              anchors.left: levelText.right
              anchors.leftMargin: Style.space(8)
              anchors.right: actionText.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              text: String(alertRow.alertData.text || "")
              color: view.panel.contentForeground
              font.family: view.panel.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: actionText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: alertRow.canAct
              // Zero-width rather than gone, because bodyText is anchored to
              // this item's left edge and must fall back to the row's edge.
              width: alertRow.canAct ? implicitWidth : 0
              text: alertRow.alertData.dismissed ? "restore" : "dismiss"
              color: actionMouse.containsMouse ? Color.accent : view.panel.dimForeground
              font.family: view.panel.contentFontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: actionMouse
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: alertRow.alertData.dismissed
                  ? view.runRestore(alertRow.alertData)
                  : view.runDismiss(alertRow.alertData)
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: view.metaLine(alertRow.alertData)
            color: view.panel.dimForeground
            font.family: view.panel.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
