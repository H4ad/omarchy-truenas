import QtQuick
import qs.Commons
import "../Ui" as Local
import "../Model.js" as Model

// One card per pool: name and status, a capacity bar, the scrub's state and when
// it last ran, and vdev error counts when they are non-zero.
//
// Three refusals are load-bearing, and each is the difference between a sentence
// and a zero:
//   * an empty pool list is only "no pools" when the poll named no pool warning.
//     A failed pool request leaves the list empty too, and that reads as "the
//     pool state could not be read", never as a NAS that has no pools.
//   * a pool with scan == null says "no scrub on record" rather than inventing a
//     date from a missing endTime.
//   * a clean pool grows no vdev row at all, because a row of zeroes looks like
//     a measurement.
Column {
  id: view
  required property var panel
  spacing: Style.space(6)

  readonly property var nasState: view.panel.state
  readonly property var connection: (view.nasState && view.nasState.connection) || null
  readonly property bool connected: !!(view.connection && view.connection.ok)
  readonly property bool unconfigured: view.panel.mode === "unconfigured"
    || !!(view.connection && String(view.connection.error || "") === "unconfigured")
  readonly property var pools: (view.nasState && Model.arrayLike(view.nasState.pools))
    ? view.nasState.pools : []

  // The poll names a section it could not fetch in `warnings`. A failed pool
  // request leaves `pools` empty, so without this an unread pool list would
  // render as the NAS having none.
  readonly property var poolWarning: {
    var warnings = (view.nasState && Model.arrayLike(view.nasState.warnings))
      ? view.nasState.warnings : []
    for (var i = 0; i < warnings.length; i++) {
      if (warnings[i] && String(warnings[i].section) === "pool") return warnings[i]
    }
    return null
  }

  readonly property string emptyText: {
    if (!view.nasState) return "No state yet. The service writes it after the first poll."
    if (view.unconfigured) return "not configured yet · run truenasctl login <url>"
    if (!view.connected)
      return "No answer from the NAS: " + (Model.errorSentence(view.connection) || "the poll failed")
    if (view.pools.length > 0) return ""
    if (view.poolWarning) {
      var reason = String(view.poolWarning.message || view.poolWarning.error || "")
      return "the pool state could not be read" + (reason !== "" ? ": " + reason : "")
    }
    return "no pools"
  }

  // ONLINE keeps the plain foreground, DEGRADED takes the accent, and everything
  // else is urgent. An unknown status ranks below FAULTED, so it lands urgent
  // rather than being mistaken for healthy.
  function statusColor(status) {
    var rank = Model.poolStatusRank(status)
    if (rank >= Model.poolStatusRank("ONLINE")) return view.panel.contentForeground
    if (rank === Model.poolStatusRank("DEGRADED")) return Color.accent
    return view.panel.urgentColor
  }

  function scrubText(scan) {
    // Reading nowTick in the binding chain is what re-derives the age as the
    // panel ticks; Date.now() supplies the value itself.
    var tick = view.panel.nowTick
    if (!scan || typeof scan !== "object") return "no scrub on record"
    var state = String(scan.state || "")
    var text
    if (state === "RUNNING") {
      var pct = scan.percentage
      text = (pct !== null && pct !== undefined && pct !== "" && isFinite(Number(pct)))
        ? "scrubbing " + Math.round(Number(pct)) + "%"
        : "scrubbing"
    } else if (state !== "") {
      text = state.toLowerCase()
      var age = Model.ageSeconds(scan.endTime, Date.now())
      if (age >= 0) text += " " + Model.ageText(age) + " ago"
    } else {
      text = "scrub on record"
    }
    var errors = scan.errors
    if (errors !== null && errors !== undefined && isFinite(Number(errors)) && Number(errors) > 0)
      text += " · " + Number(errors) + " scrub errors"
    return text
  }

  function vdevCount(value) {
    if (value === null || value === undefined || value === "") return 0
    var n = Number(value)
    return isFinite(n) && n > 0 ? n : 0
  }

  function vdevText(errors) {
    if (!errors || typeof errors !== "object") return ""
    var parts = []
    var read = view.vdevCount(errors.read)
    var write = view.vdevCount(errors.write)
    var checksum = view.vdevCount(errors.checksum)
    if (read > 0) parts.push("read " + read)
    if (write > 0) parts.push("write " + write)
    if (checksum > 0) parts.push("checksum " + checksum)
    return parts.length ? "vdev errors: " + parts.join(" · ") : ""
  }

  // Allocated, free and total, each drawn only when the poll reported it.
  // `Model.formatBytes` answers "" for a missing or non-finite value, so an
  // unknown free leaves the sentence short rather than reading as 0 B; a real
  // numeric zero is a reported zero and prints "0 B".
  function capacityText(pool) {
    if (!pool || typeof pool !== "object") return ""
    var parts = []
    var used = Model.formatBytes(pool.allocated)
    var free = Model.formatBytes(pool.free)
    var total = Model.formatBytes(pool.size)
    if (used !== "") parts.push(used + " used")
    if (free !== "") parts.push(total !== "" ? free + " free of " + total : free + " free")
    else if (total !== "") parts.push(total + " total")
    return parts.join(" · ")
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: view.emptyText !== ""
    text: view.emptyText
    color: view.connected || !view.nasState ? view.panel.contentForeground : (view.unconfigured ? Color.accent : view.panel.urgentColor)
    font.family: view.panel.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: view.pools

    Local.Card {
      id: poolCard
      required property var modelData
      width: view.width
      foreground: view.panel.contentForeground
      fontFamily: view.panel.contentFontFamily

      readonly property string statusWord: String(modelData.status || "unknown")
      readonly property string scrubLine: view.scrubText(modelData.scan)
      readonly property string vdevLine: view.vdevText(modelData.vdevErrors)
      readonly property string capacityLine: view.capacityText(modelData)

      Item {
        width: parent.width
        implicitHeight: Math.max(poolName.implicitHeight, poolStatus.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: poolName
          anchors.left: parent.left
          anchors.right: poolStatus.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: String(modelData.name || "unnamed pool")
          color: view.panel.contentForeground
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: poolStatus
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: poolCard.statusWord
          color: view.statusColor(poolCard.statusWord)
          font.family: view.panel.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Local.CapacityBar {
        width: parent.width
        name: ""
        allocated: modelData.allocated
        size: modelData.size
        usedPct: modelData.usedPct
        foreground: view.panel.contentForeground
        dimForeground: view.panel.dimForeground
        accentColor: Color.accent
        urgentColor: view.panel.urgentColor
        fontFamily: view.panel.contentFontFamily
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: poolCard.capacityLine !== ""
        text: poolCard.capacityLine
        color: view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: poolCard.scrubLine
        color: (modelData.scan && Number(modelData.scan.errors) > 0)
          ? view.panel.urgentColor : view.panel.dimForeground
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        visible: poolCard.vdevLine !== ""
        text: poolCard.vdevLine
        color: view.panel.urgentColor
        font.family: view.panel.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
