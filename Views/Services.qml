import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model
import "../Search.js" as Search
import "../Links.js" as Links

// One card per service: the name and its state, the enable flag, and the three
// control verbs.
//
// The same refusals Views/Disks.qml makes, for the same reason: a failed
// services request leaves the list empty, and `warnings` names which, so an
// unread service list never renders as a NAS that runs nothing.
//
// Every verb goes through the panel's single ConfirmAction, because a misclick
// on a service row restarts something the NAS is using. The panel reads the
// NAS back after the write rather than trusting the verb's own answer.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property bool unconfigured: view.panel.mode === "unconfigured"
    || !!(view.connection && String(view.connection.error || "") === "unconfigured")
  readonly property var services: (view.nasState && Model.arrayLike(view.nasState.services))
    ? view.nasState.services : []
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings))
    ? view.nasState.warnings : []

  property string query: ""
  readonly property var rows: Search.services(view.services, view.query)

  // Only a failed services request turns this list into "I could not tell"; a
  // warning from another section leaves the rows themselves trustworthy.
  readonly property var serviceWarning: {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === "service")
        return view.warnings[i]
    }
    return null
  }

  readonly property string warningLine: {
    if (!view.serviceWarning) return ""
    var reason = String(view.serviceWarning.message || view.serviceWarning.error || "")
    return "the service list could not be read" + (reason !== "" ? ": " + reason : "")
  }

  // Empty only while there is something to show: the warning line already says
  // why the list is missing, and a filter that matches nothing says so itself.
  readonly property string emptyText: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (view.unconfigured) return "not configured yet · run truenasctl login <url>"
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (view.services.length > 0 && view.rows.length === 0) return "no services match the filter"
    if (view.services.length > 0) return ""
    if (view.serviceWarning) return ""
    return "no services reported"
  }

  readonly property string servicesUrl: Links.systemUrl(view.panel.baseUrl)

  // 0 healthy keeps the plain foreground, 1 down is urgent, and 2 unknown is
  // dim: "I cannot tell" must not look like a stopped service.
  function stateColor(service) {
    switch (Model.serviceStateRank(service && service.state)) {
      case 0:  return view.panel.contentForeground
      case 1:  return view.panel.urgentColor
      default: return view.panel.dimForeground
    }
  }

  function stateText(service) {
    var state = String(service && service.state || "")
    return state !== "" ? state : "unknown"
  }

  function enableText(service) {
    return service && service.enable === true ? "enabled" : "disabled"
  }

  function actionLabel(verb) {
    if (verb === "service-start") return "Start"
    if (verb === "service-stop") return "Stop"
    return "Restart"
  }

  // What the verb does to the service. A confirmation that names only the target
  // leaves the consequence to be guessed, and a misclick here drops connections.
  function consequence(verb) {
    if (verb === "service-start") return "It begins serving and stays up until stopped."
    if (verb === "service-stop") return "It stops serving until started again."
    return "Existing connections are dropped."
  }

  // The inapplicable verb is not offered: no Start on a running service, no Stop
  // on a stopped one. Restart is always available. A rank-2 unknown offers both,
  // because the panel cannot tell which one applies.
  function actionVisible(service, verb) {
    var rank = Model.serviceStateRank(service && service.state)
    if (verb === "service-start") return rank !== 0
    if (verb === "service-stop") return rank !== 1
    return true
  }

  // The confirmation, then the write, then a forced re-poll. `panel` is captured
  // rather than read back off `view`, because the panel's queue outlives a view
  // that is destroyed by a tab switch.
  function act(service, verb) {
    var panel = view.panel
    var name = String(service && service.service || "")
    if (name === "") return
    var label = view.actionLabel(verb)
    panel.requestConfirm(
      label + " the " + name + " service? " + view.consequence(verb),
      function() {
        panel.runApi(verb, name, function() {
          panel.actionNotice = name + " service " + label.toLowerCase() + " requested"
          panel.refreshAfterWrite()
        }, function() {
          panel.actionNotice = ""
        })
      },
      label)
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.servicesUrl !== ""
    text: Model.GLYPH.link + "  Open services in TrueNAS"
    color: openMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.openUrl(view.servicesUrl)
    }
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter services"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.query = value }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLine !== ""
    text: view.warningLine
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyText !== ""
    text: view.emptyText
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.rows

    Local.Card {
      id: serviceCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      Item {
        width: parent.width
        implicitHeight: Math.max(serviceName.implicitHeight, serviceState.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: serviceName
          anchors.left: parent.left
          anchors.right: serviceState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: String(modelData.service || "unnamed service")
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: serviceState
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: view.stateText(modelData)
          color: view.stateColor(modelData)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: view.enableText(modelData)
        color: modelData.enable === true ? view.panel.contentForeground : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Repeater {
          model: [
            { verb: "service-start", label: "start" },
            { verb: "service-stop", label: "stop" },
            { verb: "service-restart", label: "restart" }
          ]

          Text {
            textFormat: Text.PlainText
            required property var modelData
            text: modelData.label
            visible: view.actionVisible(serviceCard.modelData, modelData.verb)
            color: actionMouse.containsMouse ? Color.accent : view.panel.dimForeground
            font.family: view.panel.contentFontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              id: actionMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: view.act(serviceCard.modelData, modelData.verb)
            }
          }
        }
      }
    }
  }
}
