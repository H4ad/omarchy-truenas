import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model
import "../Search.js" as Search
import "../Links.js" as Links

// The protection inventory: replication, cloud sync, periodic snapshot tasks
// and scrub tasks, one section each. Every run-now goes through the panel's
// single confirmation and its one write queue, then a forced re-poll, so the
// panel reads the NAS back rather than trusting the verb's stdout.
//
// The same refusal Views/Services.qml makes: a failed section leaves its list
// empty, and `warnings` names which, so an unread section never renders as a NAS
// with no protection tasks at all.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property bool unconfigured: view.panel.mode === "unconfigured"
    || !!(view.connection && String(view.connection.error || "") === "unconfigured")
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings))
    ? view.nasState.warnings : []

  readonly property var replication: (view.nasState && Model.arrayLike(view.nasState.replication))
    ? view.nasState.replication : []
  readonly property var cloudSync: (view.nasState && Model.arrayLike(view.nasState.cloudSync))
    ? view.nasState.cloudSync : []
  readonly property var snapshotTasks: (view.nasState && Model.arrayLike(view.nasState.snapshotTasks))
    ? view.nasState.snapshotTasks : []
  readonly property var scrubs: (view.nasState && Model.arrayLike(view.nasState.scrubs))
    ? view.nasState.scrubs : []

  property string replicationQuery: ""
  property string cloudSyncQuery: ""
  property string snapshotQuery: ""
  property string scrubQuery: ""

  readonly property var replicationRows: Search.replication(view.replication, view.replicationQuery)
  readonly property var cloudSyncRows: Search.cloudSync(view.cloudSync, view.cloudSyncQuery)
  readonly property var snapshotRows: Search.snapshotTasks(view.snapshotTasks, view.snapshotQuery)
  readonly property var scrubRows: Search.scrubs(view.scrubs, view.scrubQuery)

  readonly property string protectionUrl: Links.systemUrl(view.panel.baseUrl)

  // The `warnings` entry for one section, or null. Only that section's own
  // failure turns its list into "I could not tell".
  function sectionWarning(section) {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === section)
        return view.warnings[i]
    }
    return null
  }

  function warningLineFor(section, noun) {
    var warning = view.sectionWarning(section)
    if (!warning) return ""
    var reason = String(warning.message || warning.error || "")
    return "the " + noun + " could not be read" + (reason !== "" ? ": " + reason : "")
  }

  // Empty only while there is something to show: the warning line already says
  // why the list is missing, and a filter that matches nothing says so itself.
  function emptyFor(section, total, shown, noun) {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (view.unconfigured) return "not configured yet · run truenasctl login <url>"
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (total > 0 && shown === 0) return "no " + noun + " match the filter"
    if (total > 0) return ""
    if (view.sectionWarning(section)) return ""
    return "no " + noun + " reported"
  }

  // 0 healthy keeps the plain foreground, 1 failed is urgent, and 2 (blank or
  // transitional) is dim: "I cannot tell" must not look like a failure.
  function stateColor(state) {
    switch (Model.protectionStateRank(state)) {
      case 0:  return view.panel.contentForeground
      case 1:  return view.panel.urgentColor
      default: return view.panel.dimForeground
    }
  }

  function stateText(state) {
    var text = String(state || "")
    return text !== "" ? text : "unknown"
  }

  function lastRunText(value) {
    var text = String(value || "")
    return text !== "" ? text : "never run"
  }

  function joinDetail(parts) {
    var out = []
    for (var i = 0; i < parts.length; i++) {
      if (String(parts[i] || "") !== "") out.push(parts[i])
    }
    return out.join(" · ")
  }

  // The confirmation, then the write, then a forced re-poll. `panel` is captured
  // rather than read back off `view`, because the panel's queue outlives a view
  // that is destroyed by a tab switch.
  function act(verb, target, message, label) {
    var panel = view.panel
    if (String(target || "") === "") return
    panel.requestConfirm(message, function() {
      panel.runApi(verb, String(target), function() {
        panel.actionNotice = label + " requested"
        panel.refreshAfterWrite()
      }, function() {
        panel.actionNotice = ""
      })
    }, label)
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.protectionUrl !== ""
    text: Model.GLYPH.link + "  Open protection in TrueNAS"
    color: openMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.openUrl(view.protectionUrl)
    }
  }

  // ------------------------------------------------------------- replication
  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "REPLICATION"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter replication tasks"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.replicationQuery = value }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("replication", "replication task list") !== ""
    text: view.warningLineFor("replication", "replication task list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("replication", view.replication.length, view.replicationRows.length,
                           "replication tasks") !== ""
    text: view.emptyFor("replication", view.replication.length, view.replicationRows.length,
                        "replication tasks")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.replicationRows

    Local.Card {
      id: replicationCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string label: Model.protectionLabel(modelData) || "unnamed task"
      readonly property string detailLine: view.joinDetail([
        String(modelData.direction || ""), String(modelData.transport || ""),
        String(modelData.targetDataset || "")])
      readonly property string scheduleLine: Model.scheduleText(modelData.schedule)
      readonly property string runLine: view.lastRunText(modelData.job && modelData.job.timeFinished)

      Item {
        width: parent.width
        implicitHeight: Math.max(replicationName.implicitHeight, replicationState.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: replicationName
          anchors.left: parent.left
          anchors.right: replicationState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: replicationCard.label
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: replicationState
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: view.stateText(Model.protectionState(replicationCard.modelData))
          color: view.stateColor(Model.protectionState(replicationCard.modelData))
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: replicationCard.detailLine !== ""
        text: replicationCard.detailLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: replicationCard.scheduleLine !== ""
        text: "schedule " + replicationCard.scheduleLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "last run " + replicationCard.runLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: "run now"
        color: replicationRunMouse.containsMouse ? Color.accent : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: replicationRunMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.act("replication-run", replicationCard.modelData.id,
            "Run replication " + replicationCard.label + " now? It starts a replication job.",
            "Run now")
        }
      }
    }
  }

  // -------------------------------------------------------------- cloud sync
  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "CLOUD SYNC"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter cloud sync tasks"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.cloudSyncQuery = value }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("cloudSync", "cloud sync task list") !== ""
    text: view.warningLineFor("cloudSync", "cloud sync task list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("cloudSync", view.cloudSync.length, view.cloudSyncRows.length,
                           "cloud sync tasks") !== ""
    text: view.emptyFor("cloudSync", view.cloudSync.length, view.cloudSyncRows.length,
                        "cloud sync tasks")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.cloudSyncRows

    Local.Card {
      id: cloudSyncCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string label: Model.protectionLabel(modelData) || "unnamed task"
      readonly property string detailLine: view.joinDetail([
        String(modelData.direction || ""), String(modelData.transferMode || ""),
        String(modelData.path || "")])
      readonly property string scheduleLine: Model.scheduleText(modelData.schedule)
      readonly property string runLine: view.lastRunText(modelData.job && modelData.job.timeFinished)

      Item {
        width: parent.width
        implicitHeight: Math.max(cloudSyncName.implicitHeight, cloudSyncState.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: cloudSyncName
          anchors.left: parent.left
          anchors.right: cloudSyncState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: cloudSyncCard.label
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: cloudSyncState
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: view.stateText(Model.protectionState(cloudSyncCard.modelData))
          color: view.stateColor(Model.protectionState(cloudSyncCard.modelData))
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: cloudSyncCard.detailLine !== ""
        text: cloudSyncCard.detailLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: cloudSyncCard.scheduleLine !== ""
        text: "schedule " + cloudSyncCard.scheduleLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "last run " + cloudSyncCard.runLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: "sync now"
        color: cloudSyncRunMouse.containsMouse ? Color.accent : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: cloudSyncRunMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.act("cloudsync-sync", cloudSyncCard.modelData.id,
            "Sync " + cloudSyncCard.label + " now? It starts a cloud sync job.",
            "Sync now")
        }
      }
    }
  }

  // ---------------------------------------------------------- snapshot tasks
  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "SNAPSHOT TASKS"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter snapshot tasks"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.snapshotQuery = value }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("snapshotTasks", "snapshot task list") !== ""
    text: view.warningLineFor("snapshotTasks", "snapshot task list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("snapshotTasks", view.snapshotTasks.length, view.snapshotRows.length,
                           "snapshot tasks") !== ""
    text: view.emptyFor("snapshotTasks", view.snapshotTasks.length, view.snapshotRows.length,
                        "snapshot tasks")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.snapshotRows

    Local.Card {
      id: snapshotCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string label: Model.protectionLabel(modelData) || "unnamed task"
      readonly property string scheduleLine: Model.scheduleText(modelData.schedule)
      readonly property string snapshotLine: String(
        modelData.state && modelData.state.lastSnapshot || "")

      Item {
        width: parent.width
        implicitHeight: Math.max(snapshotName.implicitHeight, snapshotState.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: snapshotName
          anchors.left: parent.left
          anchors.right: snapshotState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: snapshotCard.label
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: snapshotState
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: view.stateText(Model.protectionState(snapshotCard.modelData))
          color: view.stateColor(Model.protectionState(snapshotCard.modelData))
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: snapshotCard.scheduleLine !== ""
        text: "schedule " + snapshotCard.scheduleLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: snapshotCard.snapshotLine !== ""
          ? "last snapshot " + snapshotCard.snapshotLine
          : "no snapshot on record"
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: "run now"
        color: snapshotRunMouse.containsMouse ? Color.accent : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: snapshotRunMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.act("snapshot-run", snapshotCard.modelData.id,
            "Run the snapshot task for " + snapshotCard.label + " now? It creates a snapshot immediately.",
            "Run now")
        }
      }
    }
  }

  // ---------------------------------------------------------------- scrubs
  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "SCRUB TASKS"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter scrub tasks"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.scrubQuery = value }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("scrubs", "scrub task list") !== ""
    text: view.warningLineFor("scrubs", "scrub task list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("scrubs", view.scrubs.length, view.scrubRows.length,
                           "scrub tasks") !== ""
    text: view.emptyFor("scrubs", view.scrubs.length, view.scrubRows.length, "scrub tasks")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.scrubRows

    Local.Card {
      id: scrubCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string label: Model.protectionLabel(modelData) || "unnamed pool"
      readonly property string scheduleLine: Model.scheduleText(modelData.schedule)
      readonly property string detailLine: {
        var parts = []
        parts.push(modelData.enabled === true ? "enabled" : "disabled")
        if (modelData.threshold !== null && modelData.threshold !== undefined)
          parts.push("threshold " + modelData.threshold + "d")
        if (String(modelData.description || "") !== "")
          parts.push(String(modelData.description))
        return parts.join(" · ")
      }

      Item {
        width: parent.width
        implicitHeight: scrubName.implicitHeight

        Text {
          textFormat: Text.PlainText
          id: scrubName
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: scrubCard.label
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: scrubCard.detailLine
        color: scrubCard.modelData.enabled === true
          ? view.panel.contentForeground : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: scrubCard.scheduleLine !== ""
        text: "schedule " + scrubCard.scheduleLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: "start scrub"
        color: scrubRunMouse.containsMouse ? Color.accent : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: scrubRunMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.act("scrub-start", scrubCard.modelData.pool,
            "Start a scrub on " + scrubCard.label + " now? It scans the whole pool and can take hours.",
            "Start scrub")
        }
      }
    }
  }
}
