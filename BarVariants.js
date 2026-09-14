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

var VARIANTS = ["Default", "Icon", "Alerts", "Capacity", "Pool", "Temp", "Full"];
var DEFAULT_VARIANT = "Default";
var SEPARATOR = "·";

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
    default:
      return defaultSegments(view);
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
