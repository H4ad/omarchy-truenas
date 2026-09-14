import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model
import "../Search.js" as Search
import "../Links.js" as Links

// One card per app: the label and its state, the version and train, an update
// marker when the NAS reports one, and the three control verbs.
//
// The same refusals Views/Disks.qml makes, for the same reason: a failed apps
// request leaves the list empty, and `warnings` names which, so an unread app
// list never renders as a NAS that runs nothing.
//
// Every verb goes through the panel's single ConfirmAction, because a misclick
// on an app row stops or redeploys something the NAS is serving. The panel reads
// the NAS back after the write; app writes answer a job id and land
// asynchronously, so the next poll catches up rather than a fabricated state.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property var apps: (view.nasState && Model.arrayLike(view.nasState.apps))
    ? view.nasState.apps : []
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings))
    ? view.nasState.warnings : []

  property string query: ""
  readonly property var rows: Search.apps(view.apps, view.query)

  // Only a failed apps request turns this list into "I could not tell"; a warning
  // from another section leaves the rows themselves trustworthy.
  readonly property var appWarning: {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === "app")
        return view.warnings[i]
    }
    return null
  }

  readonly property string warningLine: {
    if (!view.appWarning) return ""
    var reason = String(view.appWarning.message || view.appWarning.error || "")
    return "the app list could not be read" + (reason !== "" ? ": " + reason : "")
  }

  // The updates summary prints only when the app list itself is trustworthy and
  // at least one row carries an update. A failed app request already prints its
  // reason above; a zero count is the absence of this line, never a "0".
  readonly property string updatesLine: {
    if (view.appWarning) return ""
    var count = Model.appsUpgradeable(view.apps)
    if (count === 0) return ""
    return count + (count === 1 ? " update available" : " updates available")
  }

  // Empty only while there is something to show: the warning line already says
  // why the list is missing, and a filter that matches nothing says so itself.
  readonly property string emptyText: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (view.apps.length > 0 && view.rows.length === 0) return "no apps match the filter"
    if (view.apps.length > 0) return ""
    if (view.appWarning) return ""
    return "no apps reported"
  }

  readonly property string appsUrl: Links.appsUrl(view.panel.baseUrl)

  // 0 healthy keeps the plain foreground, 1 down is urgent, and 2 (blank or
  // transitional) is dim: "I cannot tell" must not look like a stopped app.
  function stateColor(app) {
    switch (Model.appStateRank(app && app.state)) {
      case 0:  return view.panel.contentForeground
      case 1:  return view.panel.urgentColor
      default: return view.panel.dimForeground
    }
  }

  function stateText(app) {
    var state = String(app && app.state || "")
    return state !== "" ? state : "unknown"
  }

  // The version line, each part drawn only when the poll reported it. A missing
  // version leaves the line short rather than reading as a blank release.
  function detailText(app) {
    if (!app || typeof app !== "object") return ""
    var parts = []
    var version = String(app.version || "")
    var train = String(app.train || "")
    if (version !== "") parts.push("version " + version)
    if (train !== "") parts.push(train)
    return parts.join(" · ")
  }

  function webuiUrl(app) {
    return String(app && app.webui && app.webui.url || "")
  }

  function webuiLabel(app) {
    return String(app && app.webui && app.webui.label || "")
  }

  // The portal, admitted only when Links.safeUrl accepts it against the
  // configured base. A portal on another origin would otherwise render a link
  // that opens nothing at all.
  function webuiSafeUrl(app) {
    return Links.safeUrl(view.webuiUrl(app), view.panel.baseUrl)
  }

  function actionLabel(verb) {
    if (verb === "app-start") return "Start"
    if (verb === "app-stop") return "Stop"
    return "Redeploy"
  }

  // What the verb does to the app. A confirmation that names only the target
  // leaves the consequence to be guessed, and a misclick here stops a service.
  function consequence(verb) {
    if (verb === "app-start") return "It is deployed and begins serving."
    if (verb === "app-stop") return "It stops serving until started again."
    return "It is stopped and rebuilt from its image."
  }

  // The inapplicable verb is not offered: no Start on a running app, no Stop on
  // a stopped one. Redeploy is always available. A rank-2 transitional app
  // offers both, because the panel cannot tell which one applies.
  function actionVisible(app, verb) {
    var rank = Model.appStateRank(app && app.state)
    if (verb === "app-start") return rank !== 0
    if (verb === "app-stop") return rank !== 1
    return true
  }

  // The confirmation, then the write, then a forced re-poll. `panel` is captured
  // rather than read back off `view`, because the panel's queue outlives a view
  // that is destroyed by a tab switch.
  function act(app, verb) {
    var panel = view.panel
    var name = String(app && app.name || "")
    if (name === "") return
    var label = view.actionLabel(verb)
    var named = Model.appLabel(app) || name
    panel.requestConfirm(
      label + " the " + named + " app? " + view.consequence(verb),
      function() {
        panel.runApi([verb, name], function() {
          panel.actionNotice = named + " " + label.toLowerCase() + " requested"
          panel.refreshAfterWrite()
        }, function() {
          panel.actionNotice = ""
        })
      },
      label)
  }

  // The apps page is the fallback for an app with no webui: this one line opens
  // the list, and each card offers its own webui when the poll reported one.
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.appsUrl !== ""
    text: Model.GLYPH.link + "  Open apps in TrueNAS"
    color: openMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.openUrl(view.appsUrl)
    }
  }

  // The updates summary, under the header: how many of the listed apps the NAS
  // reports an update for. Nothing at all when the count is zero.
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.updatesLine !== ""
    text: view.updatesLine
    color: Color.accent
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter apps"
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
      id: appCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string detailLine: view.detailText(modelData)
      readonly property bool hasUpdate: modelData.upgradeAvailable === true
      readonly property string webuiUrl: view.webuiSafeUrl(modelData)
      readonly property string webuiLabel: view.webuiLabel(modelData)

      Item {
        width: parent.width
        implicitHeight: Math.max(appName.implicitHeight, appState.implicitHeight)

        Text {
          id: appName
          anchors.left: parent.left
          anchors.right: appState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: Model.appLabel(modelData) !== "" ? Model.appLabel(modelData) : "unnamed app"
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: appState
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
        width: parent.width
        wrapMode: Text.WordWrap
        visible: appCard.detailLine !== ""
        text: appCard.detailLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: appCard.hasUpdate
        text: "update available"
        color: Color.accent
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Repeater {
          model: [
            { verb: "app-start", label: "start" },
            { verb: "app-stop", label: "stop" },
            { verb: "app-redeploy", label: "redeploy" }
          ]

          Text {
            required property var modelData
            text: modelData.label
            visible: view.actionVisible(appCard.modelData, modelData.verb)
            color: actionMouse.containsMouse ? Color.accent : view.panel.dimForeground
            font.family: view.panel.contentFontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              id: actionMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: view.act(appCard.modelData, modelData.verb)
            }
          }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        visible: appCard.webuiUrl !== ""
        text: Model.GLYPH.link + "  Open "
          + (appCard.webuiLabel !== "" ? appCard.webuiLabel : "the web UI")
        color: webuiMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: webuiMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.panel.openUrl(appCard.webuiUrl)
        }
      }
    }
  }
}
