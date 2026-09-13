import QtQuick
import qs.Commons
import "../Model.js" as Model

// Placeholder Pools view. Task 15 replaces this with a CapacityBar per pool,
// scrub state and vdev error counts. Until then it renders one line naming the
// worst pool, so the panel loads and the tab is not blank.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var pools: (view.nasState && Model.arrayLike(view.nasState.pools)) ? view.nasState.pools : []
  readonly property var worst: Model.worstPool(view.pools)

  readonly property string statusLine: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (!(view.nasState.connection && view.nasState.connection.ok))
      return "No answer from the NAS: " + (Model.errorSentence(view.nasState.connection) || "the poll failed")
    if (view.pools.length === 0) return "The NAS answered with no pools."
    if (view.worst) return view.worst.name + " is " + view.worst.status
    return view.pools.length + " pools"
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
