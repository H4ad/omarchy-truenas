import QtQuick
import qs.Commons
import qs.Ui
import "." as Local

// The panel's glossary, drawn over the panel it is explaining.
//
//   HelpModal {
//     id: helpModal
//     anchors.fill: parent
//     z: 9
//     foreground: root.contentForeground
//     fontFamily: root.contentFontFamily
//     onClosed: helpModal.opened = false
//   }
//
// It must be declared inside the PanelKeyCatcher and never at Panel.qml's root
// scope: BarWidget.qml loads that root object into a `Loader { visible: false }`
// and the panel you can see is a separate layer-shell window, so a visual child
// up there renders nowhere at all.
//
// The reference plugin read its terms out of Model.js. This plugin has no
// glossary model and no node suite to hold one against, so the words live here
// as data. Layout and content are still separate: `sections` decides what is
// said, the Repeaters below decide how it is drawn.
Item {
  id: root

  property bool opened: false

  property color background: Color.background
  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(root.foreground, 1.5)
  property color scrim: Util.alpha(Color.background, 0.72)
  property string fontFamily: Style.font.family

  signal closed()

  property var sections: [
    {
      title: "CONNECTION",
      note: "The bar answers one question: is the NAS healthy right now. These are the states it can be in.",
      terms: [
        { term: "quiet", text: "Connected, every pool ONLINE, nothing firing. A dimmed glyph, which is how the plugin proves it is alive." },
        { term: "firing", text: "Connected, with alerts below error. The bar prints the active alert count." },
        { term: "degraded", text: "A pool is not ONLINE, or an alert is at error or worse. The bar tints red." },
        { term: "offline", text: "The last poll could not reach the NAS. A plug glyph and no number: the plugin cannot vouch for a value it did not get." },
        { term: "unconfigured", text: "No API key yet. A cog glyph; run truenasctl login <url> with the key on stdin." }
      ]
    },
    {
      title: "POOLS",
      note: "Healthy is ONLINE only. A status the plugin does not recognise counts as worse than a known bad one, so it is never buried.",
      terms: [
        { term: "capacity", text: "The fullest pool's used percentage. An unknown capacity is a sentence, never 0%." },
        { term: "scrub", text: "The last scrub and its age. No scrub on record says so rather than inventing a date." },
        { term: "vdev errors", text: "Read, write or checksum errors on a vdev, shown only when non-zero." }
      ]
    },
    {
      title: "ALERTS",
      note: "Buckets worst first: critical, error, warning, notice, info. Counts are over non-dismissed alerts only.",
      terms: [
        { term: "dismiss", text: "Hides an alert on the NAS itself. It is a write, so it asks first and the panel re-polls afterwards." },
        { term: "restore", text: "Puts a dismissed alert back." }
      ]
    },
    {
      title: "SECRETS",
      note: "The key travels on stdin to truenasctl, never in argv, a shell string or shell.json.",
      terms: [
        { term: "key set", text: "A key resolves from the credentials file at mode 600. Its value is never read back into the panel." },
        { term: "credentials_permissions", text: "The credentials file is readable by others. Fix it with: chmod 600 <file>." },
        { term: "insecureTLS", text: "Off by default. A self-signed certificate is reported with the fix rather than quietly skipped." }
      ]
    }
  ]

  // Driven from PanelKeyCatcher.onMoveRequested, because that catcher owns
  // Keys.onPressed for the whole panel and nothing in here will ever see a key
  // of its own.
  function scrollBy(steps) {
    if (!root.opened) return
    var next = body.contentY + steps * Style.space(40)
    var limit = Math.max(0, body.contentHeight - body.height)
    body.contentY = Math.max(0, Math.min(limit, next))
  }

  visible: root.opened

  // Reopening starts on the first section rather than wherever the previous
  // read was left.
  onOpenedChanged: if (root.opened) body.contentY = 0

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    // hoverEnabled is doing the real work here: a MouseArea that does not accept
    // hover does not consume a hover event, so the rows underneath went on
    // receiving them and their tooltips floated over the sheet.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onClicked: root.closed()
    }

    // MouseArea does not handle wheel at all, and the panel body is a Flickable,
    // so without this a scroll over the scrim scrolls the view behind the sheet.
    WheelHandler {
      onWheel: function(event) { event.accepted = true }
    }

    BorderSurface {
      id: sheet
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(16), Style.space(440))
      height: Math.min(parent.height - Style.space(16),
                       sheet.contentTopInset + sheet.contentBottomInset
                       + head.implicitHeight + Style.space(10) + body.height)
      color: root.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(16)
      radius: Style.cornerRadius

      // Swallows a click that lands on the sheet so it does not reach the scrim.
      // hoverEnabled for the same reason as the scrim's.
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {}
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: sheet.contentTopInset
        anchors.rightMargin: sheet.contentRightInset
        anchors.bottomMargin: sheet.contentBottomInset
        anchors.leftMargin: sheet.contentLeftInset

        Column {
          id: head
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(2)

          Item {
            width: parent.width
            height: headTitle.implicitHeight

            Text {
              id: headTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "What the words mean"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              color: closeMouse.containsMouse ? Color.accent : root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: closeMouse
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closed()
              }
            }
          }

          Text {
            width: parent.width
            text: "Esc closes this. Up and down scroll it."
            color: root.dimForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelSeparator { width: parent.width }
        }

        Flickable {
          id: body
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: bodyBar.width + Style.space(2)
          anchors.top: head.bottom
          anchors.topMargin: Style.space(10)
          anchors.bottom: parent.bottom
          contentWidth: width
          contentHeight: sections.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          flickDeceleration: 6000

          Column {
            id: sections
            width: body.width
            spacing: Style.space(14)

            Repeater {
              model: root.sections

              Column {
                required property var modelData

                width: sections.width
                spacing: Style.space(4)

                PanelSectionHeader {
                  text: modelData.title
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  width: parent.width
                  visible: modelData.note !== ""
                  text: modelData.note
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: modelData.terms

                  Item {
                    id: termRow
                    required property var modelData
                    readonly property real columnWidth: Math.round(termRow.width * 0.3)
                    // One word wider than the column takes the line above its
                    // sentence instead of breaking mid-word.
                    readonly property bool stacked: termName.implicitWidth > termRow.columnWidth

                    width: parent.width
                    height: (termRow.stacked
                      ? termName.implicitHeight + termText.implicitHeight
                      : Math.max(termName.implicitHeight, termText.implicitHeight)) + Style.space(3)

                    Text {
                      id: termName
                      anchors.left: parent.left
                      anchors.top: parent.top
                      width: termRow.stacked ? termRow.width : termRow.columnWidth
                      text: termRow.modelData.term
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Text {
                      id: termText
                      anchors.left: termRow.stacked ? parent.left : termName.right
                      anchors.leftMargin: termRow.stacked ? 0 : Style.space(8)
                      anchors.right: parent.right
                      anchors.top: termRow.stacked ? termName.bottom : parent.top
                      text: termRow.modelData.text
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }
        }

        Local.ScrollIndicator {
          id: bodyBar
          flickable: body
          anchors.right: parent.right
          anchors.top: body.top
          anchors.bottom: body.bottom
          foreground: root.foreground
        }
      }
    }
  }
}
