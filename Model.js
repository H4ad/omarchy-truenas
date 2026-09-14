.pragma library

// Pure helpers for the TrueNAS widget and panel. No QML types in here, so every
// rule about what the bar says lives in one readable place, and every rule can be
// exercised under node.
//
// `.pragma library` is load-bearing, not decoration. Without it every QML file
// that imports this script gets its own private copy of it. With it there is one
// shared copy per engine. Nothing in here may touch QML: a library script has no
// component context, no ids, no signals.

// Buckets share/normalize.jq writes. Worst first, which is the order every
// comparison in here relies on.
var SEVERITY_ORDER = ["critical", "error", "warning", "notice", "info"];

// Worst state first. The glyph is only ever compared for equality, never rendered
// from this file, so the codepoints are free to change with the bar's font.
var GLYPH = {
  quiet:        "\uF0F3", // bell
  firing:       "\uF0F3", // bell
  critical:     "\uF071", // warning triangle
  degraded:     "\uF06A", // exclamation circle
  offline:      "\uF1E6", // plug
  unconfigured: "\uF013", // cog
  ok:           "\uF00C", // check
  refresh:      "\uF021",
  link:         "\uF08E",
  search:       "\uF002"
};

// Array.isArray is false for a QVariantList sequence wrapper, which is what a
// QML property holding a list can hand to a plain JS function. Every use below
// guards data whose absence would be rendered as an answer: a list that fails
// this test produces counts of zero, and "nothing is firing" must never be how
// "I could not tell" looks.
function arrayLike(value) {
  return !!value && typeof value !== "string" && typeof value.length === "number";
}

function severityRank(severity) {
  var index = SEVERITY_ORDER.indexOf(String(severity || ""));
  return index === -1 ? SEVERITY_ORDER.length : index;
}

// The worst bucket with a positive count, or "" when nothing is firing. Counts
// that are missing are read as zero because the poller writes every key; a
// caller that hands a partial object gets the fields it named.
function worstLevel(counts) {
  if (!counts) return "";
  for (var i = 0; i < SEVERITY_ORDER.length; i++) {
    if ((counts[SEVERITY_ORDER[i]] || 0) > 0) return SEVERITY_ORDER[i];
  }
  return "";
}

// The same question under the name the SigNoz reference uses, so the two repos
// read the same. Kept as one implementation, not two.
function worstSeverity(counts) {
  return worstLevel(counts);
}

// One pool status per level, worst first. Unknown statuses deliberately rank
// WORST, ahead of FAULTED: a status this file does not recognise is a state the
// plugin cannot vouch for, and "I cannot tell" must never sort below a known
// good pool. That also means an unknown-status pool can be chosen as the worst
// pool over a FAULTED one, which is the safe direction: the view prints the
// status word, so the odd one out becomes visible instead of buried.
var POOL_RANK = {
  "FAULTED": 0,
  "UNAVAIL": 1,
  "OFFLINE": 1,
  "REMOVED": 1,
  "DEGRADED": 2,
  "ONLINE": 3
};

function poolStatusRank(status) {
  var key = String(status || "").toUpperCase();
  if (Object.prototype.hasOwnProperty.call(POOL_RANK, key)) return POOL_RANK[key];
  return -1;
}

// The single worst pool, or null when there is none. Ties go to the first pool
// in the list, so the answer is stable across polls that did not reorder them.
function worstPool(pools) {
  var list = arrayLike(pools) ? pools : [];
  var worst = null;
  var worstRank = Infinity;
  for (var i = 0; i < list.length; i++) {
    var rank = poolStatusRank(list[i] && list[i].status);
    if (rank < worstRank) {
      worstRank = rank;
      worst = list[i];
    }
  }
  return worst;
}

// The fullest pool's used percentage, or null when there are no pools or none of
// them report a percentage. Never 0 for "unknown": a zero here is a real empty
// pool, which is a different fact from a pool size the poller could not compute.
function capacityPct(state) {
  var pools = arrayLike(state && state.pools) ? state.pools : [];
  var best = null;
  for (var i = 0; i < pools.length; i++) {
    var value = pools[i] && pools[i].usedPct;
    if (value === null || value === undefined || value === "") continue;
    var number = Number(value);
    if (!isFinite(number)) continue;
    if (best === null || number > best) best = number;
  }
  return best;
}

// Temperature states, worst first. A state this file does not recognise ranks
// with `unknown` at the bottom: "I cannot tell" must never sort above a known
// ok. The states are share/normalize.jq's, which computes them once for both
// the notifier and the views.
var TEMP_STATE_RANK = {
  "critical": 3,
  "warning": 2,
  "ok": 1
};

function tempStateRank(state) {
  var key = String(state || "");
  if (Object.prototype.hasOwnProperty.call(TEMP_STATE_RANK, key)) return TEMP_STATE_RANK[key];
  return 0;
}

// The worst temperature state across the rows, or "" when nothing is hot.
// Unknown and missing states answer "" rather than a word: the bar tints from
// this, and unknown must not look like a level of heat.
function tempLevel(disks) {
  var list = arrayLike(disks) ? disks : [];
  var warning = false;
  for (var i = 0; i < list.length; i++) {
    var rank = tempStateRank(list[i] && list[i].tempState);
    if (rank === TEMP_STATE_RANK.critical) return "critical";
    if (rank === TEMP_STATE_RANK.warning) warning = true;
  }
  return warning ? "warning" : "";
}

// The hottest temperature any row reports, or null when none does. Null, blank
// and non-finite values are not temperatures and are skipped. Absence is null,
// never 0: 0 °C is a real reading (a disk in a cold room), a different fact
// from a disk that did not answer.
function hottestTempC(disks) {
  var list = arrayLike(disks) ? disks : [];
  var best = null;
  for (var i = 0; i < list.length; i++) {
    var value = list[i] && list[i].tempC;
    if (value === null || value === undefined || value === "") continue;
    var number = Number(value);
    if (!isFinite(number)) continue;
    if (best === null || number > best) best = number;
  }
  return best;
}

// The bar label for the hottest disk: whole degrees and a degree sign, or ""
// when no row reports a temperature. Rounded because a fraction of a degree is
// noise on a bar, and blank rather than "0°" so absence stays visible.
function hotTempLabel(disks) {
  var hottest = hottestTempC(disks);
  return hottest === null ? "" : Math.round(hottest) + "\u00B0";
}

// "38 °C" for a card header or a CLI column, "" for null, blank and
// non-finite. Whole degrees on purpose, so the card and the bar's tempText
// cannot disagree about what the same reading is.
function formatTemp(value) {
  if (value === null || value === undefined || value === "") return "";
  var number = Number(value);
  if (!isFinite(number)) return "";
  return Math.round(number) + " \u00B0C";
}

// The threshold line under a disk, "" when the threshold is unknown. Goes
// through formatTemp so its unit and rounding match the temperature it
// belongs to.
function tempThresholdText(disk) {
  var text = formatTemp(disk && disk.tempCriticalC);
  return text === "" ? "" : "critical at " + text;
}

// Service state ranks. 0 is healthy, 1 is down (the worst), 2 is unknown. The
// scale is deliberately not monotonic: a blank state ranks above a down one
// because "I cannot tell" must not read as a stopped service. Case-insensitive
// because the wire says RUNNING today and the plugin must not break if it says
// Running. A state absent from the table is a real, named problem and ranks 1.
var SERVICE_STATE_RANK = {
  "RUNNING": 0,
  "": 2
};

function serviceStateRank(state) {
  var key = String(state || "").toUpperCase();
  if (Object.prototype.hasOwnProperty.call(SERVICE_STATE_RANK, key)) return SERVICE_STATE_RANK[key];
  return 1;
}

// App state ranks. 0 is healthy, 1 is down (the worst), 2 is unknown.
// DEPLOYING, STARTING and STOPPING are transitional, like blank, and must never
// look like a down app: the poller reads the NAS back and the next poll catches
// up. A state absent from the table is down and ranks 1.
var APP_STATE_RANK = {
  "RUNNING": 0,
  "": 2,
  "DEPLOYING": 2,
  "STARTING": 2,
  "STOPPING": 2
};

function appStateRank(state) {
  var key = String(state || "").toUpperCase();
  if (Object.prototype.hasOwnProperty.call(APP_STATE_RANK, key)) return APP_STATE_RANK[key];
  return 1;
}

// The worst service level across the rows: "warning" if anything is down,
// "unknown" only when a row is blank and nothing is down, "" when all running.
// A blank state is never a warning, and missing rows answer "".
function worstServiceLevel(services) {
  var list = arrayLike(services) ? services : [];
  var unknown = false;
  for (var i = 0; i < list.length; i++) {
    var rank = serviceStateRank(list[i] && list[i].state);
    if (rank === 1) return "warning";
    if (rank === 2) unknown = true;
  }
  return unknown ? "unknown" : "";
}

// The same rule for apps, with the transitional states ranking as unknown.
function worstAppLevel(apps) {
  var list = arrayLike(apps) ? apps : [];
  var unknown = false;
  for (var i = 0; i < list.length; i++) {
    var rank = appStateRank(list[i] && list[i].state);
    if (rank === 1) return "warning";
    if (rank === 2) unknown = true;
  }
  return unknown ? "unknown" : "";
}

// The down services, in input order, as a new list. A blank-state row is
// unknown, not down, so it never appears here.
function downServices(services) {
  var list = arrayLike(services) ? services : [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    if (serviceStateRank(list[i] && list[i].state) === 1) out.push(list[i]);
  }
  return out;
}

// The same for apps: only the real down states, transitional ones excluded.
function downApps(apps) {
  var list = arrayLike(apps) ? apps : [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    if (appStateRank(list[i] && list[i].state) === 1) out.push(list[i]);
  }
  return out;
}

// How many rows carry an update. A non-list counts zero because the caller
// asked how many of these rows need one and there are no rows; a row whose flag
// is missing or not exactly true is not counted.
function appsUpgradeable(apps) {
  var list = arrayLike(apps) ? apps : [];
  var count = 0;
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].upgradeAvailable === true) count += 1;
  }
  return count;
}

// The label for an app card: the title when it has one, else the name, else "".
// Never "undefined": a row missing both fields reads as blank, not the word.
function appLabel(app) {
  var title = app && app.title;
  if (title !== null && title !== undefined && String(title) !== "") return String(title);
  var name = app && app.name;
  if (name !== null && name !== undefined && String(name) !== "") return String(name);
  return "";
}

function hasAlerts(state) {
  var counts = state && state.counts;
  if (counts && typeof counts.total === "number") return counts.total > 0;
  var alerts = arrayLike(state && state.alerts) ? state.alerts : [];
  return alerts.length > 0;
}

// An alert the bar must not stay quiet about. Counts are preferred because
// normalize.jq computes them from the non-dismissed alerts; the alerts array is
// the fallback for a state written before the counts were.
function hasSevereAlert(state) {
  var counts = state && state.counts;
  if (counts) {
    return (counts.critical || 0) > 0 || (counts.error || 0) > 0;
  }
  var alerts = arrayLike(state && state.alerts) ? state.alerts : [];
  for (var i = 0; i < alerts.length; i++) {
    if (severityRank(alerts[i] && alerts[i].level) <= severityRank("error")) return true;
  }
  return false;
}

// Any pool that is not ONLINE, including one whose status is missing: a pool the
// state list names but cannot vouch for is not healthy.
function hasBadPool(state) {
  var pools = arrayLike(state && state.pools) ? state.pools : [];
  for (var i = 0; i < pools.length; i++) {
    if (String(pools[i] && pools[i].status || "").toUpperCase() !== "ONLINE") return true;
  }
  return false;
}

// One word the widget picks its glyph, tint and badge from. Precedence, worst
// first: unconfigured, offline, degraded, firing, quiet.
//
//   unconfigured  no schema in the state file: nothing has been set up
//   offline       the connection is not ok, whatever the last counts said
//   degraded      a pool is not ONLINE, or an alert sits at error/critical
//   firing        alerts are present below error/critical
//   quiet         connected, pools ONLINE, nothing firing
//
// `partial` is a property of `warnings`, not a mode: a failed slow endpoint does
// not change what the bar is, it only changes what the panel can show.
function mode(state) {
  if (!state || !state.schema) return "unconfigured";
  if (!(state.connection && state.connection.ok)) return "offline";
  if (hasSevereAlert(state) || hasBadPool(state)) return "degraded";
  if (hasAlerts(state)) return "firing";
  return "quiet";
}

// Alerts worst level first, then oldest datetime first. A copy, so a view can
// sort or slice freely without disturbing the state object another binding reads.
function alertRows(alerts) {
  var list = arrayLike(alerts) ? alerts.slice() : [];
  return list.sort(function (a, b) {
    var byLevel = severityRank(a && a.level) - severityRank(b && b.level);
    if (byLevel !== 0) return byLevel;
    return String(a && a.datetime || "").localeCompare(String(b && b.datetime || ""));
  });
}

// Counts per bucket, in the fixed order the state file uses, so a caller can
// render a legend without reaching into SEVERITY_ORDER.
function byLevel(alerts) {
  var list = arrayLike(alerts) ? alerts : [];
  var counts = { critical: 0, error: 0, warning: 0, notice: 0, info: 0, total: 0 };
  for (var i = 0; i < list.length; i++) {
    var level = String(list[i] && list[i].level || "");
    if (SEVERITY_ORDER.indexOf(level) !== -1) counts[level] += 1;
    counts.total += 1;
  }
  return counts;
}

function ageSeconds(updatedAt, nowMs) {
  if (!updatedAt) return -1;
  var then = Date.parse(updatedAt);
  if (isNaN(then)) return -1;
  return Math.max(0, Math.round(((nowMs || Date.now()) - then) / 1000));
}

function ageText(seconds) {
  if (seconds < 0) return "never";
  if (seconds < 60) return seconds + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h";
  return Math.floor(seconds / 86400) + "d";
}

// Coarse on purpose. Seconds on a bar are noise, and "1h12m" is the answer to
// how long something has been broken.
function durationText(startsAt, nowMs) {
  if (!startsAt) return "";
  var start = Date.parse(startsAt);
  if (isNaN(start)) return "";
  var seconds = Math.max(0, Math.round(((nowMs || Date.now()) - start) / 1000));
  if (seconds < 60) return "<1m";
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m";
  var hours = Math.floor(minutes / 60);
  if (hours < 24) {
    var rest = minutes % 60;
    return rest === 0 ? hours + "h" : hours + "h" + rest + "m";
  }
  return Math.floor(hours / 24) + "d";
}

// "2 critical, 1 warning" for a tooltip or a summary row. Nothing firing is the
// empty string, so a caller can test for it rather than print "0".
function countPhrase(counts) {
  var parts = [];
  for (var i = 0; i < SEVERITY_ORDER.length; i++) {
    var key = SEVERITY_ORDER[i];
    if ((counts && (counts[key] || 0)) > 0) parts.push(counts[key] + " " + key);
  }
  return parts.join(", ");
}

// Exact binary units. `n` is bytes; the result is TiB/GiB/MiB-shaped because
// pools and memory are binary quantities and a decimal "TB" would overstate them.
// Zero is a real zero (an empty pool, an empty counter) and prints "0 B"; null,
// negative and non-finite are unknown and print "", never "0 B". One fractional
// digit is enough for a capacity label, and a whole value drops it.
var BYTE_UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];

function formatBytes(n) {
  if (n === null || n === undefined || n === "") return "";
  var value = Number(n);
  if (!isFinite(value) || value < 0) return "";
  if (value === 0) return "0 B";
  var unit = 0;
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  var text = value.toFixed(unit === 0 ? 0 : 1).replace(/\.0$/, "");
  return text + " " + BYTE_UNITS[unit];
}

// Every failure gets its own sentence, because the fix is different for each and
// a widget that says "error" says nothing. `connection` is the state.json
// connection object; the code list matches what tn_classify and tn_resolve_key
// emit in bin/truenas-lib.sh.
function errorSentence(connection) {
  var c = connection || {};
  var message = c.message || "";
  var error = String(c.error || "");
  if (error.indexOf("http_") === 0) return "the NAS answered HTTP " + error.slice(5);
  switch (error) {
    case "unconfigured":            return "not configured yet";
    case "config_not_json":         return "the config file is not valid JSON";
    case "no_key":                  return "no API key found";
    case "key_command_failed":      return "the key command failed";
    case "credentials_permissions": return "the credentials file is readable by others";
    case "unauthenticated":         return "the API key was rejected";
    case "forbidden":               return message || "this key has no permission";
    case "not_found":               return "the API path was not found";
    case "not_json":                return "the response was not JSON, check the base URL";
    case "timeout":                 return "timed out";
    case "unreachable":             return message || "unreachable";
    case "server_error":            return "the NAS returned a server error";
    default:                        return error ? (message || error) : "";
  }
}

// The line under the bar glyph. `mode` is what Model.mode returned, so the
// tooltip and the glyph never disagree about what the state is.
function tooltipFor(state, mode) {
  var connection = (state && state.connection) || {};
  var counts = (state && state.counts) || {};
  switch (mode) {
    case "unconfigured":
      return "TrueNAS: run truenasctl login <url>";
    case "offline":
      return "TrueNAS unreachable: " + errorSentence(connection) +
             (connection.lastOkAt
               ? " (last ok " + ageText(ageSeconds(connection.lastOkAt)) + " ago)"
               : "");
    case "degraded": {
      var pool = worstPool(state && state.pools);
      if (pool) return "TrueNAS: pool " + String(pool.name || "") + " is " + String(pool.status || "unknown");
      return "TrueNAS: " + (countPhrase(counts) || "degraded");
    }
    case "firing":
      return "TrueNAS: " + countPhrase(counts);
    default:
      return "TrueNAS: nothing firing (checked " + ageText(ageSeconds(state && state.updatedAt)) + " ago)";
  }
}

function glyphFor(mode, counts) {
  var severe = !!(counts && ((counts.critical || 0) > 0 || (counts.error || 0) > 0));
  switch (mode) {
    case "unconfigured": return GLYPH.unconfigured;
    case "offline":      return GLYPH.offline;
    case "degraded":     return severe ? GLYPH.critical : GLYPH.degraded;
    default:             return severe ? GLYPH.critical : GLYPH.firing;
  }
}
