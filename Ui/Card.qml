import QtQuick
import qs.Commons

// A titled container for one group of rows inside a view.
//
// The reference plugin's Card drew a fetched query result; this plugin has no
// card queries, so the surface is reduced to what every view in this milestone
// needs: a dimmed heading over caller-supplied content.
//
//   Card {
//     title: "POOLS"
//     foreground: panel.contentForeground
//     fontFamily: panel.contentFontFamily
//
//     Text { ... }
//   }
//
// The default property is aliased to the inner Column, so children declared on
// the Card land in the body whether or not it has a title.
Item {
  id: root

  property string title: ""
  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(root.foreground, 1.4)
  property string fontFamily: Style.font.family
  property real padding: Style.space(8)
  property real radius: Style.cornerRadius

  default property alias content: body.data

  implicitWidth: head.implicitWidth + root.padding * 2
  implicitHeight: head.implicitHeight + root.padding * 2

  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
  }

  Column {
    id: head
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: root.padding
    spacing: Style.space(4)

    Text {
      width: parent.width
      visible: root.title !== ""
      text: root.title
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.space(4)
    }
  }
}
