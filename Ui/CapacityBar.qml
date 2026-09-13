import QtQuick
import qs.Commons
import "../Model.js" as Model

// One pool's capacity: allocated / size with a percentage label over a track.
//
//   CapacityBar {
//     name: pool.name
//     allocated: pool.allocated
//     size: pool.size
//     usedPct: pool.usedPct
//     foreground: panel.contentForeground
//     fontFamily: panel.contentFontFamily
//   }
//
// The rule this component exists to keep is that an unknown capacity is never
// drawn as 0%. A real 0% fills nothing and says "0%"; an unknown one fills
// nothing and says "capacity unknown". The two are different facts about a
// pool, and only one of them is the pool being empty.
Item {
  id: root

  property string name: ""
  property var allocated: null
  property var size: null
  property var usedPct: null

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(root.foreground, 1.4)
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family
  property real trackHeight: Style.space(6)

  readonly property bool known: root.usedPct !== null && root.usedPct !== undefined
    && root.usedPct !== "" && isFinite(Number(root.usedPct))
  readonly property real fraction: root.known
    ? Math.max(0, Math.min(1, Number(root.usedPct) / 100)) : 0
  readonly property string pctText: root.known ? Math.round(Number(root.usedPct)) + "%" : "capacity unknown"
  readonly property color fillColor: root.fraction >= 0.9 ? root.urgentColor : root.accentColor

  // Only facts that were reported are drawn. `Model.formatBytes` returns "" for
  // anything unknown, so a missing size leaves the pair short rather than
  // printing a zero it never saw.
  readonly property string sizeText: {
    var used = Model.formatBytes(root.allocated)
    var total = Model.formatBytes(root.size)
    if (used !== "" && total !== "") return used + " / " + total
    if (used !== "") return used + " allocated"
    if (total !== "") return "size " + total
    return ""
  }

  implicitHeight: head.implicitHeight + Style.space(4) + root.trackHeight
    + (sizeLabel.visible ? Style.space(3) + sizeLabel.implicitHeight : 0)

  Item {
    id: head
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    implicitHeight: Math.max(nameLabel.implicitHeight, pctLabel.implicitHeight)

    Text {
      id: nameLabel
      anchors.left: parent.left
      anchors.right: pctLabel.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: root.name
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: pctLabel
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.pctText
      color: root.known ? root.foreground : root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: head.bottom
    anchors.topMargin: Style.space(4)
    height: root.trackHeight
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: parent.radius
      // A floor of the track height on anything measured, so a full pool of
      // 99.6% still reads as a bar rather than a rounding to nothing.
      width: root.known
        ? Math.max(root.fraction > 0 ? parent.height : 0, parent.width * root.fraction)
        : 0
      color: root.fillColor
      visible: root.known
    }
  }

  Text {
    id: sizeLabel
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: track.bottom
    anchors.topMargin: Style.space(3)
    visible: root.sizeText !== ""
    text: root.sizeText
    color: root.dimForeground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
