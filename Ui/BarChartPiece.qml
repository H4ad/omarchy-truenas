import QtQuick
import qs.Commons
import qs.Ui

// One chart, drawn from a BarVariants chart spec. Shared by the single-chart
// variants and by the Custom composer, so a capacity bar, a row of pool squares,
// a disk heat row or a sparkline looks the same wherever it appears.
//
//   BarChartPiece {
//     spec: BarVariants.chartFor("CapacityBar", view)
//     foreground: bar.foreground
//     urgent: bar.urgent
//   }
//
// The spec is the whole contract: { kind, ... } as BarVariants.chartFor builds
// it. A null spec draws nothing, which is how a chart with nothing to show stays
// empty instead of becoming a zero-length shape.
Item {
  id: root

  property var spec: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption

  readonly property string kind: root.spec ? String(root.spec.kind || "") : ""
  readonly property bool drawable: root.kind !== ""

  // The design's sizes: 4x8 cells with a 2px gap, 5px squares, a 40x10 spark.
  readonly property real cellWidth: 4
  readonly property real cellHeight: 8
  readonly property real gap: 2
  readonly property real dotSize: 5
  readonly property real sparkWidth: 40
  readonly property real sparkHeight: 10
  readonly property real barRowHeight: Math.max(root.cellHeight, root.fontSize + 4)
  readonly property real sparkColumnWidth: {
    var columns = (root.kind === "spark" && root.spec) ? root.spec.columns.length : 0
    return columns <= 0 ? root.sparkWidth : root.sparkWidth / columns
  }
  readonly property color emptyColor: {
    var base = root.foreground
    return Qt.rgba(base.r, base.g, base.b, 0.22)
  }

  // The same severity -> colour map the widget uses for text, so a tinted
  // number and a tinted square never disagree.
  function colorForSeverity(severity) {
    switch (String(severity || "")) {
      case "critical": return root.urgent
      case "error":    return Qt.tint(root.urgent,
                                      Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35))
      case "warning":  return root.accent
      case "info":     return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
      default:         return root.foreground
    }
  }

  visible: root.drawable
  implicitWidth: root.kind === "bar" ? barRow.implicitWidth
    : root.kind === "spark" ? sparkRow.implicitWidth
    : dotsRow.implicitWidth
  implicitHeight: root.kind === "bar" ? barRow.implicitHeight
    : root.kind === "spark" ? root.sparkHeight
    : dotsRow.implicitHeight

  // CapacityBar: `total` cells, the first `filled` tinted, then the percent.
  // Each cell is an Item of the row's height so the cells and the label sit on
  // one centred line rather than top-aligning.
  Row {
    id: barRow
    // Centred, not top-left: the host loads this into a square optical canvas,
    // so a child at y 0 would sit above the bar.
    anchors.centerIn: parent
    visible: root.kind === "bar"
    spacing: root.gap

    Repeater {
      model: root.kind === "bar" ? root.spec.total : 0

      Item {
        required property int index
        width: root.cellWidth
        height: root.barRowHeight

        Rectangle {
          anchors.centerIn: parent
          width: root.cellWidth
          height: root.cellHeight
          color: index < (root.spec ? root.spec.filled : 0)
            ? root.colorForSeverity(root.spec ? root.spec.severity : "")
            : root.emptyColor
        }
      }
    }

    Item {
      width: barLabel.implicitWidth
      height: root.barRowHeight

      Text {
        textFormat: Text.PlainText
        id: barLabel
        anchors.centerIn: parent
        text: root.kind === "bar" ? String(root.spec.label || "") : ""
        color: root.colorForSeverity(root.spec ? root.spec.severity : "")
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        renderType: Text.NativeRendering
      }
    }
  }

  // Pools and DiskHeat: one small square per row, coloured by its severity.
  Row {
    id: dotsRow
    anchors.centerIn: parent
    visible: root.kind === "dots" || root.kind === "heat"
    spacing: root.gap

    Repeater {
      model: (root.kind === "dots" || root.kind === "heat") ? root.spec.items : []

      Item {
        required property var modelData
        width: root.dotSize
        height: root.dotSize

        Rectangle {
          anchors.fill: parent
          color: root.colorForSeverity(modelData ? modelData.severity : "")
        }
      }
    }
  }

  // Sparkline: one thin column per sample, oldest first, bottom-aligned in a
  // 10px band. A null sample draws nothing, so a gap stays a gap; a real 0 keeps
  // a 1px stub so it is not mistaken for the gap.
  Row {
    id: sparkRow
    anchors.centerIn: parent
    visible: root.kind === "spark"
    spacing: 0

    Repeater {
      model: root.kind === "spark" ? root.spec.columns : []

      Item {
        required property var modelData
        width: root.sparkColumnWidth
        height: root.sparkHeight

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: (modelData === null || modelData === undefined)
            ? 0 : Math.max(1, Number(modelData) * root.sparkHeight)
          color: root.colorForSeverity(root.spec ? root.spec.severity : "")
        }
      }
    }
  }
}
