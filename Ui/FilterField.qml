import QtQuick
import qs.Commons
import qs.Ui

// The filter box above a panel list: text in, `filterChanged` out, and a clear
// button once there is something to clear. It knows nothing about what it
// filters and reads nothing off a panel root, so the alerts and pools lists can
// both point at the same component.
//
//   FilterField {
//     width: parent.width
//     placeholder: "filter alerts"
//     foreground: panel.contentForeground
//     fontFamily: panel.contentFontFamily
//     autoFocus: true
//     onFilterChanged: function(value) { panel.alertFilter = value }
//   }
//
// Escape is consumed only while there is text to clear, so an empty field lets
// the key through to the panel's key catcher and still closes the panel.
Item {
  id: root

  property string placeholder: "filter"
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body

  // Focus on creation, for a view that opens with the filter as the obvious
  // first thing to do. A view reached by clicking a tab wants it off, or the
  // caret steals the keyboard from the list.
  property bool autoFocus: false

  property alias text: field.text

  // For a panel whose key catcher needs to stand down while someone is typing.
  readonly property alias activeFocusInField: field.activeFocus

  signal filterChanged(string text)

  function clear() {
    field.text = ""
    field.forceActiveFocus()
  }

  function focusField() {
    field.forceActiveFocus()
  }

  implicitWidth: field.implicitWidth
  implicitHeight: field.implicitHeight

  Component.onCompleted: if (root.autoFocus) field.forceActiveFocus()
  onVisibleChanged: if (visible && root.autoFocus) field.forceActiveFocus()

  TextField {
    id: field
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    placeholderText: root.placeholder
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: root.fontSize

    // The panel binds Tab to switching panels, and there is nothing else in a
    // list view worth tabbing to. Off, the key is ignored here and reaches the
    // panel's key catcher, which is where it means something.
    activeFocusOnTab: false

    // Reserved whether or not the button is showing, so the caret does not jump
    // sideways on the keystroke that makes the button appear.
    rightPadding: clearButton.width + Style.space(4)

    onTextChanged: root.filterChanged(field.text)

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape && field.text !== "") {
        root.clear()
        event.accepted = true
      }
    }
  }

  PanelActionButton {
    id: clearButton
    anchors.right: field.right
    anchors.rightMargin: Style.space(2)
    anchors.verticalCenter: field.verticalCenter
    visible: field.text !== ""
    iconText: "󰅙"
    tooltipText: "Clear the filter"
    fontSize: Style.font.caption
    fontFamily: root.fontFamily
    foreground: Qt.darker(root.foreground, 1.4)
    hoverColor: root.foreground
    onClicked: root.clear()
  }
}
