import QtQuick
import qs.Commons
import "../Model.js" as Model
import "../BarVariants.js" as BarVariants

// One row per bar variant: its name, what it prints, and a preview of that on
// the live numbers. Self-contained on purpose: it reads no panel root and no
// config file, it takes the current value and the values to preview, and it
// emits the choice for whoever owns the setting to write.
//
//   VariantPicker {
//     value: panel.setting("variant", "Default")
//     view: ({ mode: "quiet", alertCount: 0, capacityText: "71%", ... })
//     onPicked: function(variant) { panel.setWidgetSetting("variant", variant) }
//   }
//
// The preview is drawn against one sample view when the caller passes none, so
// every row has something to read and the caller does not repeat the sample.
// `view` is the same object BarVariants documents, so the preview goes through
// the exact code the bar does and cannot disagree with it.
Column {
  id: root

  property string value: BarVariants.DEFAULT_VARIANT
  property var view: null
  property var glyphs: null

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(Color.foreground, 1.5)
  property color urgentColor: Color.urgent
  property color accentColor: Color.accent
  property string fontFamily: Style.font.family
  property real labelWidth: Style.space(58)

  signal picked(string variant)

  // The sample lives in BarVariants.js, next to the code that consumes it, so
  // the preview here and the node test that proves every row renders non-empty
  // cannot drift apart.
  readonly property var sampleView: BarVariants.sampleView()
  readonly property var sampleGlyphs: ({
    main: Model.glyphFor("firing", ({ warning: 1 })),
    offline: Model.GLYPH.offline,
    unconfigured: Model.GLYPH.unconfigured
  })
  readonly property var previewView: root.view ? root.view : root.sampleView
  readonly property var previewGlyphs: root.glyphs ? root.glyphs : root.sampleGlyphs
  // A representative Custom composition for the preview row: the glyph, the alert
  // count, the capacity, the pool status, the temp and a capacity bar, so the row
  // shows what mixing text and a chart looks like.
  readonly property var customSampleOptions: BarVariants.customOptions({
    showGlyph: true, showAlerts: true, showCapacity: true, showPool: true,
    showTemp: true, showCapacityBar: true
  }, root.previewGlyphs)

  function colorForSeverity(severity) {
    switch (String(severity || "")) {
      case "critical": return root.urgentColor
      // The same hue as critical, a third of the way toward the text colour: one
      // step quieter, which is the order the two severities are in.
      case "error":    return Qt.tint(root.urgentColor,
                                      Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35))
      case "warning":  return root.accentColor
      case "info":     return root.dimForeground
      default:         return root.foreground
    }
  }

  function titleFor(variant) {
    var name = String(variant || "")
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  function blurbFor(variant) {
    switch (BarVariants.resolveVariant(variant)) {
      case "Icon":         return "glyph only"
      case "Alerts":       return "alert count"
      case "Capacity":     return "fullest pool"
      case "Pool":         return "worst pool status"
      case "Temp":         return "hottest disk"
      case "Full":         return "alerts + capacity"
      case "Severity":     return "worst two alert buckets"
      case "Down":         return "down services + apps"
      case "Protection":   return "failed protection jobs"
      case "Uptime":       return "time since boot"
      case "CapacityBar":  return "capacity cells + percent"
      case "Pools":        return "one square per pool"
      case "DiskHeat":     return "one square per disk"
      case "Sparkline":    return "capacity trend"
      case "Custom":       return "the pieces you switch on"
      default:             return "alerts, else capacity"
    }
  }

  spacing: Style.space(1)

  Repeater {
    model: BarVariants.VARIANTS

    Item {
      id: row
      required property var modelData
      readonly property bool selected: root.value === modelData
      readonly property var segments: BarVariants.segmentsFor(
        modelData, root.previewView, root.previewGlyphs)
      // A chart variant prints no text body, so the preview draws the same shape
      // the bar draws (cells, squares, columns) through the same chart spec.
      readonly property string chartKind: BarVariants.chartKind(modelData)
      readonly property var chart: BarVariants.chartFor(modelData, root.previewView)
      readonly property bool composed: BarVariants.isComposed(modelData)
      readonly property string composedPreviewText: row.composed
        ? BarVariants.customText(
            BarVariants.customItems(root.previewView, root.customSampleOptions))
        : ""

      width: parent.width
      implicitHeight: Math.max(name.implicitHeight, blurb.implicitHeight, preview.implicitHeight)
        + Style.space(5)

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.selected
          ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.16)
          : (rowMouse.containsMouse
             ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
             : "transparent")
      }

      Text {
        textFormat: Text.PlainText
        id: name
        anchors.left: parent.left
        anchors.leftMargin: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        width: root.labelWidth
        text: root.titleFor(row.modelData)
        color: row.selected ? root.accentColor : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        id: blurb
        anchors.left: name.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.blurbFor(row.modelData)
        color: root.dimForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        id: preview
        visible: row.chartKind === ""
        anchors.right: parent.right
        anchors.rightMargin: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spaceReal(3)

        Repeater {
          model: row.segments

          Text {
            textFormat: Text.PlainText
            required property var modelData
            text: modelData.text
            color: root.colorForSeverity(modelData.severity)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }
      }

      // The Custom preview: its text pieces as one string. A chart piece is not
      // type, so it is left out here rather than faked; the row is about what the
      // composer reads, not the exact pixels.
      Text {
        textFormat: Text.PlainText
        visible: row.composed
        anchors.right: parent.right
        anchors.rightMargin: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        text: row.composedPreviewText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // The chart preview: cells for CapacityBar, one square per dot for Pools and
      // DiskHeat, one column per sample for Sparkline. Drawn the same way the bar
      // draws them so the preview and the bar cannot disagree.
      Row {
        id: chartPreview
        visible: row.chartKind !== "" && row.chart !== null
        anchors.right: parent.right
        anchors.rightMargin: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spaceReal(2)

        Repeater {
          model: row.chartKind === "bar" && row.chart ? row.chart.total : 0

          Rectangle {
            required property int index
            width: Style.spaceReal(4)
            height: Style.spaceReal(8)
            radius: 1
            color: index < row.chart.filled
              ? root.colorForSeverity(row.chart.severity)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: row.chartKind === "bar" && row.chart !== null
          text: row.chart ? row.chart.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: (row.chartKind === "dots" || row.chartKind === "heat") && row.chart
            ? row.chart.items.length : 0

          Rectangle {
            required property int index
            width: Style.spaceReal(5)
            height: Style.spaceReal(5)
            radius: 1
            color: root.colorForSeverity(row.chart.items[index].severity)
          }
        }

        Repeater {
          model: row.chartKind === "spark" && row.chart ? row.chart.columns.length : 0

          Item {
            required property int index
            width: Style.spaceReal(2)
            height: Style.spaceReal(10)

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: Style.spaceReal(2)
                + (row.chart.columns[index] === null || row.chart.columns[index] === undefined
                   ? 0 : Number(row.chart.columns[index]) * Style.spaceReal(8))
              radius: 1
              color: root.colorForSeverity(row.chart.severity)
            }
          }
        }
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.picked(String(row.modelData))
      }
    }
  }
}
