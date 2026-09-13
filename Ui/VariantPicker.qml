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
// The preview is drawn against sample numbers when the caller passes none, so
// five rows never read the same glyph. `view` is the same object BarVariants
// documents, so the preview goes through the exact code the bar does and cannot
// disagree with it.
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

  readonly property var sampleView: ({
    mode: "firing", alertCount: 3, capacityText: "71%",
    worstPool: "DEGRADED", worstLevel: "warning"
  })
  readonly property var sampleGlyphs: ({
    main: Model.glyphFor("firing", ({ warning: 1 })),
    offline: Model.GLYPH.offline,
    unconfigured: Model.GLYPH.unconfigured
  })
  readonly property var previewView: root.view ? root.view : root.sampleView
  readonly property var previewGlyphs: root.glyphs ? root.glyphs : root.sampleGlyphs

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
      case "Icon":     return "glyph only"
      case "Alerts":   return "alert count"
      case "Capacity": return "fullest pool"
      case "Pool":     return "worst pool status"
      case "Full":     return "alerts + capacity"
      default:         return "alerts, else capacity"
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
        anchors.right: parent.right
        anchors.rightMargin: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spaceReal(3)

        Repeater {
          model: row.segments

          Text {
            required property var modelData
            text: modelData.text
            color: root.colorForSeverity(modelData.severity)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
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
