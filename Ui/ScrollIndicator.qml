import QtQuick
import qs.Commons

// The scrollbar a Flickable here never had.
//
//   ScrollIndicator {
//     id: bodyBar
//     flickable: bodyScroll
//     anchors.right: parent.right
//     anchors.top: bodyScroll.top
//     anchors.bottom: bodyScroll.bottom
//     foreground: panel.contentForeground
//   }
//
// Anchored by the caller and declared as a sibling of the Flickable, never as a
// child of it: a child of a Flickable is content, so it would scroll away with
// the rows it is describing. The caller also reserves its lane with
// `anchors.rightMargin: bodyBar.width + Style.space(2)` on the Flickable itself,
// held open whether or not the bar is drawn, so a view does not re-wrap every
// sentence the moment its list grows long enough to scroll.
//
// The reference plugin kept the handle arithmetic in Model.js so node could
// check it. This plugin has no such helpers and this is the only consumer, so
// the formulas live here, inlined, and the component takes nothing but the
// Flickable it describes and the colour it draws with.
Item {
  id: root

  required property var flickable

  property color foreground: Color.foreground
  property real thickness: Style.space(5)

  // A handle short enough to be a dot stops reading as a position.
  property real minimumLength: Style.space(20)

  // The lane is thinner than a comfortable target, so the grab area reaches
  // back across the gap between the bar and the Flickable. It stops there: one
  // unit further and it is over the rows.
  property real grabMargin: Style.space(3)

  property real trackAlpha: 0.09
  property real handleAlpha: 0.34
  property real movingAlpha: 0.58
  property real pressedAlpha: 0.76

  readonly property real ratio: root.flickable ? root.flickable.visibleArea.heightRatio : 1
  readonly property real position: root.flickable ? root.flickable.visibleArea.yPosition : 0
  readonly property bool scrollable:
    !!root.flickable && root.flickable.contentHeight > root.flickable.height

  readonly property real handleLength: root.scrollable
    ? Math.max(root.minimumLength, Math.min(root.height, root.height * root.ratio))
    : root.height

  // visibleArea.yPosition runs 0..(1-ratio), which is the range the pointer can
  // put the handle through. Scaling it onto the handle's own travel is what
  // keeps the handle under the pointer at both ends.
  readonly property real handleOffset: {
    if (!root.scrollable) return 0
    var travel = root.height - root.handleLength
    var span = 1 - root.ratio
    if (travel <= 0 || span <= 0) return 0
    return Math.max(0, Math.min(travel, travel * (root.position / span)))
  }

  function jumpTo(wanted) {
    if (!root.flickable) return
    if (root.flickable.flicking) root.flickable.cancelFlick()
    var minY = root.flickable.originY
    var maxY = root.flickable.originY
      + Math.max(0, root.flickable.contentHeight - root.flickable.height)
    root.flickable.contentY = Math.max(minY, Math.min(maxY, Number(wanted) || 0))
  }

  function scrollToHandleTop(top) {
    if (!root.flickable) return
    var travel = root.height - root.handleLength
    var span = Math.max(0, root.flickable.contentHeight - root.flickable.height)
    if (travel <= 0 || span <= 0) return
    root.jumpTo(root.flickable.originY + (top / travel) * span)
  }

  // A page and not a jump to where the pointer landed: a jump throws away the
  // place being read, while a page short of a full screen leaves a row of it
  // behind for the eye to land on.
  function pageBy(direction) {
    if (!root.flickable) return
    root.jumpTo(root.flickable.contentY + direction * root.flickable.height * 0.9)
  }

  width: root.thickness
  visible: root.scrollable && root.height > 0

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.trackAlpha)
  }

  Rectangle {
    id: handle
    width: parent.width
    radius: width / 2
    height: root.handleLength
    y: root.handleOffset

    readonly property real alpha: {
      if (grab.pressed) return root.pressedAlpha
      if (grab.containsMouse) return root.movingAlpha
      return root.flickable && root.flickable.moving ? root.movingAlpha : root.handleAlpha
    }

    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, handle.alpha)

    Behavior on color {
      ColorAnimation { duration: 120 }
    }
  }

  MouseArea {
    id: grab
    anchors.fill: parent
    anchors.leftMargin: -root.grabMargin
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    // Where inside the handle the press landed, so the handle stays under the
    // pointer instead of jumping its own centre there on the first pixel of
    // movement. -1 means this press was on the track and is not a drag.
    property real grabOffset: -1

    onPressed: function(event) {
      if (event.y >= handle.y && event.y <= handle.y + handle.height) {
        grab.grabOffset = event.y - handle.y
        return
      }
      grab.grabOffset = -1
      root.pageBy(event.y < handle.y ? -1 : 1)
    }

    onPositionChanged: function(event) {
      if (grab.grabOffset < 0) return
      root.scrollToHandleTop(event.y - grab.grabOffset)
    }

    onReleased: grab.grabOffset = -1
  }

  // MouseArea does not handle the wheel at all, and the bar sits beside the
  // Flickable rather than over it, so without this a wheel with the pointer on
  // the scrollbar reaches the panel behind it and scrolls nothing.
  WheelHandler {
    onWheel: function(event) {
      if (!root.flickable) return
      root.jumpTo(root.flickable.contentY - event.angleDelta.y)
      event.accepted = true
    }
  }
}
