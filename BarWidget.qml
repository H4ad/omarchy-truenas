import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "BarVariants.js" as BarVariants
import "Links.js" as Links

// The bar item. A read-only watcher of the state file the service writes: it
// never polls on a timer of its own, so there is one poll per machine rather
// than one per monitor. `refresh()` runs the poller once, on demand, for the
// middle click and for the IPC verb.
BarWidget {
  id: root
  moduleName: "io.github.h4ad.truenas"

  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath:
    (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state"))
      + "/omarchy/truenas/state.json"

  // The config file, read only for the base URL the right click opens. It is not
  // the poll path and it is never written here: `truenasctl login` owns it.
  readonly property string configPath: {
    var override = String(root.setting("configPath", ""))
    if (override !== "") return override.replace(/^~/, root.home)
    return (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config"))
      + "/omarchy/truenas/config.json"
  }

  property var state: null
  property var configDoc: null
  property int nowTick: 0

  readonly property var counts: (state && state.counts) || ({})
  readonly property var pools: (state && Model.arrayLike(state.pools)) ? state.pools : []
  readonly property var disks: (state && Model.arrayLike(state.disks)) ? state.disks : []
  readonly property string mode: Model.mode(state)
  readonly property string worstLevel: Model.worstLevel(counts)
  readonly property var worstPool: Model.worstPool(pools)
  readonly property string worstPoolStatus: worstPool ? String(worstPool.status || "") : ""

  // Unknown capacity is "", never "0%": a pool list that did not answer must not
  // read as an empty pool.
  readonly property var capacityPct: Model.capacityPct(state)
  readonly property string capacityText:
    (capacityPct === null || capacityPct === undefined)
      ? "" : (Math.round(Number(capacityPct)) + "%")

  readonly property int alertCount: Number(counts.total || 0)
  readonly property bool quiet: mode === "quiet"
  // The two modes where the plugin cannot vouch for a value. They override every
  // variant with a glyph and dim the item, so "nothing wrong" and "I cannot
  // tell" never look alike.
  readonly property bool degraded: mode === "offline" || mode === "unconfigured"

  readonly property var variantChoice: BarVariants.resolveVariant(root.setting("variant", "Default"))
  readonly property var glyphs: ({
    main: Model.glyphFor(root.mode, root.counts),
    offline: Model.GLYPH.offline,
    unconfigured: Model.GLYPH.unconfigured
  })
  readonly property var barView: ({
    mode: root.mode,
    alertCount: root.alertCount,
    capacityText: root.capacityText,
    worstPool: root.worstPoolStatus,
    worstLevel: root.worstLevel,
    tempText: Model.hotTempLabel(root.disks),
    tempLevel: Model.tempLevel(root.disks)
  })
  readonly property var segments: BarVariants.segmentsFor(root.variantChoice, root.barView, root.glyphs)

  // One glyph paints one colour, so per-severity segments go through the icon
  // slot as a Row of separately tinted Text items. A vertical bar has no
  // horizontal room for that Row, so there the segments fall back to one string.
  readonly property bool tintedSegments: !root.vertical && BarVariants.isMultiColour(root.segments)

  readonly property string segmentFontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property real segmentFontSize: Style.font.caption
  readonly property real segmentSpacing: Style.spaceReal(3)

  readonly property color severityColor: {
    if ((counts.critical || 0) > 0 || (counts.error || 0) > 0)
      return root.bar ? root.bar.urgent : Color.urgent
    if ((counts.warning || 0) > 0) return Color.accent
    return root.bar ? root.bar.foreground : Color.foreground
  }

  function colorForSeverity(severity) {
    var base = root.bar ? root.bar.foreground : Color.foreground
    var urgent = root.bar ? root.bar.urgent : Color.urgent
    switch (String(severity || "")) {
      case "critical": return urgent
      // Error shares critical's hue, pulled a third of the way toward the bar
      // foreground: the same family, one step quieter.
      case "error":    return Qt.tint(urgent, Qt.rgba(base.r, base.g, base.b, 0.35))
      case "warning":  return Color.accent
      case "info":     return Qt.rgba(base.r, base.g, base.b, 0.6)
      default:         return root.severityColor
    }
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() { refreshProc.running = true }

  // Opening straight onto a tab, so a keybinding can reach Config without a
  // click: omarchy-shell io.github.h4ad.truenas view config
  function openView(name) {
    if (!panelLoader.item) return
    panelLoader.item.showView(String(name || "health"))
    panelLoader.item.open()
  }

  function openDashboard() {
    var url = Links.dashboardUrl(root.configuredBase())
    if (url === "") return
    Quickshell.execDetached(["xdg-open", url])
  }

  function configuredBase() {
    var doc = root.configDoc
    if (!doc) return ""
    var list = doc.instances
    if (!list || typeof list.length !== "number" || list.length === 0) return ""
    return String(list[0].baseUrl || "")
  }

  function applyState(text) {
    try {
      root.state = JSON.parse(String(text || "null"))
    } catch (e) {
      root.state = null
    }
  }

  function applyConfig(text) {
    try {
      root.configDoc = JSON.parse(String(text || "null"))
    } catch (e) {
      root.configDoc = null
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.state = root.state
  }

  visible: !(root.setting("hideWhenHealthy", false) && root.quiet)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()
  onStateChanged: root.injectPanel()

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.state = null
  }

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.configDoc = null
  }

  // Only drives the "checked 12s ago" tooltip. The count itself arrives with the
  // file change, so this can be slow.
  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.nowTick++
  }

  Process {
    id: refreshProc
    command: [decodeURIComponent(String(Qt.resolvedUrl("bin/truenas-poll")).replace(/^file:\/\//, "")),
              "--quiet"]
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.h4ad.truenas"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.broadcast("refresh") }
    function view(name: string): void { root.openView(name) }
  }

  // The visible row is loaded inside BarIconButton's icon slot, where no width
  // binding can reach it, so an invisible twin sizes the bar item. Both read the
  // same segments, font and spacing, and only the colour differs.
  Row {
    id: segmentSizer
    visible: false
    spacing: root.segmentSpacing

    Repeater {
      model: root.segments

      Text {
        text: (modelData || {}).text || ""
        font.family: root.segmentFontFamily
        font.pixelSize: root.segmentFontSize
        renderType: Text.NativeRendering
      }
    }
  }

  Component {
    id: segmentRow

    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.segmentSpacing

        Repeater {
          model: root.segments

          Text {
            text: (modelData || {}).text || ""
            color: root.colorForSeverity((modelData || {}).severity)
            font.family: root.segmentFontFamily
            font.pixelSize: root.segmentFontSize
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.tintedSegments ? "" : BarVariants.textFor(root.segments)
    iconComponent: root.tintedSegments ? segmentRow : null
    foreground: root.degraded
      ? (root.bar ? root.bar.foreground : Color.foreground)
      : root.severityColor
    dimmed: root.quiet || root.degraded
    fontSize: Style.font.caption
    fixedWidth: root.tintedSegments
      ? Math.max(12, segmentSizer.implicitWidth + button.scaledHorizontalMargin * 2)
      : -1
    slotSize: Style.bar.statusSlot
    tooltipText: Model.tooltipFor(root.state, root.mode) + (root.nowTick, "")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton) root.openDashboard()
      else root.toggle()
    }
  }
}
