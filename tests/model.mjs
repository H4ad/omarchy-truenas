// Runs the pure helpers in Model.js under node. Model.js has to stay loadable by
// QML as `.import "Model.js" as Model`, so it is not a module: it is read and
// evaluated here, and its top-level declarations are collected into one object.
//
//   node tests/model.mjs
//
// Prints one line per assertion, in the shape tests/lib.sh's `check` prints, and
// exits non-zero if any of them failed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
// `.pragma library` and `.import` are QML script directives, not JavaScript, so
// they have to come off before node can evaluate the file.
const source = readFileSync(join(root, "Model.js"), "utf8")
  .replace(/^\.(pragma|import)\b.*$/gm, "");

function declaredNames(text) {
  const names = [];
  const patterns = [/^function\s+([A-Za-z0-9_$]+)/gm, /^var\s+([A-Za-z0-9_$]+)\s*=/gm];
  for (const pattern of patterns) {
    let match = pattern.exec(text);
    while (match !== null) {
      names.push(match[1]);
      match = pattern.exec(text);
    }
  }
  return names;
}

const exports = declaredNames(source)
  .map(function (name) { return name + ": " + name; })
  .join(", ");
const Model = new Function(source + "\nreturn { " + exports + " };")();

let pass = 0;
let fail = 0;

function show(value) {
  return String(JSON.stringify(value));
}

function check(what, want, got) {
  if (show(want) === show(got)) {
    pass += 1;
    console.log("  ok   " + what);
    return;
  }
  fail += 1;
  console.log("  FAIL " + what);
  console.log("       want " + show(want));
  console.log("       got  " + show(got));
}

function test_case(name) {
  console.log("\n" + name);
}

function pool(name, status, usedPct) {
  return { name: name, status: status, usedPct: usedPct };
}

function alert(level, datetime, uuid) {
  return { level: level, datetime: datetime, uuid: uuid };
}

function disk(name, tempC, tempCriticalC, tempState) {
  return { name: name, tempC: tempC, tempCriticalC: tempCriticalC, tempState: tempState };
}

function service(name, state) {
  return { service: name, state: state };
}

function app(name, title, state, upgradeAvailable) {
  return { name: name, title: title, state: state, upgradeAvailable: upgradeAvailable };
}

const ok = { ok: true };

// A QVariantList reaches a plain JS function as an object with indexed members
// and a length, not as an Array.
const seqLike = { 0: { name: "boot" }, 1: { name: "storage" }, length: 2 };

test_case("arrayLike");

check("Array.isArray is false for a sequence-like", false, Array.isArray(seqLike));
check("arrayLike sees it", true, Model.arrayLike(seqLike));
check("arrayLike rejects a string", false, Model.arrayLike("abcd"));
check("arrayLike rejects null", false, Model.arrayLike(null));

test_case("poolStatusRank");

check("FAULTED is worse than DEGRADED",
  true, Model.poolStatusRank("FAULTED") < Model.poolStatusRank("DEGRADED"));
check("DEGRADED is worse than ONLINE",
  true, Model.poolStatusRank("DEGRADED") < Model.poolStatusRank("ONLINE"));
check("OFFLINE, UNAVAIL and REMOVED rank together",
  true, Model.poolStatusRank("OFFLINE") === Model.poolStatusRank("REMOVED"));
check("an unknown status is worse than DEGRADED",
  true, Model.poolStatusRank("SUSPENDED") < Model.poolStatusRank("DEGRADED"));

test_case("worstPool");

check("DEGRADED outranks ONLINE",
  "storage", Model.worstPool([pool("boot", "ONLINE", 10), pool("storage", "DEGRADED", 50)]).name);
check("FAULTED outranks DEGRADED",
  "dead", Model.worstPool([pool("dead", "FAULTED", 0), pool("storage", "DEGRADED", 50)]).name);
check("no pools is null", null, Model.worstPool([]));
check("not a list is null", null, Model.worstPool(null));

test_case("capacityPct");

check("no pools is null, not 0", null, Model.capacityPct({ pools: [] }));
check("a pool without a percentage is skipped",
  null, Model.capacityPct({ pools: [pool("storage", "ONLINE", null)] }));
check("the fullest pool wins",
  71, Model.capacityPct({ pools: [pool("boot", "ONLINE", 12), pool("storage", "ONLINE", 71)] }));
check("a real zero is a real zero",
  0, Model.capacityPct({ pools: [pool("storage", "ONLINE", 0)] }));
check("a missing state is null", null, Model.capacityPct(null));

test_case("tempStateRank");

check("critical outranks warning",
  true, Model.tempStateRank("critical") > Model.tempStateRank("warning"));
check("warning outranks ok",
  true, Model.tempStateRank("warning") > Model.tempStateRank("ok"));
check("unknown ranks below ok",
  true, Model.tempStateRank("unknown") < Model.tempStateRank("ok"));
check("a state this file does not know ranks with unknown",
  0, Model.tempStateRank("toasty"));
check("a blank state ranks with unknown", 0, Model.tempStateRank(""));
check("a missing state ranks with unknown", 0, Model.tempStateRank(null));

test_case("tempLevel");

check("critical in any row is critical", "critical",
  Model.tempLevel([disk("sda", 61, 60, "critical"), disk("sdb", 38, 60, "ok")]));
check("warning is the worst when nothing is critical", "warning",
  Model.tempLevel([disk("sda", 51, 60, "warning"), disk("sdb", 38, 60, "ok")]));
check("all ok is no level", "", Model.tempLevel([disk("sda", 38, 60, "ok")]));
check("unknown is not a level", "",
  Model.tempLevel([disk("sda", null, null, "unknown")]));
check("no rows is no level", "", Model.tempLevel([]));
check("not a list is no level", "", Model.tempLevel(null));
check("a blank is no level", "", Model.tempLevel(""));

test_case("hottestTempC");

check("the hottest known temperature wins", 42.85,
  Model.hottestTempC([disk("sda", 38, 60, "ok"), disk("nvme0n1", 42.85, 78.85, "ok")]));
check("a null temperature is skipped",
  39, Model.hottestTempC([disk("sda", null, 60, "unknown"), disk("sdb", 39, 60, "ok")]));
check("a blank temperature is skipped",
  38, Model.hottestTempC([disk("sda", "", 60, "unknown"), disk("sdb", 38, 60, "ok")]));
check("a NaN temperature is skipped",
  38, Model.hottestTempC([disk("sda", NaN, 60, "unknown"), disk("sdb", 38, 60, "ok")]));
check("no known temperature is null, never 0", null,
  Model.hottestTempC([disk("sda", null, 60, "unknown")]));
check("only blank temperatures is null, never 0", null,
  Model.hottestTempC([disk("sda", "", 60, "unknown")]));
check("a real zero is a real zero", 0,
  Model.hottestTempC([disk("sda", 0, 60, "ok")]));
check("no rows is null", null, Model.hottestTempC([]));
check("not a list is null", null, Model.hottestTempC(null));
check("a blank is null", null, Model.hottestTempC(""));

test_case("hotTempLabel");

check("a fraction rounds to whole degrees", "43\u00B0",
  Model.hotTempLabel([disk("sda", 42.85, 78.85, "ok")]));
check("a whole degree stays whole", "54\u00B0",
  Model.hotTempLabel([disk("sda", 54, 60, "warning")]));
check("no known temperature is blank", "",
  Model.hotTempLabel([disk("sda", null, 60, "unknown")]));
check("only blank temperatures is blank, never 0\u00B0", "",
  Model.hotTempLabel([disk("sda", "", 60, "unknown")]));
check("not a list is blank", "", Model.hotTempLabel(null));
check("a blank is blank", "", Model.hotTempLabel(""));

test_case("formatTemp");

check("a whole degree", "38 \u00B0C", Model.formatTemp(38.0));
check("a fraction rounds to a whole degree", "43 \u00B0C", Model.formatTemp(42.85));
check("null is unknown", "", Model.formatTemp(null));
check("undefined is unknown", "", Model.formatTemp(undefined));
check("a blank is unknown", "", Model.formatTemp(""));
check("NaN is unknown", "", Model.formatTemp(NaN));
check("Infinity is unknown", "", Model.formatTemp(Infinity));

test_case("tempThresholdText");

check("names the critical threshold", "critical at 60 \u00B0C",
  Model.tempThresholdText({ tempCriticalC: 60 }));
check("no threshold is blank", "", Model.tempThresholdText({ tempCriticalC: null }));
check("a missing field is blank", "", Model.tempThresholdText({}));
check("no disk is blank", "", Model.tempThresholdText(null));
check("a blank disk is blank", "", Model.tempThresholdText(""));

test_case("serviceStateRank");

check("RUNNING is healthy", 0, Model.serviceStateRank("RUNNING"));
check("the state is case-insensitive", 0, Model.serviceStateRank("running"));
check("a stopped service is down", 1, Model.serviceStateRank("STOPPED"));
check("an unknown service state is down", 1, Model.serviceStateRank("SOMETHING"));
check("a blank state is unknown, not down", 2, Model.serviceStateRank(""));
check("a missing state is unknown, not down", 2, Model.serviceStateRank(null));

test_case("appStateRank");

check("RUNNING is healthy", 0, Model.appStateRank("RUNNING"));
check("the state is case-insensitive", 0, Model.appStateRank("running"));
check("a crashed app is down", 1, Model.appStateRank("CRASHED"));
check("a failed app is down", 1, Model.appStateRank("FAILED"));
check("DEPLOYING is transitional, not down", 2, Model.appStateRank("DEPLOYING"));
check("STARTING is transitional, not down", 2, Model.appStateRank("STARTING"));
check("STOPPING is transitional, not down", 2, Model.appStateRank("STOPPING"));
check("a blank state is unknown, not down", 2, Model.appStateRank(""));
check("a missing state is unknown, not down", 2, Model.appStateRank(null));

test_case("worstServiceLevel");

check("a down service warns", "warning",
  Model.worstServiceLevel([service("cifs", "RUNNING"), service("ups", "STOPPED")]));
check("a warning outranks an unknown", "warning",
  Model.worstServiceLevel([service("ups", "STOPPED"), service("cifs", "")]));
check("blank states are unknown, not a warning", "unknown",
  Model.worstServiceLevel([service("cifs", "RUNNING"), service("ups", "")]));
check("all running is no level", "",
  Model.worstServiceLevel([service("cifs", "RUNNING")]));
check("a row without a state is unknown, never a warning", "unknown",
  Model.worstServiceLevel([{}]));
check("no rows is no level", "", Model.worstServiceLevel([]));
check("not a list is no level", "", Model.worstServiceLevel(null));
check("a blank is no level", "", Model.worstServiceLevel(""));

test_case("worstAppLevel");

check("a crashed app warns", "warning",
  Model.worstAppLevel([app("appc", "appc", "RUNNING"), app("appb", "appb", "CRASHED")]));
check("a warning outranks an unknown", "warning",
  Model.worstAppLevel([app("appb", "appb", "FAILED"), app("appc", "appc", "DEPLOYING")]));
check("a transitional state is unknown, not a warning", "unknown",
  Model.worstAppLevel([app("appc", "appc", "RUNNING"), app("appb", "appb", "DEPLOYING")]));
check("all running is no level", "",
  Model.worstAppLevel([app("appc", "appc", "RUNNING")]));
check("a row without a state is unknown, never a warning", "unknown",
  Model.worstAppLevel([{}]));
check("no rows is no level", "", Model.worstAppLevel([]));
check("not a list is no level", "", Model.worstAppLevel(null));
check("a blank is no level", "", Model.worstAppLevel(""));

test_case("downServices");

check("only down rows are copied", ["ups"],
  Model.downServices([service("cifs", "RUNNING"), service("ups", "STOPPED")])
    .map(function (s) { return s.service; }));
check("input order survives", ["ftp", "ups"],
  Model.downServices([service("ftp", "STOPPED"), service("cifs", "RUNNING"), service("ups", "STOPPED")])
    .map(function (s) { return s.service; }));
const serviceRows = [service("cifs", "RUNNING"), service("ups", "STOPPED")];
check("the result is a copy, not the input", false, Model.downServices(serviceRows) === serviceRows);
check("the input is untouched", 2, serviceRows.length);
check("a blank state is unknown, not down", 0,
  Model.downServices([service("cifs", "")]).length);
check("blind rows are skipped, not down", 0,
  Model.downServices([{}, null, undefined, 4]).length);
check("not a list is an empty list", [], Model.downServices(null));
check("a blank is an empty list", [], Model.downServices(""));

test_case("downApps");

check("only down rows are copied", ["appb"],
  Model.downApps([app("appc", "appc", "RUNNING"), app("appb", "appb", "CRASHED")])
    .map(function (a) { return a.name; }));
check("input order survives", ["alpha", "appb"],
  Model.downApps([app("alpha", "Alpha", "FAILED"), app("appc", "appc", "RUNNING"), app("appb", "appb", "EXITED")])
    .map(function (a) { return a.name; }));
const appRows = [app("appc", "appc", "RUNNING"), app("appb", "appb", "CRASHED")];
check("the result is a copy, not the input", false, Model.downApps(appRows) === appRows);
check("the input is untouched", 2, appRows.length);
check("a transitional state is not down", 0,
  Model.downApps([app("appb", "appb", "DEPLOYING")]).length);
check("a blank state is unknown, not down", 0,
  Model.downApps([app("appb", "appb", "")]).length);
check("blind rows are skipped, not down", 0,
  Model.downApps([{}, null, undefined, 4]).length);
check("not a list is an empty list", [], Model.downApps(null));
check("a blank is an empty list", [], Model.downApps(""));

test_case("appsUpgradeable");

check("counts only true flags", 1,
  Model.appsUpgradeable([app("appc", "appc", "RUNNING", true), app("appb", "appb", "RUNNING", false)]));
check("a missing flag is not true", 0,
  Model.appsUpgradeable([app("appb", "appb", "RUNNING")]));
check("blind rows never count", 0, Model.appsUpgradeable([{}, null, 4]));
check("an empty list is zero", 0, Model.appsUpgradeable([]));
check("a non-list is zero", 0, Model.appsUpgradeable(null));
check("a blank is zero", 0, Model.appsUpgradeable(""));

test_case("appLabel");

check("the title wins", "appc", Model.appLabel(app("appc", "appc", "RUNNING")));
check("the name is the fallback", "appc", Model.appLabel(app("appc", "", "RUNNING")));
check("a blank title falls through to the name", "appc",
  Model.appLabel({ name: "appc", title: "" }));
check("a title with no name still wins", "appc",
  Model.appLabel({ title: "appc" }));
check("no title and no name is blank", "", Model.appLabel({}));
check("undefined fields are blank, never the word undefined", "",
  Model.appLabel({ name: undefined, title: undefined }));
check("no app is blank", "", Model.appLabel(null));
check("a blank app is blank", "", Model.appLabel(""));

test_case("mode");

check("unconfigured when there is no schema", "unconfigured", Model.mode({ connection: ok }));
check("offline when the connection is not ok, even with alerts", "offline",
  Model.mode({ schema: 1, connection: { ok: false, error: "unreachable" },
    counts: { total: 3 }, alerts: [alert("critical", "2026-01-01T00:00:00Z", "x")] }));
check("firing when alerts are present", "firing",
  Model.mode({ schema: 1, connection: ok, counts: { warning: 2, total: 2 },
    alerts: [alert("warning", "2026-01-01T00:00:00Z", "w")], pools: [pool("storage", "ONLINE", 20)] }));
check("quiet when nothing is wrong", "quiet",
  Model.mode({ schema: 1, connection: ok, counts: { total: 0 }, alerts: [],
    pools: [pool("storage", "ONLINE", 20)] }));
check("degraded when a pool is OFFLINE", "degraded",
  Model.mode({ schema: 1, connection: ok, counts: { total: 0 }, alerts: [],
    pools: [pool("storage", "OFFLINE", 0)] }));
check("degraded when an alert is an error", "degraded",
  Model.mode({ schema: 1, connection: ok, counts: { error: 1, total: 1 },
    alerts: [alert("error", "2026-01-01T00:00:00Z", "e")], pools: [pool("storage", "ONLINE", 20)] }));

test_case("worstLevel");

check("critical outranks error", "critical", Model.worstLevel({ critical: 1, error: 1, warning: 2 }));
check("nothing firing is an empty string", "",
  Model.worstLevel({ critical: 0, error: 0, warning: 0, notice: 0, info: 0 }));
check("worstSeverity agrees", "warning", Model.worstSeverity({ critical: 0, error: 0, warning: 1 }));

test_case("alertRows");

const before = [
  alert("warning", "2026-01-02T00:00:00Z", "w1"),
  alert("critical", "2026-01-03T00:00:00Z", "c1"),
  alert("warning", "2026-01-01T00:00:00Z", "w0")
];
const rows = Model.alertRows(before);
check("critical sorts before warning", "c1", rows[0].uuid);
check("older comes first within one level", "w0", rows[1].uuid);
check("the input keeps its order", ["w1", "c1", "w0"], before.map(function (a) { return a.uuid; }));
check("not a list is an empty list", [], Model.alertRows(null));

test_case("byLevel");

check("counts by bucket", { critical: 1, error: 0, warning: 2, notice: 0, info: 1, total: 4 },
  Model.byLevel([alert("critical", "", "c"), alert("warning", "", "w1"),
    alert("warning", "", "w2"), alert("info", "", "i")]));

test_case("formatBytes");

check("null is unknown", "", Model.formatBytes(null));
check("undefined is unknown", "", Model.formatBytes(undefined));
check("negative is unknown", "", Model.formatBytes(-1));
check("NaN is unknown", "", Model.formatBytes(NaN));
check("zero is a real zero", "0 B", Model.formatBytes(0));
check("one TiB", "1 TiB", Model.formatBytes(1099511627776));
check("one GiB", "1 GiB", Model.formatBytes(1073741824));
check("exactly half a MiB in KiB", "512 KiB", Model.formatBytes(524288));

test_case("errorSentence");

check("unauthenticated names the key", "the API key was rejected", Model.errorSentence({ error: "unauthenticated" }));
check("timeout is not the same sentence",
  true, Model.errorSentence({ error: "timeout" }) !== Model.errorSentence({ error: "unauthenticated" }));
check("not_found names the path", "the API path was not found", Model.errorSentence({ error: "not_found" }));
check("an http code is named", "the NAS answered HTTP 400", Model.errorSentence({ error: "http_400" }));
check("an unknown code falls back to its message", "boom", Model.errorSentence({ error: "weird", message: "boom" }));
check("no error is an empty sentence", "", Model.errorSentence({}));

test_case("glyphFor");

check("offline is not the quiet glyph", true, Model.glyphFor("offline") !== Model.glyphFor("quiet"));
check("unconfigured is not the quiet glyph", true, Model.glyphFor("unconfigured") !== Model.glyphFor("quiet"));
check("quiet and firing share the bell", Model.glyphFor("quiet"), Model.glyphFor("firing", { total: 0 }));

test_case("ageText and durationText");

check("seconds", "30s", Model.ageText(30));
check("minutes", "5m", Model.ageText(300));
check("never", "never", Model.ageText(-1));
const noon = Date.parse("2026-01-01T12:00:00Z");
check("an hour and twelve minutes", "1h12m", Model.durationText("2026-01-01T10:48:00Z", noon));
check("a missing start is blank", "", Model.durationText(null, noon));

test_case("tooltipFor");

check("unconfigured points at login", "TrueNAS: run truenasctl login <url>", Model.tooltipFor({}, "unconfigured"));

console.log("\nmodel: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
