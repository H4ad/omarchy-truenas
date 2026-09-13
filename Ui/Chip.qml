import QtQuick
import qs.Commons

// One label chip: a dimmed key, its value, and a tint of the panel's own
// foreground behind both. Never clickable, so it carries no MouseArea and
// cannot take a click away from the row it sits on.
//
//   Chip {
//     key: "pool"
//     value: "storage"
//     foreground: panel.contentForeground
//     fontFamily: panel.contentFontFamily
//     maximumWidth: 140
//   }
//
// The panel is 460 units wide and configurable down to 360, so a chip row gets
// one line and never a second one. Both texts elide and neither wraps.
Item {
  id: root

  property string key: ""
  property string value: ""

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property real radius: Style.cornerRadius

  // 0 means "as wide as the text needs". Anything else is a hard cap the caller
  // computed from the line it has to share, and the text elides inside it.
  property real maximumWidth: 0

  readonly property real paddingX: Style.space(5)
  readonly property real paddingY: Style.space(1)
  readonly property real gap: (root.key !== "" && root.value !== "") ? Style.space(4) : 0
  readonly property real innerWidth: Math.max(0, root.width - root.paddingX * 2)

  // The natural width, never the capped one, so a caller may read it back
  // without the cap it set feeding into the number it is deciding from.
  implicitWidth: root.paddingX * 2 + keyText.implicitWidth + root.gap + valueText.implicitWidth
  implicitHeight: Math.max(keyText.implicitHeight, valueText.implicitHeight) + root.paddingY * 2

  width: root.maximumWidth > 0 ? Math.min(root.implicitWidth, root.maximumWidth) : root.implicitWidth

  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
  }

  // The key keeps its width and the value gives ground, because a truncated
  // value is still recognizable from its prefix while a truncated key stops
  // saying which label this is.
  Text {
    id: keyText
    anchors.left: parent.left
    anchors.leftMargin: root.paddingX
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.innerWidth)
    elide: Text.ElideRight
    text: root.key
    color: Qt.darker(root.foreground, 1.8)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  Text {
    id: valueText
    anchors.left: keyText.right
    anchors.leftMargin: root.gap
    anchors.right: parent.right
    anchors.rightMargin: root.paddingX
    anchors.verticalCenter: parent.verticalCenter
    elide: Text.ElideRight
    text: root.value
    color: Qt.darker(root.foreground, 1.25)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }
}
