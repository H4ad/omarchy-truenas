import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model
import "Links.js" as Links
import "Redact.js" as Redact

// The summoned menu surface: `omarchy-shell shell summon io.github.h4ad.truenas`
// lands here rather than on the bar item, so the popout itself stays on
// left-click. Every row either asks the live bar widget to open the popout or
// runs bin/truenas-poll, so this file never talks to a NAS and there is still
// exactly one implementation of each verb.
//
// The base is named `Ui.Panel` rather than `Panel`: this directory has its own
// Panel.qml, and the qualification leaves no doubt that the shell's base is
// meant. It is a menu, so `manageIpc` is off: the bar widget owns the single
// IpcHandler the io.github.h4ad.truenas target allows, and a second handler on
// the same target is a collision.
Ui.Panel {
  id: root

  moduleName: "io.github.h4ad.truenas"
  ipcTarget: "io.github.h4ad.truenas"
  manageIpc: false

  // Injected by omarchy-shell when the plugin is summoned.
  property var shell: null
  property var manifest: null

  // What the last poll wrote to state.json, and nothing else. Redacted for
  // display, the same way the bar redacts it, so a recording cannot leak a value
  // the bar hid.
  property var rawSnapshot: null
  property var snapshot: Redact.apply(root.rawSnapshot, root.redactLevel)
  property int selectedIndex: 0
  property string busyLabel: ""
  property string notice: ""

  readonly property string pluginId:
    manifest && manifest.id ? String(manifest.id) : "io.github.h4ad.truenas"
  readonly property string statePath:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/truenas/state.json"
  readonly property string pollPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/truenas-poll")).replace(/^file:\/\//, ""))

  readonly property var counts: (snapshot && snapshot.counts) || ({})
  readonly property var pools: (snapshot && Model.arrayLike(snapshot.pools)) ? snapshot.pools : []
  readonly property var disks: (snapshot && Model.arrayLike(snapshot.disks)) ? snapshot.disks : []
  readonly property var services: (snapshot && Model.arrayLike(snapshot.services)) ? snapshot.services : []
  readonly property var apps: (snapshot && Model.arrayLike(snapshot.apps)) ? snapshot.apps : []
  readonly property var replication: (snapshot && Model.arrayLike(snapshot.replication)) ? snapshot.replication : []
  readonly property var cloudSync: (snapshot && Model.arrayLike(snapshot.cloudSync)) ? snapshot.cloudSync : []
  readonly property var snapshotTasks: (snapshot && Model.arrayLike(snapshot.snapshotTasks)) ? snapshot.snapshotTasks : []
  readonly property var scrubs: (snapshot && Model.arrayLike(snapshot.scrubs)) ? snapshot.scrubs : []
  readonly property var shares: (snapshot && snapshot.shares) ? snapshot.shares : null
  readonly property var network: (snapshot && Model.arrayLike(snapshot.network)) ? snapshot.network : []
  readonly property string mode: Model.mode(snapshot)
  readonly property var connection: (snapshot && snapshot.connection) || null
  readonly property bool connected: !!(connection && connection.ok)
  readonly property var warnings: (snapshot && Model.arrayLike(snapshot.warnings)) ? snapshot.warnings : []

  // A section failure names the section in `warnings`; only the failed request's
  // own summary may turn into "I could not tell", exactly as Views/Alerts.qml and
  // Views/Pools.qml decide it.
  readonly property var alertWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "alert")
        return root.warnings[i]
    }
    return null
  }
  readonly property var poolWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "pool")
        return root.warnings[i]
    }
    return null
  }
  readonly property var diskWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "disk")
        return root.warnings[i]
    }
    return null
  }
  readonly property var diskTempWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "diskTemp")
        return root.warnings[i]
    }
    return null
  }
  readonly property var serviceWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "service")
        return root.warnings[i]
    }
    return null
  }
  readonly property var appWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "app")
        return root.warnings[i]
    }
    return null
  }
  readonly property var replicationWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "replication")
        return root.warnings[i]
    }
    return null
  }
  readonly property var cloudSyncWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "cloudSync")
        return root.warnings[i]
    }
    return null
  }
  readonly property var snapshotWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "snapshotTasks")
        return root.warnings[i]
    }
    return null
  }
  readonly property var scrubWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "scrubs")
        return root.warnings[i]
    }
    return null
  }
  readonly property var smbWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "smb")
        return root.warnings[i]
    }
    return null
  }
  readonly property var nfsWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "nfs")
        return root.warnings[i]
    }
    return null
  }
  readonly property var iscsiWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "iscsi")
        return root.warnings[i]
    }
    return null
  }
  readonly property var networkWarning: {
    for (var i = 0; i < root.warnings.length; i++) {
      if (String(root.warnings[i] && root.warnings[i].section || "") === "network")
        return root.warnings[i]
    }
    return null
  }

  // Configured means a base URL exists, or the state can name a reason other
  // than "unconfigured". The poller writes schema:1 even when there is nothing
  // to log in to, so schema alone would call an empty setup reachable.
  readonly property bool configured:
    root.baseUrl !== ""
    || !!(connection && String(connection.error || "") !== "unconfigured")

  // The bar widget already reads config.json to know the base URL, so the menu
  // asks it rather than reading the same file a second time.
  readonly property string baseUrl: {
    var widget = root.panelWidget()
    return widget && typeof widget.configuredBase === "function"
      ? String(widget.configuredBase() || "")
      : ""
  }

  // The level the bar widget resolved, so the menu and the bar never disagree
  // about what is hidden. The widget is the single reader of config.json.
  readonly property string redactLevel:
    Redact.normalize(root.widgetRedactLevel())

  function widgetRedactLevel() {
    var widget = root.panelWidget()
    return widget && widget.redactLevel !== undefined ? String(widget.redactLevel) : ""
  }

  // The base URL as printed, never as linked: dashboardUrl() keeps the real one.
  readonly property string displayBase:
    Redact.url(root.baseUrl, root.redactLevel)

  readonly property color statusColor: {
    if (!root.snapshot || !root.configured) return Color.menu.text
    if (!root.connected) return Color.urgent
    return (root.counts.critical || 0) > 0 || (root.counts.error || 0) > 0
      ? Color.urgent
      : Color.menu.text
  }

  // Reachable, or the sentence that says why not. An unknown state is a
  // sentence too, never a blank line that could read as "fine".
  readonly property string statusText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet · run truenasctl login <url>"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    var system = root.snapshot.system || {}
    var host = String(system.hostname || "")
    return "connected" + (host !== "" ? " to " + host : "")
  }

  // An empty pool list is only "no pools" when a pool request actually answered;
  // offline and a failed section each get the reason instead of a count.
  readonly property string poolsText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.poolWarning) return "the pool state could not be read"
    if (!root.pools.length) return "no pools reported"
    var worst = Model.worstPool(root.pools)
    var text = root.pools.length + (root.pools.length === 1 ? " pool" : " pools")
    if (worst) text += " · worst " + String(worst.name || "") + " " + String(worst.status || "")
    return text
  }

  // A failed disk request leaves the list empty too, so "no disks reported"
  // prints only when neither disk section warned.
  readonly property string disksText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.diskWarning) return "the disk list could not be read"
    if (root.diskTempWarning) return "the disk temperatures could not be read"
    if (!root.disks.length) return "no disks reported"
    return root.disks.length + (root.disks.length === 1 ? " disk" : " disks")
  }

  // A failed services request leaves the list empty too, so the counts print
  // only when the service section warned about nothing. Down and unknown are
  // reported apart: an unknown is a service mid-transition, never "nothing
  // down", and a zero count is a phrase rather than the number "0".
  readonly property string servicesText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.serviceWarning) return "the service list could not be read"
    if (!root.services.length) return "no services reported"
    var down = Model.downServices(root.services).length
    var unknown = Model.unknownServices(root.services).length
    if (down > 0 && unknown > 0) return down + " down, " + unknown + " unknown"
    if (down > 0) return down + " down"
    if (unknown > 0) return unknown + " unknown"
    return "nothing down"
  }

  // The same rule for apps: a failed app request prints why, never a count, and
  // a transitional state is unknown rather than down.
  readonly property string appsText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.appWarning) return "the app list could not be read"
    if (!root.apps.length) return "no apps reported"
    var down = Model.downApps(root.apps).length
    var unknown = Model.unknownApps(root.apps).length
    if (down > 0 && unknown > 0) return down + " down, " + unknown + " unknown"
    if (down > 0) return down + " down"
    if (unknown > 0) return unknown + " unknown"
    return "nothing down"
  }

  // Shares and interfaces. The three share types and the interface list each
  // fail on their own, so any one warning prints the sentence rather than a
  // count a failed section zeroed. A down link is named; a blank or unknown
  // link is not a warning. Never "0 shares": an empty list prints a phrase.
  readonly property string sharesText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.smbWarning || root.nfsWarning || root.iscsiWarning || root.networkWarning)
      return "the shares and network could not be read"
    var counts = Model.shareCounts(root.shares)
    if (counts.total === 0 && root.network.length === 0) return "no shares reported"
    if (counts.total === 0) return "no shares"
    var text = counts.total + (counts.total === 1 ? " share" : " shares")
    var down = Model.downInterfaces(root.network).length
    if (down > 0) return text + " · " + down + (down === 1 ? " link down" : " links down")
    return text
  }

  // Protection: replication and cloud sync carry a job, so a failed one is a
  // real failure; snapshot tasks and scrub tasks do not, so only the count is
  // reported. A failed section prints why rather than a count.
  readonly property string protectionText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    if (root.replicationWarning || root.cloudSyncWarning
        || root.snapshotWarning || root.scrubWarning)
      return "the protection tasks could not be read"
    var failed = Model.failedReplications(root.replication).length
      + Model.failedCloudSync(root.cloudSync).length
    var overdue = Model.protectionOverdue(root.snapshot)
    if (failed > 0 && overdue > 0)
      return failed + (failed === 1 ? " task failed" : " tasks failed") + ", "
        + overdue + (overdue === 1 ? " task overdue" : " tasks overdue")
    if (failed > 0) return failed + (failed === 1 ? " task failed" : " tasks failed")
    if (overdue > 0) return overdue + (overdue === 1 ? " task overdue" : " tasks overdue")
    var total = root.replication.length + root.cloudSync.length
      + root.snapshotTasks.length + root.scrubs.length
    if (total === 0) return "no protection tasks reported"
    return total + (total === 1 ? " task" : " tasks") + ", nothing overdue"
  }

  // "Nothing firing" is only true of a connected NAS whose alert request
  // answered; an offline or failed-alert state prints why, never the phrase.
  readonly property string alertsText: {
    if (!root.snapshot) return "no state yet, the poller has not run"
    if (!root.configured) return "not configured yet"
    if (root.alertWarning) return "the alert list did not answer"
    if (!root.connected) {
      var reason = Model.errorSentence(root.connection)
      return "unreachable" + (reason !== "" ? ": " + reason : "")
    }
    var phrase = Model.countPhrase(root.counts)
    return phrase === "" ? "nothing firing" : phrase
  }

  readonly property string configText: {
    if (!root.snapshot) return ""
    if (!root.configured) return "not configured yet"
    return root.displayBase !== "" ? root.displayBase : "no base URL set"
  }

  readonly property string pollText: root.snapshot
    ? "last checked " + Model.ageText(Model.ageSeconds(root.snapshot.updatedAt, Date.now())) + " ago"
    : "the poller has not run"

  // Health is the popout's default view, so the first row opens the popout and
  // every later row lands on one specific tab. The NAS UI is offered only when
  // the widget can produce a URL out of the configured base.
  readonly property var rows: {
    var list = [
      { kind: "view", args: ["health"], label: "Health", detail: root.statusText },
      { kind: "view", args: ["pools"], label: "Pools", detail: root.poolsText },
      { kind: "view", args: ["disks"], label: "Disks", detail: root.disksText },
      { kind: "view", args: ["services"], label: "Services", detail: root.servicesText },
      { kind: "view", args: ["apps"], label: "Apps", detail: root.appsText },
      { kind: "view", args: ["shares"], label: "Shares", detail: root.sharesText },
      { kind: "view", args: ["protection"], label: "Protection", detail: root.protectionText },
      { kind: "view", args: ["alerts"], label: "Alerts", detail: root.alertsText },
      { kind: "view", args: ["config"], label: "Config", detail: root.configText },
      { kind: "help", args: [], label: "Help", detail: "what the words mean" },
      { kind: "poll", args: [], label: "Poll now", detail: root.pollText }
    ]
    if (root.dashboardUrl() !== "")
      list.push({ kind: "open", args: [], label: "Open the NAS UI",
                  detail: Links.baseUrl(root.displayBase) })
    return list
  }

  // Rebuilt on every open: the poller may have written a new state file, and a
  // summon always starts with the first row selected.
  onOpenedChanged: {
    if (!root.opened) return
    root.notice = ""
    root.busyLabel = ""
    root.selectedIndex = 0
    stateFile.reload()
  }

  function panelWidget() {
    var bar = root.shell ? root.shell.bar : null
    if (!bar || typeof bar.findPanelWidget !== "function") return null
    return bar.findPanelWidget(root.pluginId)
  }

  function dashboardUrl() {
    return Links.dashboardUrl(root.baseUrl)
  }

  function move(delta) {
    if (!root.rows.length) return
    var next = root.selectedIndex + delta
    root.selectedIndex = next < 0
      ? root.rows.length - 1
      : (next >= root.rows.length ? 0 : next)
  }

  function activate(row) {
    if (!row || root.busyLabel !== "") return
    root.notice = ""
    if (row.kind === "view") {
      if (root.openPanelView(row.args[0])) root.close()
      else root.notice = "there is no TrueNAS item on the bar to open the panel from"
      return
    }
    if (row.kind === "poll") {
      root.pollNow()
      return
    }
    if (row.kind === "help") {
      var widget = root.panelWidget()
      if (widget && typeof widget.openHelp === "function") {
        widget.openHelp()
        root.close()
        return
      }
      if (root.openPanelView("health")) root.close()
      else root.notice = "there is no TrueNAS item on the bar to open the panel from"
      return
    }
    root.openDashboard()
  }

  // The panel belongs to the bar widget, which exists once per monitor, and the
  // bar picks the copy on the focused screen. summon() cannot reach it: declaring
  // the `menu` kind is what moved summon() onto this file, so summon() would
  // reopen this menu rather than the panel.
  function openPanelView(name) {
    var widget = root.panelWidget()
    if (!widget || typeof widget.openView !== "function") return false
    widget.openView(String(name))
    return true
  }

  function openDashboard() {
    var widget = root.panelWidget()
    if (!widget || typeof widget.openDashboard !== "function") {
      root.notice = "there is no TrueNAS item on the bar to open the NAS UI from"
      return
    }
    widget.openDashboard()
    root.close()
  }

  // The poller writes state.json, which the FileView below watches, so the menu
  // closes on the run's end and the bar picks the new state up on its own.
  function pollNow() {
    if (pollProc.running) return
    root.busyLabel = "Polling"
    pollProc.running = true
  }

  // Read rather than polled: the service writes this file and the menu only ever
  // shows what the last poll found. Loading blocks so that a summon paints the
  // real status instead of one frame of an empty list.
  FileView {
    id: stateFile
    path: root.statePath
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.rawSnapshot = JSON.parse(text())
      } catch (e) {
        root.rawSnapshot = null
      }
    }
    onFileChanged: reload()
    onLoadFailed: root.rawSnapshot = null
  }

  Process {
    id: pollProc
    command: [root.pollPath, "--quiet"]
    onExited: {
      root.busyLabel = ""
      stateFile.reload()
      root.close()
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-truenas-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(360), window.width - Style.gapsOut * 2)
      height: Math.min(content.implicitHeight + padding * 2, window.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: card.padding
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.rows[root.selectedIndex])
            event.accepted = true
          }
        }

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.xs

          Row {
            width: content.width
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: Model.glyphFor(root.mode, root.counts)
              color: root.statusColor
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            Text {
              textFormat: Text.PlainText
              text: "TrueNAS"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.manifest && root.manifest.version
                ? String(root.manifest.version) : ""
              visible: text !== ""
              color: Qt.darker(Color.menu.text, 1.5)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          Text {
            textFormat: Text.PlainText
            width: content.width
            text: root.statusText
            wrapMode: Text.WordWrap
            color: root.statusColor
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }

          Repeater {
            model: root.rows

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool selected: row.index === root.selectedIndex

              width: content.width
              height: rowText.implicitHeight + Style.spacing.rowPaddingX
              radius: Style.cornerRadius
              color: row.selected ? Color.menu.selectedBackground : "transparent"

              Column {
                id: rowText
                anchors.verticalCenter: row.verticalCenter
                anchors.left: row.left
                anchors.right: row.right
                anchors.leftMargin: Style.spacing.xs
                anchors.rightMargin: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  width: rowText.width
                  text: row.modelData.label
                  elide: Text.ElideRight
                  color: row.selected ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                  renderType: Text.NativeRendering
                }

                Text {
                  textFormat: Text.PlainText
                  width: rowText.width
                  text: row.modelData.detail
                  visible: row.modelData.detail !== ""
                  elide: Text.ElideRight
                  color: Qt.darker(Color.menu.text, 1.5)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }

              MouseArea {
                anchors.fill: row
                hoverEnabled: true
                onEntered: root.selectedIndex = row.index
                onClicked: root.activate(row.modelData)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            id: footer
            width: content.width
            text: root.busyLabel !== "" ? root.busyLabel + "..." : root.notice
            visible: footer.text !== ""
            wrapMode: Text.WordWrap
            color: root.notice !== "" ? Color.urgent : Qt.darker(Color.menu.text, 1.5)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }
}
