import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model
import "../Search.js" as Search
import "../Links.js" as Links

// The shares and network inventory: the SMB, NFS and iSCSI shares the NAS
// serves, then the network interfaces it serves them over. One combined view,
// read-only. M5 ships no share write, so there is no action, no confirmation
// and no bar variant here.
//
// The same refusal Views/Services.qml makes: a failed section leaves its list
// empty, and `warnings` names which, so an unread section never renders as a NAS
// that serves nothing over no link. Each share type fails on its own, and the
// interface list fails on its own, so one failure leaves the other blocks up.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property bool unconfigured: view.panel.mode === "unconfigured"
    || !!(view.connection && String(view.connection.error || "") === "unconfigured")
  readonly property var warnings: (view.nasState && Model.arrayLike(view.nasState.warnings))
    ? view.nasState.warnings : []

  readonly property var shares: (view.nasState && view.nasState.shares)
    ? view.nasState.shares : null
  readonly property var smb: (view.shares && Model.arrayLike(view.shares.smb)) ? view.shares.smb : []
  readonly property var nfs: (view.shares && Model.arrayLike(view.shares.nfs)) ? view.shares.nfs : []
  readonly property var iscsi: (view.shares && Model.arrayLike(view.shares.iscsi))
    ? view.shares.iscsi : []
  readonly property var network: (view.nasState && Model.arrayLike(view.nasState.network))
    ? view.nasState.network : []

  property string sharesQuery: ""
  property string networkQuery: ""

  readonly property var smbRows: Search.shares(view.smb, view.sharesQuery)
  readonly property var nfsRows: Search.shares(view.nfs, view.sharesQuery)
  readonly property var iscsiRows: Search.shares(view.iscsi, view.sharesQuery)
  readonly property var networkRows: Search.interfaces(view.network, view.networkQuery)

  readonly property string sharesUrl: Links.sharesUrl(view.panel.baseUrl)

  // The `warnings` entry for one section, or null. Only that section's own
  // failure turns its list into "I could not tell".
  function sectionWarning(section) {
    for (var i = 0; i < view.warnings.length; i++) {
      if (String(view.warnings[i] && view.warnings[i].section || "") === section)
        return view.warnings[i]
    }
    return null
  }

  function warningLineFor(section, noun) {
    var warning = view.sectionWarning(section)
    if (!warning) return ""
    var reason = String(warning.message || warning.error || "")
    return "the " + noun + " could not be read" + (reason !== "" ? ": " + reason : "")
  }

  // Empty only while there is something to show: the warning line already says
  // why the list is missing, and a filter that matches nothing says so itself.
  function emptyFor(section, total, shown, noun) {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (view.unconfigured) return "not configured yet · run truenasctl login <url>"
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (total > 0 && shown === 0) return "no " + noun + " match the filter"
    if (total > 0) return ""
    if (view.sectionWarning(section)) return ""
    return "no " + noun + " reported"
  }

  // The network summary names the links that are down and the ones whose state
  // the poll could not read, so a list of unknown rows never reads as every link
  // up. It counts the raw list, not the filtered rows, and a count at zero
  // prints nothing.
  readonly property string interfaceSummary: {
    var parts = []
    var down = Model.downInterfaces(view.network).length
    var unknown = Model.unknownInterfaces(view.network).length
    if (down > 0) parts.push(down + (down === 1 ? " link down" : " links down"))
    if (unknown > 0) parts.push(unknown + (unknown === 1 ? " link unknown" : " links unknown"))
    return parts.join(" · ")
  }

  // A down link is a real fault; an unknown link is not, so it stays dim.
  readonly property color interfaceSummaryColor: Model.downInterfaces(view.network).length > 0
    ? view.panel.urgentColor : view.panel.dimForeground

  // 0 up keeps the plain foreground, 1 down is urgent, and 2 (blank or
  // LINK_STATE_UNKNOWN) is dim: "I cannot tell" must not look like a dead link.
  function linkColor(iface) {
    switch (Model.linkStateRank(iface && iface.linkState)) {
      case 0:  return view.panel.contentForeground
      case 1:  return view.panel.urgentColor
      default: return view.panel.dimForeground
    }
  }

  // The negotiated speed is the human value; the configured media type is the
  // fallback, and neither is "unknown" unless both are missing.
  function mediaText(iface) {
    var subtype = String(iface && iface.mediaSubtype || "")
    if (subtype !== "") return subtype
    var type = String(iface && iface.mediaType || "")
    return type !== "" ? type : "media unknown"
  }

  function addressText(iface) {
    var addresses = (iface && Model.arrayLike(iface.addresses)) ? iface.addresses : []
    var parts = []
    for (var i = 0; i < addresses.length; i++) {
      var address = String(addresses[i] && addresses[i].address || "")
      if (address === "") continue
      var netmask = addresses[i] && addresses[i].netmask
      parts.push(netmask === null || netmask === undefined ? address : address + "/" + netmask)
    }
    return parts.length > 0 ? parts.join(", ") : "no addresses"
  }

  // SMB and iSCSI have a name; NFS only has its path, so the path is the title.
  function shareTitle(row, hasName) {
    var name = hasName ? String(row && row.name || "") : ""
    if (name !== "") return name
    var path = String(row && row.path || "")
    return path !== "" ? path : "unnamed share"
  }

  // The flags a share type carries, in words. A flag the type does not have is
  // never rendered, because the caller does not call this for it.
  function shareMarkers(row) {
    var parts = []
    parts.push(row && row.enabled === true ? "enabled" : "disabled")
    if (row && row.locked === true) parts.push("locked")
    if (row && row.readonly === true) parts.push("read-only")
    return parts.join(" · ")
  }

  function iscsiDetail(row) {
    var parts = []
    var alias = String(row && row.alias || "")
    if (alias !== "") parts.push(alias)
    var mode = String(row && row.mode || "")
    if (mode !== "") parts.push(mode)
    return parts.join(" · ")
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.sharesUrl !== ""
    text: Model.GLYPH.link + "  Open shares in TrueNAS"
    color: openMouse.containsMouse ? Color.accent : Qt.darker(view.panel.contentForeground, 1.4)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.openUrl(view.sharesUrl)
    }
  }

  // ------------------------------------------------------------------ shares
  Text {
    width: parent.width
    text: "SHARES"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter shares"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.sharesQuery = value }
  }

  Text {
    width: parent.width
    text: "SMB"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("smb", "SMB share list") !== ""
    text: view.warningLineFor("smb", "SMB share list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("smb", view.smb.length, view.smbRows.length, "SMB shares") !== ""
    text: view.emptyFor("smb", view.smb.length, view.smbRows.length, "SMB shares")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.smbRows

    Local.Card {
      id: smbCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      Text {
        width: parent.width
        text: view.shareTitle(smbCard.modelData, true)
        color: view.panel.contentForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: String(smbCard.modelData.path || "path unknown")
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: view.shareMarkers(smbCard.modelData)
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Text {
    width: parent.width
    text: "NFS"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("nfs", "NFS export list") !== ""
    text: view.warningLineFor("nfs", "NFS export list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("nfs", view.nfs.length, view.nfsRows.length, "NFS exports") !== ""
    text: view.emptyFor("nfs", view.nfs.length, view.nfsRows.length, "NFS exports")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.nfsRows

    Local.Card {
      id: nfsCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      Text {
        width: parent.width
        text: view.shareTitle(nfsCard.modelData, false)
        color: view.panel.contentForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: view.shareMarkers(nfsCard.modelData)
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Text {
    width: parent.width
    text: "ISCSI"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("iscsi", "iSCSI target list") !== ""
    text: view.warningLineFor("iscsi", "iSCSI target list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("iscsi", view.iscsi.length, view.iscsiRows.length, "iSCSI targets") !== ""
    text: view.emptyFor("iscsi", view.iscsi.length, view.iscsiRows.length, "iSCSI targets")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.iscsiRows

    Local.Card {
      id: iscsiCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      Text {
        width: parent.width
        text: view.shareTitle(iscsiCard.modelData, true)
        color: view.panel.contentForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: view.iscsiDetail(iscsiCard.modelData)
        visible: text !== ""
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ----------------------------------------------------------------- network
  Text {
    width: parent.width
    text: "NETWORK"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Local.FilterField {
    width: parent.width
    placeholder: "filter interfaces"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
    onFilterChanged: function(value) { view.networkQuery = value }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.warningLineFor("network", "interface list") !== ""
    text: view.warningLineFor("network", "interface list")
    color: view.panel.urgentColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyFor("network", view.network.length, view.networkRows.length, "interfaces") !== ""
    text: view.emptyFor("network", view.network.length, view.networkRows.length, "interfaces")
    color: (view.connected || !view.nasState) ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.interfaceSummary !== ""
    text: view.interfaceSummary
    color: view.interfaceSummaryColor
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.networkRows

    Local.Card {
      id: ifaceCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      Item {
        width: parent.width
        implicitHeight: Math.max(ifaceName.implicitHeight, ifaceLink.implicitHeight)

        Text {
          id: ifaceName
          anchors.left: parent.left
          anchors.right: ifaceLink.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: String(ifaceCard.modelData.name || "unnamed interface")
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: ifaceLink
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.linkStateText(ifaceCard.modelData.linkState)
          color: view.linkColor(ifaceCard.modelData)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        width: parent.width
        text: String(ifaceCard.modelData.type || "type unknown") + " · " + view.mediaText(ifaceCard.modelData)
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: view.addressText(ifaceCard.modelData)
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
