.pragma library

// What the bar item prints, given the mode the poller reported and the values
// behind it. No QML types in here and no Model.js internals: every value a
// segment prints arrives through the `view` argument, so each decision about
// what the bar says is readable and testable under node, and a change to Model
// cannot quietly change the bar.
//
// The unit is a segment: { text, severity }. `severity` is one of
// critical | error | warning | notice | info, or "" for the item's own tint, so
// this file never names a colour and never needs to know the theme.
//
// The `view` contract, all fields a plain value the caller owns:
//   mode          "unconfigured" | "offline" | "degraded" | "firing" | "quiet".
//                 Only unconfigured and offline override the variant; any other
//                 mode is ordinary (so "partial" with a single NAS never occurs).
//   alertCount    number of active (non-dismissed) alerts. 0 means none.
//   capacityText  the fullest pool's capacity as it should read, e.g. "71%".
//                 "" or null when the capacity is not known; never "0%".
//   worstPool     the worst pool's status word, e.g. "DEGRADED". "" when there
//                 are no pools to speak of.
//   worstLevel    the severity word to tint the body with, e.g. "warning".
//                 "" when everything is healthy or nothing is known.
//   tempText      the hottest disk's label, e.g. "54°". "" when no disk answered
//                 with a temperature; never "0°".
//   tempLevel     "critical" | "warning", or "" for the item's own tint, which
//                 includes a reading that is merely ok.
//
// An unreachable or unconfigured NAS overrides every variant with one glyph and
// no numbers: a value the plugin cannot vouch for is never printed as one.
//
// `glyphs` is { main, offline, unconfigured }. The widget owns the glyph set:
// `main` is the normal glyph, `offline` the plug for an unreachable NAS,
// `unconfigured` the cog for one that was never set up. Each override falls
// back to the next, then to "", because a mark a caller can forget to pass is a
// mark that can silently go missing.

var VARIANTS = ["Default", "Icon", "Alerts", "Capacity", "Pool", "Temp", "Full", "Severity", "Down", "Protection", "Uptime", "CapacityBar", "Pools", "DiskHeat", "Sparkline"];
var DEFAULT_VARIANT = "Default";
var SEPARATOR = "·";

// The alert buckets, worst first. Severity prints one glyph per non-empty
// bucket, worst two only, so the bar does not grow a legend.
var SEVERITY_ORDER = ["critical", "error", "warning", "notice", "info"];
var SEVERITY_GLYPH = {
  critical: "\u25B2", // solid up triangle
  error:    "\u25CF", // solid circle
  warning:  "\u25B3", // hollow up triangle
  notice:   "\u25CB", // hollow circle
  info:     "\u00B7"  // middle dot
};
var SEVERITY_BUCKETS = 2;

// The four variants that draw a shape instead of type. `chartKind` maps a
// variant to the shape name the widget renders; a text variant has no entry and
// gets "".
var CHART_KINDS = {
  "CapacityBar": "bar",
  "Pools":       "dots",
  "DiskHeat":    "heat",
  "Sparkline":   "spark"
};
var CAPACITY_CELLS = 6;
var POOL_DOT_CAP = 10;
var DISK_DOT_CAP = 12;
var SPARK_COLUMNS = 30;

// A dot/heat list is wide enough after this many squares; the rest move to the
// tooltip as a +N count rather than eating the bar. The severity list the caller
// passes is the full one, so the count stays honest.
function listLike(value) {
  return !!value && typeof value !== "string" && typeof value.length === "number";
}

// Modes that replace the whole variant with a glyph. They are the only place
// this file says less than the caller passed, and it says less on purpose.
var OVERRIDE_MODES = ["unconfigured", "offline"];

// The pinned setting, case-normalized to the manifest spelling. An empty or
// unknown setting falls back to the built-in Default ("the active alert count
// when anything is firing, otherwise the fullest pool's capacity"); it never
// widens to accept a value the manifest does not offer.
function resolveVariant(setting) {
  var wanted = String(setting == null ? "" : setting).toLowerCase();
  for (var i = 0; i < VARIANTS.length; i++) {
    if (VARIANTS[i].toLowerCase() === wanted) return VARIANTS[i];
  }
  return DEFAULT_VARIANT;
}

function segment(text, severity) {
  return {
    text: String(text == null ? "" : text),
    severity: String(severity == null ? "" : severity)
  };
}

function isOverride(mode) {
  return OVERRIDE_MODES.indexOf(String(mode || "")) !== -1;
}

function overrideGlyph(mode, glyphs) {
  var icons = glyphs || {};
  if (String(mode) === "unconfigured") {
    return String(icons.unconfigured || icons.offline || icons.main || "");
  }
  return String(icons.offline || icons.main || "");
}

function mainGlyph(glyphs) {
  return String((glyphs || {}).main || "");
}

// The bar prints whole things only. A count that is not a positive number is
// nothing to say, not a zero to draw.
function countOf(value) {
  var number = Number(value);
  if (!isFinite(number) || number <= 0) return 0;
  return Math.floor(number);
}

function textOf(value) {
  return value == null ? "" : String(value);
}

// A zero spends a bar slot on the absence of something. A successful poll with
// no alerts prints nothing rather than "0": the absence is the message.
function alertSegments(view) {
  var count = countOf(view.alertCount);
  if (count <= 0) return [];
  return [segment(String(count), view.worstLevel)];
}

// Unknown capacity is "", never "0%": a pool list that did not answer must not
// read as an empty pool.
function capacitySegments(view) {
  var text = textOf(view.capacityText);
  if (text === "") return [];
  return [segment(text, view.worstLevel)];
}

// The worst pool's own status word, not a derived number: "DEGRADED" is what a
// person looks for, and the tint carries the rest.
function poolSegments(view) {
  var word = textOf(view.worstPool);
  if (word === "") return [];
  return [segment(word, view.worstLevel)];
}

// The hottest disk's label, tinted by its own level rather than the alert
// level. Unknown is "", never a fabricated zero: a disk that did not answer is
// not a disk at 0°.
function tempSegments(view) {
  var text = textOf(view.tempText);
  if (text === "") return [];
  return [segment(text, view.tempLevel)];
}

// One segment per alert bucket that has something in it, worst first, at most
// two. Each segment carries its own bucket as its severity, so a critical count
// and a warning count are tinted differently in the same row. The glyph says
// which bucket at a glance; the count says how many.
function severitySegments(view) {
  var counts = (view && typeof view.counts === "object" && view.counts) ? view.counts : {};
  var out = [];
  for (var i = 0; i < SEVERITY_ORDER.length && out.length < SEVERITY_BUCKETS; i++) {
    var level = SEVERITY_ORDER[i];
    var count = countOf(counts[level]);
    if (count <= 0) continue;
    out.push(segment(String(count) + String(SEVERITY_GLYPH[level] || ""), level));
  }
  return out;
}

// Services and apps that are not running, as one count. Zero is nothing to say,
// never "0": the bar does not spend a slot on a good state.
function downSegments(view) {
  var count = countOf(view && view.downTotal);
  if (count <= 0) return [];
  return [segment(String(count), "warning")];
}

// Failed replication, cloud sync, snapshot and scrub jobs, as one count. Zero is
// nothing to say, never "0".
function protectionSegments(view) {
  var count = countOf(view && view.protectionCount);
  if (count <= 0) return [];
  return [segment(String(count), "warning")];
}

// Time since boot, preformatted by the caller (e.g. "up 18h"). Untinted: uptime
// is context, not a state. A missing uptime is nothing to say.
function uptimeSegments(view) {
  var text = textOf(view && view.uptimeText);
  if (text === "") return [];
  return [segment(text, "")];
}

// Alerts then capacity, each half dropped when unknown. The separator appears
// only between two halves that both printed.
function fullSegments(view) {
  var alerts = alertSegments(view);
  var capacity = capacitySegments(view);
  if (alerts.length === 0) return capacity;
  if (capacity.length === 0) return alerts;
  return alerts.concat([segment(SEPARATOR, "")], capacity);
}

// "Anything is firing" is a positive alert count, or the firing mode the
// poller reported. A degraded state with no alerts is not firing, so it falls
// through to the capacity, tinted by the worst level.
function defaultSegments(view) {
  var firing = countOf(view.alertCount) > 0
    || String(view.mode || "") === "firing";
  if (firing) {
    var alerts = alertSegments(view);
    if (alerts.length > 0) return alerts;
  }
  return capacitySegments(view);
}

function bodySegments(variant, view) {
  switch (resolveVariant(variant)) {
    case "Alerts":
      return alertSegments(view);
    case "Capacity":
      return capacitySegments(view);
    case "Pool":
      return poolSegments(view);
    case "Temp":
      return tempSegments(view);
    case "Full":
      return fullSegments(view);
    case "Severity":
      return severitySegments(view);
    case "Down":
      return downSegments(view);
    case "Protection":
      return protectionSegments(view);
    case "Uptime":
      return uptimeSegments(view);
    // A chart variant prints no body text. The widget draws the shape in the
    // icon slot and the glyph is the only segment left for any other caller.
    case "CapacityBar":
    case "Pools":
    case "DiskHeat":
    case "Sparkline":
      return [];
    default:
      return defaultSegments(view);
  }
}

// The shape a chart variant draws: "bar" | "dots" | "heat" | "spark", or "" for
// a text variant. The widget switches on this and never on the variant name.
function chartKind(variant) {
  var resolved = resolveVariant(variant);
  return Object.prototype.hasOwnProperty.call(CHART_KINDS, resolved) ? CHART_KINDS[resolved] : "";
}

// A capped list of { severity } squares plus the number that did not fit. The
// overflow is what the tooltip adds back as "+N", so a large NAS still names its
// true size rather than pretending it has only the squares that fitted.
function dotItems(severities, cap) {
  var list = listLike(severities) ? severities : [];
  var items = [];
  for (var i = 0; i < list.length && items.length < cap; i++) {
    items.push({ severity: String(list[i] == null ? "" : list[i]) });
  }
  return { items: items, overflow: Math.max(0, list.length - items.length) };
}

// The spec for a chart variant, or null when the variant is text, the mode
// overrides everything, or there is nothing to draw. "Nothing to draw" is the
// same rule as the text variants: unknown is blank, never a zero-length shape.
// The caller passes plain, already-reduced data; this file only decides the
// shape and the severities.
function chartFor(variant, view) {
  var v = view || {};
  if (isOverride(String(v.mode || ""))) return null;

  switch (resolveVariant(variant)) {
    case "CapacityBar": {
      if (textOf(v.capacityText) === "") return null;
      var total = CAPACITY_CELLS;
      var filled = countOf(v.capacityFill);
      if (filled > total) filled = total;
      return { kind: "bar", filled: filled, total: total,
               label: textOf(v.capacityText), severity: String(v.worstLevel || "") };
    }
    case "Pools": {
      var pools = dotItems(v.poolDots, POOL_DOT_CAP);
      if (pools.items.length === 0) return null;
      return { kind: "dots", items: pools.items, overflow: pools.overflow };
    }
    case "DiskHeat": {
      var disks = dotItems(v.diskDots, DISK_DOT_CAP);
      if (disks.items.length === 0) return null;
      return { kind: "heat", items: disks.items, overflow: disks.overflow };
    }
    case "Sparkline": {
      var columns = listLike(v.sparkColumns) ? v.sparkColumns : [];
      var hasValue = false;
      for (var i = 0; i < columns.length; i++) {
        if (columns[i] !== null && columns[i] !== undefined) { hasValue = true; break; }
      }
      if (!hasValue) return null;
      return { kind: "spark", columns: columns, severity: String(v.worstLevel || "") };
    }
    default:
      return null;
  }
}

// `view` is the plain object documented at the top; `glyphs` the widget's set.
// The main glyph leads every ordinary variant, and the Icon variant is that one
// glyph tinted by the worst state.
function segmentsFor(variant, view, glyphs) {
  var v = view || {};
  var mode = String(v.mode || "");

  if (isOverride(mode)) {
    return [segment(overrideGlyph(mode, glyphs), "")];
  }

  var resolved = resolveVariant(variant);
  if (resolved === "Icon") {
    return [segment(mainGlyph(glyphs), v.worstLevel)];
  }

  return [segment(mainGlyph(glyphs), "")].concat(bodySegments(resolved, v));
}

// The non-tinted path and the sizing path both read this: one space between
// segments, and an empty segment leaves no double space.
function textFor(segments) {
  var parts = [];
  for (var i = 0; i < (segments || []).length; i++) {
    var text = String((segments[i] || {}).text || "");
    if (text !== "") parts.push(text);
  }
  return parts.join(" ");
}

// One tinted string cannot hold two colours, so this is what decides whether
// the widget draws through `text` or through a Row in `iconComponent`. More than
// one distinct non-empty severity is the point where a single tint cannot say
// it; the glyph and the separator are untinted and do not count.
function isMultiColour(segments) {
  var seen = [];
  for (var i = 0; i < (segments || []).length; i++) {
    var severity = String((segments[i] || {}).severity || "");
    if (severity !== "" && seen.indexOf(severity) === -1) seen.push(severity);
  }
  return seen.length > 1;
}

// The one severity the whole list carries, or "" when there are none or they
// disagree. The single-tint path paints one colour, so this is what that
// colour is: without it a lone hot disk would fall back to the alert counts'
// tint and look quiet when the disk is not.
function soleSeverity(segments) {
  var found = "";
  for (var i = 0; i < (segments || []).length; i++) {
    var severity = String((segments[i] || {}).severity || "");
    if (severity === "") continue;
    if (found === "") found = severity;
    else if (found !== severity) return "";
  }
  return found;
}

// The one sample the config picker previews against, with a value in every
// field the text and chart variants read. It lives here, next to the code that
// consumes it, so the picker and the node test that proves no variant previews
// blank read the same numbers; a new view field has to be added here too, and
// the test catches it when a variant goes empty.
function sampleView() {
  return {
    mode: "firing", alertCount: 3,
    counts: { critical: 0, error: 2, warning: 1, notice: 0, info: 1 },
    capacityText: "71%", capacityFill: 4,
    worstPool: "DEGRADED", worstLevel: "warning",
    tempText: "54\u00B0", tempLevel: "warning",
    downTotal: 1, protectionCount: 1, uptimeText: "up 18h",
    poolDots: [{ severity: "" }, { severity: "" }, { severity: "warning" }],
    diskDots: [{ severity: "warning" }, { severity: "" }, { severity: "" }],
    sparkColumns: [0.2, 0.35, 0.3, 0.6, 0.55, 0.8]
  };
}
