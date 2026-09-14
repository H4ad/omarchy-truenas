import QtQuick
import qs.Commons
import qs.Ui
import "../Ui" as Local

// Configuration for this bar item. Two different things live here and the view
// keeps them apart:
//
//   WIDGET  variant, hideWhenHealthy and panelWidth come from shell.json, so
//           they belong to the bar item. Only the variant is editable here,
//           through the same picker the reference plugin uses; the other two
//           are shown as they are.
//   NAS     baseUrl, insecureTLS, pollSeconds and whether a key is set come from
//           truenasctl config list. The base URL is set by `truenasctl login`,
//           and the key is the one thing this view writes, on stdin.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  property string keyError: ""
  property string keyNotice: ""

  // The panel owns config loading: it calls loadConfig() from showView("config")
  // (and from the refresh and key-save paths), so this view must not issue a
  // second `config list` of its own.
  readonly property var config: view.panel.configData

  function keyStatusText() {
    if (!view.config) return "reading config…"
    if (view.config.keySet === true) return "a key is set"
    return "no key set"
  }

  function baseUrlText() {
    if (!view.config) return "reading config…"
    if (!view.config.instance) return "not configured; run truenasctl login"
    return String(view.config.instance.baseUrl || "")
  }

  function configValueText(name, fallback) {
    if (!view.config) return "…"
    var value = view.config[name]
    return value === undefined || value === null ? String(fallback) : String(value)
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: view.width
    implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: label
      color: view.panel.dimForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: rowValue
      anchors.left: rowLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: value
      color: view.panel.contentForeground
      font.family: view.panel.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: text !== ""
    text: {
      if (view.keyError !== "") return view.keyError
      if (view.panel.actionError !== "") return view.panel.actionError
      if (view.keyNotice !== "") return view.keyNotice
      if (view.panel.actionNotice !== "") return view.panel.actionNotice
      return ""
    }
    color: (view.keyError !== "" || view.panel.actionError !== "")
      ? view.panel.urgentColor : view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "WIDGET"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "the bar item's own settings; the variant is written back to shell.json here"
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Local.VariantPicker {
    width: parent.width
    value: view.panel.setting("variant", "Default")
    foreground: view.panel.contentForeground
    dimForeground: view.panel.dimForeground
    urgentColor: view.panel.urgentColor
    accentColor: Color.accent
    fontFamily: view.panel.contentFontFamily
    onPicked: function(variant) { view.panel.setWidgetSetting("variant", variant) }
  }

  InfoRow {
    label: "hide when healthy"
    value: view.panel.setting("hideWhenHealthy", false) ? "on" : "off"
  }

  InfoRow {
    label: "panel width"
    value: String(view.panel.setting("panelWidth", 460))
  }

  PanelSeparator { width: parent.width }

  PanelSectionHeader {
    text: "NAS"
    foreground: view.panel.contentForeground
    fontFamily: view.panel.contentFontFamily
  }

  InfoRow {
    label: "base url"
    value: view.baseUrlText()
  }

  InfoRow {
    label: "key"
    value: view.keyStatusText()
  }

  InfoRow {
    label: "insecure tls"
    value: view.config && view.config.insecureTLS === true ? "on" : "off"
  }

  InfoRow {
    label: "poll seconds"
    value: view.configValueText("pollSeconds", 30)
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Replacing the key runs truenasctl config set-key. It is read on stdin and "
      + "stored at mode 600; it is never passed as an argument or shown here."
    color: view.panel.dimForeground
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Local.SecretField {
    width: parent.width
    ctlPath: view.panel.ctlPath
    placeholderText: view.config && view.config.keySet === true
      ? "replace the API key" : "paste the API key"
    foreground: view.panel.contentForeground
    accent: Color.accent
    fontFamily: view.panel.contentFontFamily
    onSaved: {
      view.keyError = ""
      view.keyNotice = "key stored"
      view.panel.loadConfig()
      view.panel.refreshAfterWrite()
    }
    onFailed: function(message) {
      view.keyNotice = ""
      view.keyError = message
    }
    onCanceled: {}
  }
}
