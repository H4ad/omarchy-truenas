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
      note: "The bar answers one question: is the NAS healthy right now. Press the ? in the panel header to open this sheet.",
      terms: [
        { term: "quiet", text: "Connected, every pool ONLINE and nothing firing, drawn as a dimmed glyph that proves the plugin is alive." },
        { term: "firing", text: "Connected with alerts below error, so the bar prints the active alert count." },
        { term: "degraded", text: "A pool is not ONLINE or an alert is at error or worse, so the bar tints red." },
        { term: "offline", text: "The last poll could not reach the NAS, so the bar shows a plug glyph and no number it did not get." },
        { term: "unconfigured", text: "No API key yet, so the bar shows a cog glyph and you run truenasctl login <url> with the key on stdin." }
      ]
    },
    {
      title: "POOLS",
      note: "Healthy is ONLINE only. A status the plugin does not recognise counts as worse than a known bad one, so it is never buried.",
      terms: [
        { term: "capacity", text: "The fullest pool's used percentage, and an unknown capacity reads as a sentence rather than 0%." },
        { term: "scrub", text: "The last scrub and its age, and no scrub on record says so rather than inventing a date." },
        { term: "vdev errors", text: "Read, write or checksum errors on a vdev, shown only when they are non-zero." }
      ]
    },
    {
      title: "DISKS",
      note: "One card per disk, ordered as the NAS reports them. The view exists to catch a disk running hot before it becomes the pool's problem.",
      terms: [
        { term: "temperature", text: "The disk's current reading in Celsius, and a missing reading says unknown rather than 0 degrees." },
        { term: "tempState", text: "ok, warning or critical as set by the poll's threshold, so warning is amber and critical is red." },
        { term: "threshold", text: "The temperature the NAS starts warning at, shown only when the poll reported it." }
      ]
    },
    {
      title: "SERVICES",
      note: "One card per service and the three verbs that change it. Every write asks first and the panel re-polls afterwards.",
      terms: [
        { term: "state", text: "Whether the service runs now, and a word the plugin does not know reads as unknown rather than stopped." },
        { term: "enabled", text: "Whether the service starts on boot, which is separate from whether it is running now." },
        { term: "restart", text: "Stops and starts the service and drops existing connections, so the confirmation names that consequence first." }
      ]
    },
    {
      title: "APPS",
      note: "The apps the NAS runs as containers, with their control verbs. An app write lands asynchronously, so the next poll catches up.",
      terms: [
        { term: "state", text: "Whether the app is deployed and serving, and a blank or transitional word reads as unknown rather than stopped." },
        { term: "train", text: "The catalog generation the app came from, such as stable or community." },
        { term: "update available", text: "The NAS reports a newer image for the app, and redeploy pulls it." },
        { term: "redeploy", text: "Stops the app and rebuilds it from its image, so unsaved container state is lost." }
      ]
    },
    {
      title: "PROTECTION",
      note: "The scheduled jobs that keep data safe: replication, cloud sync, snapshots and scrubs. Run now starts one immediately, after a confirmation.",
      terms: [
        { term: "replication", text: "A ZFS send and receive to another dataset or NAS, shown with its direction, transport and target." },
        { term: "cloud sync", text: "A scheduled copy to or from a remote provider, shown with its direction and path." },
        { term: "snapshot task", text: "A periodic point-in-time copy of a dataset, and the card names the last snapshot taken." },
        { term: "scrub", text: "A full scan of a pool that checks every block against its checksum, which can take hours." },
        { term: "run now", text: "Starts the task outside its schedule, after a confirmation and a re-poll so the panel reads the NAS back." }
      ]
    },
    {
      title: "SHARES AND NETWORK",
      note: "What the NAS serves and the links it serves them over. Read-only: this milestone ships no share write, so every card here is a report.",
      terms: [
        { term: "SMB", text: "The share protocol Windows and macOS clients use, shown with its path and its enabled, locked or read-only flags." },
        { term: "NFS", text: "The share protocol Unix clients use, shown by its path because NFS exports have no name." },
        { term: "iSCSI", text: "A block-level target a client mounts as a disk, shown with its alias and mode." },
        { term: "interface", text: "A physical or virtual network adapter, shown with its type, negotiated media and addresses." },
        { term: "link state", text: "Whether the interface is up or down, and a state the plugin does not recognise reads as unknown rather than down." }
      ]
    },
    {
      title: "ALERTS",
      note: "Buckets worst first: critical, error, warning, notice, info. Counts are over non-dismissed alerts only.",
      terms: [
        { term: "dismiss", text: "Hides an alert on the NAS itself, and because it is a write it asks first and the panel re-polls afterwards." },
        { term: "restore", text: "Puts a dismissed alert back." }
      ]
    },
    {
      title: "SECRETS",
      note: "The key travels on stdin to truenasctl, never in argv, a shell string or shell.json.",
      terms: [
        { term: "key set", text: "A key resolves from the credentials file at mode 600, and its value is never read back into the panel." },
        { term: "credentials_permissions", text: "The credentials file is readable by others, so fix it with chmod 600 <file>." },
        { term: "insecureTLS", text: "Off by default, and a self-signed certificate is reported with the fix rather than quietly skipped." }
      ]
    },
    {
      title: "WHEN SOMETHING FAILS",
      note: "The plugin tells you what it could not read rather than showing a zero, so a failed section never looks like a healthy one.",
      terms: [
        { term: "warning", text: "One section did not answer, so the sentence names the section and the reason while the healthy rows stay up." },
        { term: "unknown", text: "A fact the poll did not get is written as a word, never as 0 or 0%, so it cannot be mistaken for a real zero." },
        { term: "no state yet", text: "The service writes state.json after the first poll, so run truenasctl poll to fill it now." },
        { term: "filter", text: "A filter that matches nothing says no noun match the filter rather than showing an empty NAS." }
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
