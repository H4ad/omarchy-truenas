import QtQuick
import qs.Commons
import "../Model.js" as Model

// Placeholder Health view. Tasks 14 replaces this with the full status line,
// system facts, capacity bars and counts. Until then it renders one line that
// says what the plugin knows, so the panel loads and the tab is not blank.
//
// The rule the real view will keep, and this one already keeps: an unknown
// number is a sentence, never a zero and never a loading dash.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)

  readonly property string statusLine: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    var system = view.nasState.system || {}
    var counts = view.nasState.counts || null
    var pools = Model.arrayLike(view.nasState.pools) ? view.nasState.pools : []
    var host = String(system.hostname || "")
    var alerts = (counts && typeof counts.total === "number")
      ? counts.total + " active alerts"
      : "alert count unknown"
    return "Connected" + (host !== "" ? " to " + host : "")
      + " · " + alerts
      + " · " + pools.length + " pools"
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.statusLine
    color: view.connected || !view.nasState
      ? view.panel.contentForeground : view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.panel.state
      && Model.arrayLike(view.panel.state.warnings)
      && view.panel.state.warnings.length > 0
    text: "some sections did not answer; the full health view arrives in a later task"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }
}
