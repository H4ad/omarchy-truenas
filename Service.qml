import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of the plugin. Exactly one of these exists per shell, which is
// the whole reason the poll lives here: a bar widget is instantiated once per
// monitor, so polling from the widget would notify twice on two screens.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configHome: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy/truenas"
  readonly property string configPath: configHome + "/config.json"
  readonly property string pollerPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/truenas-poll")).replace(/^file:\/\//, ""))

  // Both ends are load-bearing. The floor is the API rate limit; the ceiling
  // keeps `pollSeconds * 1000` inside a 32-bit int, because the Timer interval
  // is an int and an out-of-range product wraps to 0 or negative, which turns a
  // repeating Timer into a tight loop that hammers the NAS.
  property int pollSeconds: 30

  function applyConfig(text) {
    try {
      var config = JSON.parse(String(text || "{}"))
      var seconds = parseInt(config.pollSeconds, 10)
      // The floor is not politeness, it is a guard: the API rate-limits, and a
      // typo of 1 would hammer the instance from every session the user has open.
      root.pollSeconds = isFinite(seconds) && seconds >= 15
        ? Math.min(seconds, 86400)
        : 30
    } catch (e) {
      root.pollSeconds = 30
    }
  }

  function poll() {
    if (pollProc.running) return
    pollProc.running = true
  }

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.pollSeconds = 30
  }

  Process {
    id: pollProc
    command: [root.pollerPath, "--quiet"]
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  IpcHandler {
    target: "truenas"

    function refresh(): void { root.poll() }
    function poll(): void { root.poll() }
  }
}
