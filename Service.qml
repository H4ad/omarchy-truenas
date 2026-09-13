import QtQuick

// Headless half of the plugin. The host injects shell and manifest; the real
// poll, IPC and notifications land in later tasks.
Item {
  property var shell: null
  property var manifest: null
}
