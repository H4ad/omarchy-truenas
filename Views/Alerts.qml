import QtQuick
import qs.Commons
import "../Model.js" as Model

// Placeholder Alerts view. Task 16 replaces this with a row per alert and the
// dismiss / restore writes. Until then it renders one line of counts, so the
// panel loads and the tab is not blank.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var counts: (view.nasState && view.nasState.counts) || null

  readonly property string statusLine: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!(view.nasState.connection && view.nasState.connection.ok))
      return "No answer from the NAS: " + (Model.errorSentence(view.nasState.connection) || "the poll failed")
    var phrase = Model.countPhrase(view.counts)
    if (phrase !== "") return phrase
    if (view.counts && (view.counts.dismissed || 0) > 0)
      return "nothing firing; " + view.counts.dismissed + " dismissed"
    return "nothing firing"
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.statusLine
    color: view.nasState && view.nasState.connection && view.nasState.connection.ok
      ? view.panel.contentForeground : view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }
}
