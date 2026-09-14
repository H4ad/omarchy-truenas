import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Views" as Views
import "Ui" as Local
import "Model.js" as Model
import "Links.js" as Links

// The popout. A shell and a write queue, plus the four views.
//
// The panel owns every write: views ask it to run a verb, it serialises the
// argv through one Process (apiQueue/pumpApi), then refreshes the state with a
// forced re-poll before believing anything. It never trusts a verb's stdout as
// the new state.
//
// The bar widget injects bar, settings, anchorItem, hostWidget and state. The
// panel adds nothing else to that contract on purpose: everything else it needs
// it reads from its own files.
Panel {
  id: root
  moduleName: "io.github.h4ad.truenas"
  ipcTarget: "io.github.h4ad.truenas"
  // The bar widget owns the single IpcHandler this target permits, so the
  // panel does not register a second one.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var state: null
  property int nowTick: 0

  property string view: "health"
  property string actionError: ""
  property string actionNotice: ""
  property string busyVerb: ""
  property var apiQueue: []
  property var configData: null
  property var configDoc: null
  property var pendingConfirm: null

  readonly property var barIdentity: hostWidget || root

  readonly property var counts: (state && state.counts) || ({})
  readonly property var pools: (state && Model.arrayLike(state.pools)) ? state.pools : []
  readonly property string mode: Model.mode(state)
  readonly property bool connected: !!(state && state.connection && state.connection.ok)

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.darker(root.contentForeground, 1.5)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int panelWidth: Style.space(Number(root.setting("panelWidth", 460)) || 460)

  readonly property bool identityKnown: {
    var connection = (root.state && root.state.connection) || {}
    var system = (root.state && root.state.system) || {}
    return String(system.hostname || "") !== ""
      || String(connection.version || system.version || "") !== ""
  }

  readonly property string identityText: {
    var connection = (root.state && root.state.connection) || {}
    var system = (root.state && root.state.system) || {}
    var host = String(system.hostname || "")
    var version = String(connection.version || system.version || "")
    if (host === "" && version === "") return "unknown host"
    if (host === "") return version
    if (version === "") return host
    return host + " · " + version
  }

  readonly property var tabs: [
    { key: "health", label: "Health" },
    { key: "pools", label: "Pools" },
    { key: "disks", label: "Disks" },
    { key: "alerts", label: "Alerts" },
    { key: "config", label: "Config" }
  ]

  readonly property var viewComponents: ({
    "health": healthView,
    "pools": poolsView,
    "disks": disksView,
    "alerts": alertsView,
    "config": configView
  })

  readonly property string ctlPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/truenasctl")).replace(/^file:\/\//, ""))
  readonly property string apiPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/truenas-api")).replace(/^file:\/\//, ""))
  readonly property string pollPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/truenas-poll")).replace(/^file:\/\//, ""))

  // The config file this plugin reads and writes. `configPath` is the widget's
  // own setting; empty means the default location.
  readonly property string configPath: {
    var override = String(root.setting("configPath", ""))
    if (override !== "") return override.replace(/^~/, Quickshell.env("HOME") || "")
    return (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") || "") + "/.config")
      + "/omarchy/truenas/config.json"
  }

  // The configured NAS, read off the config file rather than off a write's
  // answer, so it is available to every view whether or not Config was opened.
  readonly property string baseUrl: {
    var doc = root.configDoc
    if (!doc) return ""
    var list = doc.instances
    if (!list || typeof list.length !== "number" || list.length === 0) return ""
    return String(list[0].baseUrl || "")
  }

  // ------------------------------------------------------------- lifecycle

  function open() {
    root.refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function showView(name) {
    var next = String(name || "health")
    root.actionError = ""
    root.actionNotice = ""
    root.pendingConfirm = null
    root.view = next
    if (next === "config") root.loadConfig()
  }

  // ------------------------------------------------------------------ reads

  function refresh() {
    if (pollProc.running) return
    pollProc.command = [root.pollPath, "--quiet"]
    pollProc.running = true
  }

  // A write changes something the poller only refetches on its slow cadence, so
  // without the flag the panel keeps showing the state from before the write.
  function refreshAfterWrite() {
    if (pollProc.running) return
    pollProc.command = [root.pollPath, "--quiet", "--force-meta"]
    pollProc.running = true
  }

  function loadConfig() {
    root.busyVerb = "config"
    root.runCtl(["config", "list"], function(result) {
      if (!root) return
      root.configData = result
      root.busyVerb = ""
    })
  }

  // ----------------------------------------------------------- widget setting
  // The variant is this bar item's own shell.json setting, not plugin config, so
  // it is written the way the first-party widgets write theirs: patch the live
  // entry and ask the shell to persist it. `settings` is the object the widget
  // injected, so the change is visible on the bar before the write lands.
  function setWidgetSetting(name, value) {
    var entry = { id: root.moduleName }
    var current = root.settings || {}
    for (var key in current) entry[key] = current[key]
    entry[String(name)] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ------------------------------------------------------------------ writes
  // One queue, one process. truenas-api answers with a single JSON object;
  // truenasctl answers with JSON for its read verbs and a sentence for its
  // writes, because it is also a command somebody types. So success is the exit
  // status, not the parseability of the output.
  function runCtl(args, callback, onError) {
    root.enqueue([root.ctlPath].concat(args), callback, onError)
  }

  function runApi(args, callback, onError) {
    root.enqueue([root.apiPath].concat(args), callback, onError)
  }

  function enqueue(command, callback, onError) {
    root.apiQueue = root.apiQueue.concat([
      { command: command, callback: callback, onError: onError }])
    root.pumpApi()
  }

  function pumpApi() {
    if (apiProc.running || !root.apiQueue.length) return
    apiProc.command = root.apiQueue[0].command
    apiProc.running = true
  }

  function finishApi(text, errorText, exitCode) {
    var job = root.apiQueue.length ? root.apiQueue[0] : null
    root.apiQueue = root.apiQueue.slice(1)
    root.busyVerb = ""
    var parsed = null
    try {
      parsed = JSON.parse(String(text || "null"))
    } catch (e) {
      parsed = null
    }
    if (parsed && parsed.error) {
      root.actionError = Model.errorSentence({
        connection: { error: parsed.error, message: parsed.message } })
      if (job && job.onError) job.onError(parsed)
    } else if (exitCode !== 0) {
      root.actionError = root.helperComplaint(errorText, exitCode)
      if (job && job.onError)
        job.onError({ ok: false, error: "helper_failed", message: root.actionError })
    } else if (job && job.callback) {
      root.actionError = ""
      // A write verb answers with a sentence, and its callback wants an object.
      job.callback(parsed || { ok: true, output: String(text || "") })
    }
    Qt.callLater(root.pumpApi)
  }

  // The helper prefixes its own warnings with "truenas: ". The last line is the
  // one that says what went wrong; the earlier ones are usually context.
  function helperComplaint(errorText, exitCode) {
    var lines = String(errorText || "").split("\n").filter(function(line) {
      return line.trim() !== ""
    })
    if (!lines.length) return "the helper failed with status " + exitCode
    return lines[lines.length - 1].replace(/^truenas:\s*/, "")
  }

  // ------------------------------------------------------------------ confirm
  // Destructive writes are queued here and armed through the one ConfirmAction,
  // which lives inside the key catcher where a dialog can actually be seen.
  function requestConfirm(message, action, label) {
    root.pendingConfirm = action
    confirmAction.arm(message, label)
  }

  // ------------------------------------------------------------------- links
  // execDetached, not a Process: xdg-open blocks for as long as the browser it
  // launched lives, and a held Process would refuse the next open.
  function openUrl(url) {
    var safe = Links.safeUrl(url, root.baseUrl)
    if (safe === "") return
    Quickshell.execDetached(["xdg-open", safe])
    root.close()
  }

  // ------------------------------------------------------------------ files

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.configDoc = JSON.parse(String(text() || "null"))
      } catch (e) {
        root.configDoc = null
      }
    }
    onFileChanged: reload()
    onLoadFailed: root.configDoc = null
  }

  Process {
    id: pollProc
    command: [root.pollPath, "--quiet"]
    onExited: pollProc.command = [root.pollPath, "--quiet"]
  }

  Process {
    id: apiProc
    property string outText: ""
    property string errText: ""
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: apiProc.outText = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: apiProc.errText = text
    }
    onExited: function(exitCode) {
      var out = apiProc.outText
      var err = apiProc.errText
      apiProc.outText = ""
      apiProc.errText = ""
      root.finishApi(out, err, exitCode)
    }
  }

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowTick++
  }

  // ------------------------------------------------------------------ surface

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: keyboardPanel.fittedContentWidth(root.panelWidth)
    contentHeight: keyboardPanel.fittedContentHeight(
      header.implicitHeight + Style.space(10) + bodyScroll.height
      + Style.space(8) + footer.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (confirmAction.opened) confirmAction.canceled()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (confirmAction.opened) return
        root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (confirmAction.opened && dx !== 0)
          confirmAction.selectedIndex = confirmAction.selectedIndex === 0 ? 1 : 0
      }
      onReturnRequested: {
        if (!confirmAction.opened) return
        if (confirmAction.selectedIndex === 0) confirmAction.canceled()
        else confirmAction.confirmed()
      }

      // ------------------------------------------------------------- header
      Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(6)

        Item {
          width: parent.width
          implicitHeight: Math.max(title.implicitHeight, closeButton.height)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "TrueNAS"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.left: title.right
            anchors.leftMargin: Style.space(10)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            // Dimmed when the identity is unknown, so "I cannot tell" never
            // looks like a hostname.
            color: root.identityKnown ? root.contentForeground : root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            text: root.identityText
          }

          PanelActionButton {
            id: closeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "✕"
            tooltipText: "Close"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.close()
          }

          PanelActionButton {
            id: gearButton
            anchors.right: closeButton.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "⚙"
            tooltipText: "Configure TrueNAS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.showView("config")
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: gearButton.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.GLYPH.refresh
            tooltipText: "Poll now"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: {
              root.refresh()
              if (root.view === "config") root.loadConfig()
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            model: root.tabs

            Text {
              required property var modelData
              readonly property bool active: root.view === modelData.key
              text: modelData.label
              color: active
                ? Color.accent
                : (tabMouse.containsMouse ? root.contentForeground : root.dimForeground)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: active

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showView(modelData.key)
              }
            }
          }
        }

        PanelSeparator { width: parent.width }
      }

      // --------------------------------------------------------------- body
      Flickable {
        id: bodyScroll
        anchors.left: parent.left
        anchors.right: parent.right
        // The scrollbar's lane, reserved whether or not the bar is showing.
        anchors.rightMargin: bodyBar.width + Style.space(2)
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        readonly property real maxHeight: Math.max(Style.space(120),
          Math.round((keyboardPanel.screenH > 0 ? keyboardPanel.screenH : 1080) * 0.55))
        height: Math.min(bodyLoader.implicitHeight, maxHeight)
        contentWidth: width
        contentHeight: bodyLoader.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        flickDeceleration: 6000

        Loader {
          id: bodyLoader
          width: bodyScroll.width
          sourceComponent: root.viewComponents[root.view] || healthView
        }
      }

      Local.ScrollIndicator {
        id: bodyBar
        flickable: bodyScroll
        anchors.right: parent.right
        anchors.top: bodyScroll.top
        anchors.bottom: bodyScroll.bottom
        foreground: root.contentForeground
      }

      // ------------------------------------------------------------- footer
      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(6)

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: root.actionError !== "" || root.actionNotice !== ""
          text: root.actionError !== "" ? root.actionError : root.actionNotice
          color: root.actionError !== "" ? root.urgentColor : root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width }

        Row {
          width: parent.width
          spacing: Style.space(12)
          visible: root.baseUrl !== ""

          Repeater {
            model: [
              { label: "Dashboard", path: "/ui/dashboard" },
              { label: "Pools", path: "/ui/storage" },
              { label: "Alerts", path: "/ui/alerts" }
            ]

            Text {
              required property var modelData
              text: Model.GLYPH.link + " " + modelData.label
              color: linkMouse.containsMouse
                ? Color.accent : Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: linkMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(root.baseUrl + modelData.path)
              }
            }
          }
        }
      }

      // Inside the key catcher and raised, because a dialog at Panel.qml's root
      // scope renders nowhere: BarWidget loads that root into a hidden Loader
      // and the visible panel is a separate layer-shell window.
      Local.ConfirmAction {
        id: confirmAction
        anchors.fill: parent
        z: 10
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
        onConfirmed: {
          var action = root.pendingConfirm
          root.pendingConfirm = null
          confirmAction.opened = false
          if (action) action()
        }
        onCanceled: {
          root.pendingConfirm = null
          confirmAction.opened = false
        }
      }
    }
  }

  // ------------------------------------------------------------------- views
  // A view takes the panel root as a property instead of resolving the id `root`
  // up the scope chain across the file boundary, so what a view reads is visible
  // where it is created.
  Component { id: healthView; Views.Health { panel: root } }
  Component { id: poolsView; Views.Pools { panel: root } }
  Component { id: disksView; Views.Disks { panel: root } }
  Component { id: alertsView; Views.Alerts { panel: root } }
  Component { id: configView; Views.Config { panel: root } }
}
