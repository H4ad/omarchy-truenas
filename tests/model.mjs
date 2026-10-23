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

function replication(name, jobState, warnCount) {
  var warnings = [];
  for (var i = 0; i < (warnCount || 0); i++) warnings.push("w");
  return { name: name,
           job: jobState === null ? null : { state: jobState },
           state: { state: "FINISHED", warnings: warnings } };
}

function cloudSync(name, jobState) {
  return { name: name, job: jobState === null ? null : { state: jobState } };
}

function iface(name, linkState, mediaType, mediaSubtype, addresses) {
  return { name: name, linkState: linkState, mediaType: mediaType,
           mediaSubtype: mediaSubtype, addresses: addresses || [] };
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
check("a stopped app is down", 1, Model.appStateRank("STOPPED"));
check("a crashed app is down", 1, Model.appStateRank("CRASHED"));
check("a failed app is down", 1, Model.appStateRank("FAILED"));
check("an exited app is down", 1, Model.appStateRank("EXITED"));
check("DEPLOYING is transitional, not down", 2, Model.appStateRank("DEPLOYING"));
check("STARTING is transitional, not down", 2, Model.appStateRank("STARTING"));
check("STOPPING is transitional, not down", 2, Model.appStateRank("STOPPING"));
check("a blank state is unknown, not down", 2, Model.appStateRank(""));
check("a missing state is unknown, not down", 2, Model.appStateRank(null));

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

test_case("unknownServices");

check("only rank-2 rows are copied", ["ups"],
  Model.unknownServices([service("cifs", "RUNNING"), service("ups", "")])
    .map(function (s) { return s.service; }));
check("input order survives", ["ftp", "ups"],
  Model.unknownServices([service("ftp", ""), service("cifs", "RUNNING"), service("ups", "")])
    .map(function (s) { return s.service; }));
const unknownServiceRows = [service("cifs", "RUNNING"), service("ups", "")];
check("the result is a copy, not the input", false,
  Model.unknownServices(unknownServiceRows) === unknownServiceRows);
check("the input is untouched", 2, unknownServiceRows.length);
check("a down state is not unknown", 0,
  Model.unknownServices([service("ups", "STOPPED")]).length);
check("a row without a state is unknown, like the rank says", 1,
  Model.unknownServices([{}]).length);
check("not a list is an empty list", [], Model.unknownServices(null));
check("a blank is an empty list", [], Model.unknownServices(""));

test_case("unknownApps");

check("only rank-2 rows are copied", ["appb"],
  Model.unknownApps([app("appc", "appc", "RUNNING"), app("appb", "appb", "DEPLOYING")])
    .map(function (a) { return a.name; }));
check("a blank state is unknown", ["appa"],
  Model.unknownApps([app("appa", "appa", "")])
    .map(function (a) { return a.name; }));
const unknownAppRows = [app("appc", "appc", "RUNNING"), app("appb", "appb", "STARTING")];
check("the result is a copy, not the input", false,
  Model.unknownApps(unknownAppRows) === unknownAppRows);
check("the input is untouched", 2, unknownAppRows.length);
check("a down state is not unknown", 0,
  Model.unknownApps([app("appb", "appb", "CRASHED")]).length);
check("a row without a state is unknown, like the rank says", 1,
  Model.unknownApps([{}]).length);
check("not a list is an empty list", [], Model.unknownApps(null));
check("a blank is an empty list", [], Model.unknownApps(""));

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

test_case("protectionStateRank");

check("SUCCESS is healthy", 0, Model.protectionStateRank("SUCCESS"));
check("FINISHED is healthy", 0, Model.protectionStateRank("FINISHED"));
check("the state is case-insensitive", 0, Model.protectionStateRank("success"));
check("FAILED is a failure", 1, Model.protectionStateRank("FAILED"));
check("ERROR is a failure", 1, Model.protectionStateRank("ERROR"));
check("ABORTED is a failure", 1, Model.protectionStateRank("ABORTED"));
check("PENDING is unknown, not a failure", 2, Model.protectionStateRank("PENDING"));
check("a blank state is unknown", 2, Model.protectionStateRank(""));
check("a missing state is unknown", 2, Model.protectionStateRank(null));
check("an unknown word is unknown, not a failure", 2, Model.protectionStateRank("RUNNING"));

test_case("protectionState");

check("the job state wins", "SUCCESS",
  Model.protectionState({ job: { state: "SUCCESS" }, state: { state: "FINISHED" } }));
check("the task state is the fallback when there is no job", "FINISHED",
  Model.protectionState({ job: null, state: { state: "FINISHED" } }));
check("a job with no state falls back to the task", "PENDING",
  Model.protectionState({ job: {}, state: { state: "PENDING" } }));
check("an empty row is blank", "", Model.protectionState({}));
check("no row is blank", "", Model.protectionState(null));

test_case("replicationFailed");

check("a failed job is a failure", true,
  Model.replicationFailed(replication("a", "FAILED", 0)));
check("a successful job with no warnings is not", false,
  Model.replicationFailed(replication("a", "SUCCESS", 0)));
check("warnings on a successful job are a failure", true,
  Model.replicationFailed(replication("a", "SUCCESS", 2)));
check("a jobless task with no warnings is not", false,
  Model.replicationFailed(replication("a", null, 0)));
check("a jobless task with warnings is", true,
  Model.replicationFailed(replication("a", null, 1)));
check("a blind row is not a failure", false, Model.replicationFailed({}));
check("no row is not a failure", false, Model.replicationFailed(null));

test_case("cloudSyncFailed");

check("a failed job is a failure", true,
  Model.cloudSyncFailed(cloudSync("a", "FAILED")));
check("a successful job is not", false,
  Model.cloudSyncFailed(cloudSync("a", "SUCCESS")));
check("a running job is not a failure", false,
  Model.cloudSyncFailed(cloudSync("a", "RUNNING")));
check("a jobless task is not", false, Model.cloudSyncFailed(cloudSync("a", null)));
check("a blind row is not", false, Model.cloudSyncFailed({}));
check("no row is not", false, Model.cloudSyncFailed(null));

test_case("failedReplications and failedCloudSync");

check("only failed rows are copied", ["b"],
  Model.failedReplications([replication("a", "SUCCESS", 0), replication("b", "FAILED", 0)])
    .map(function (r) { return r.name; }));
check("input order survives", ["a", "b"],
  Model.failedReplications([replication("a", "ERROR", 0), replication("b", "ABORTED", 0)])
    .map(function (r) { return r.name; }));
const repRows = [replication("a", "FAILED", 0)];
check("the result is a copy, not the input", false,
  Model.failedReplications(repRows) === repRows);
check("the input is untouched", 1, repRows.length);
check("not a list is an empty list", [], Model.failedReplications(null));
check("a blank is an empty list", [], Model.failedReplications(""));
check("blind rows are skipped", 0, Model.failedReplications([{}, null, 4]).length);
check("cloud sync only failed rows", ["c"],
  Model.failedCloudSync([cloudSync("c", "FAILED"), cloudSync("d", "SUCCESS")])
    .map(function (r) { return r.name; }));
const csRows = [cloudSync("c", "FAILED")];
check("the cloud sync result is a copy", false, Model.failedCloudSync(csRows) === csRows);
check("not a list is an empty list for cloud sync", [], Model.failedCloudSync(null));

test_case("protectionLabel");

check("the name wins", "storage-to-backup",
  Model.protectionLabel({ name: "storage-to-backup", dataset: "storage", pool: "storage" }));
check("the dataset is the fallback", "Backup",
  Model.protectionLabel({ name: "", dataset: "Backup", pool: "Backup" }));
check("the pool is the last fallback", "storage",
  Model.protectionLabel({ name: "", dataset: "", pool: "storage" }));
check("an empty row is blank", "", Model.protectionLabel({}));
check("undefined fields are blank, never the word undefined", "",
  Model.protectionLabel({ name: undefined, dataset: undefined, pool: undefined }));
check("no row is blank", "", Model.protectionLabel(null));

test_case("scheduleText");

check("a scrub schedule is dow hour minute", "7 00 00",
  Model.scheduleText({ minute: "00", hour: "00", dow: "7" }));
check("a replication schedule keeps its fields", "* 3 0",
  Model.scheduleText({ minute: "0", hour: "3", dow: "*" }));
check("a missing field is skipped", "3 0",
  Model.scheduleText({ minute: "0", hour: "3" }));
check("a null schedule is blank", "", Model.scheduleText(null));
check("an empty object is blank", "", Model.scheduleText({}));
check("a non-object is blank", "", Model.scheduleText("daily"));

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

test_case("linkStateRank");

check("up ranks best", 0, Model.linkStateRank("LINK_STATE_UP"));
check("down ranks worse than up",
  true, Model.linkStateRank("LINK_STATE_DOWN") > Model.linkStateRank("LINK_STATE_UP"));
check("down ranks worse than unknown",
  true, Model.linkStateRank("LINK_STATE_DOWN") < Model.linkStateRank("LINK_STATE_UNKNOWN"));
check("a blank link is unknown, not 0", 2, Model.linkStateRank(""));
check("a missing link is unknown, not 0", 2, Model.linkStateRank(null));
check("LINK_STATE_UNKNOWN is unknown", 2, Model.linkStateRank("LINK_STATE_UNKNOWN"));
check("an unknown spelling is a real down state",
  1, Model.linkStateRank("LINK_STATE_TESTING"));

test_case("linkStateText");

check("up", "up", Model.linkStateText("LINK_STATE_UP"));
check("down", "down", Model.linkStateText("LINK_STATE_DOWN"));
check("unknown", "unknown", Model.linkStateText("LINK_STATE_UNKNOWN"));
check("a blank link is unknown, never undefined", "unknown", Model.linkStateText(""));
check("a missing link is unknown, never undefined", "unknown", Model.linkStateText(null));
check("a spelling this file has not heard of is unknown", "unknown",
  Model.linkStateText("LINK_STATE_TESTING"));

test_case("downInterfaces and unknownInterfaces");

check("only the down rows are copied", ["b"],
  Model.downInterfaces([iface("a", "LINK_STATE_UP"), iface("b", "LINK_STATE_DOWN")])
    .map(function (r) { return r.name; }));
check("input order survives", ["c", "a"],
  Model.downInterfaces([iface("c", "LINK_STATE_DOWN"), iface("a", "LINK_STATE_DOWN")])
    .map(function (r) { return r.name; }));
check("an unknown link is not down", 0,
  Model.downInterfaces([iface("a", "LINK_STATE_UNKNOWN"), iface("b", "")]).length);
check("only the unknown rows are copied", ["a", "b"],
  Model.unknownInterfaces([iface("a", "LINK_STATE_UNKNOWN"), iface("b", ""),
    iface("c", "LINK_STATE_UP")]).map(function (r) { return r.name; }));
const ifaceRows = [iface("a", "LINK_STATE_DOWN")];
check("the down result is a copy, not the input", false,
  Model.downInterfaces(ifaceRows) === ifaceRows);
check("the input is untouched", 1, ifaceRows.length);
check("not a list is an empty list", [], Model.downInterfaces(null));
check("not a list is an empty list for unknown", [], Model.unknownInterfaces(null));
check("junk rows are skipped", 0, Model.downInterfaces([{}, null, 4]).length);

test_case("shareCounts");

check("counts each type and the total",
  { smb: 3, nfs: 1, iscsi: 2, total: 6 },
  Model.shareCounts({ smb: [{}, {}, {}], nfs: [{}], iscsi: [{}, {}] }));
check("an absent key is zero",
  { smb: 0, nfs: 1, iscsi: 0, total: 1 },
  Model.shareCounts({ nfs: [{}] }));
check("a real empty list is a real zero",
  { smb: 0, nfs: 0, iscsi: 0, total: 0 },
  Model.shareCounts({ smb: [], nfs: [], iscsi: [] }));
check("a non-list key is zero",
  { smb: 0, nfs: 0, iscsi: 0, total: 0 },
  Model.shareCounts({ smb: "junk", nfs: 4, iscsi: null }));
check("a junk shares argument is all zeroes",
  { smb: 0, nfs: 0, iscsi: 0, total: 0 }, Model.shareCounts(null));
check("a string shares argument is all zeroes",
  { smb: 0, nfs: 0, iscsi: 0, total: 0 }, Model.shareCounts("junk"));

test_case("tooltipFor");

check("unconfigured points at login", "TrueNAS: run truenasctl login <url>", Model.tooltipFor({}, "unconfigured"));

test_case("capacityBarFill");

check("a known percent rounds to the nearest cell", 4, Model.capacityBarFill(71, 6));
check("half fills to the nearer cell", 3, Model.capacityBarFill(50, 6));
check("zero fills nothing", 0, Model.capacityBarFill(0, 6));
check("a full pool fills every cell", 6, Model.capacityBarFill(100, 6));
check("beyond full is clamped", 6, Model.capacityBarFill(140, 6));
check("negative is clamped", 0, Model.capacityBarFill(-5, 6));
check("unknown is no fill, never a guess", 0, Model.capacityBarFill(null, 6));
check("a blank is no fill", 0, Model.capacityBarFill("", 6));
check("a non-number is no fill", 0, Model.capacityBarFill("lots", 6));
check("NaN is no fill", 0, Model.capacityBarFill(NaN, 6));
check("no cells is no fill", 0, Model.capacityBarFill(50, 0));
check("a non-number cells is no fill", 0, Model.capacityBarFill(50, "six"));

test_case("sparkColumns");

check("fractions, oldest first", [0.1, 0.5, 1], Model.sparkColumns([10, 50, 100], 30));
check("a null sample is a gap", [0.1, null, 0.5], Model.sparkColumns({ capacityPct: [10, null, 50] }, 30));
check("a blank sample is a gap", [null], Model.sparkColumns({ capacityPct: [""] }, 30));
check("a non-number is a gap", [null], Model.sparkColumns({ capacityPct: ["junk"] }, 30));
check("only the last cells survive", [0.7, 0.8], Model.sparkColumns([10, 60, 70, 80], 2));
check("values are clamped to 0..100", [0, 1], Model.sparkColumns({ capacityPct: [-5, 900] }, 30));
check("a real zero is a real zero", [0], Model.sparkColumns({ capacityPct: [0] }, 30));
check("a missing history is empty", [], Model.sparkColumns(null, 30));
check("a history without a list is empty", [], Model.sparkColumns({ at: [] }, 30));
check("no cells is empty", [], Model.sparkColumns([10, 20], 0));

test_case("downTotal");

check("services and apps together", 3,
  Model.downTotal({ services: [{ state: "STOPPED" }, { state: "RUNNING" }],
    apps: [{ state: "CRASHED" }, { state: "FAILED" }] }));
check("no state is zero", 0, Model.downTotal(null));
check("an empty state is zero", 0, Model.downTotal({}));
check("a transitional app is not down", 0,
  Model.downTotal({ services: [], apps: [{ state: "DEPLOYING" }] }));

test_case("protectionFailures");

check("replication, cloud sync and snapshot failures count", 3,
  Model.protectionFailures({
    replication: [replication("a", "FAILED", 0), replication("b", "SUCCESS", 0)],
    cloudSync: [cloudSync("c", "ERROR")],
    snapshotTasks: [{ state: { state: "ABORTED" } }],
    scrubs: [{}]
  }));
check("a running or blank row is unknown, not a failure", 0,
  Model.protectionFailures({
    replication: [replication("a", "RUNNING", 0)],
    cloudSync: [cloudSync("c", "RUNNING")],
    snapshotTasks: [{ state: { state: "" } }],
    scrubs: [{}]
  }));
check("a failed replication job counts", 1,
  Model.protectionFailures({ replication: [replication("a", "FAILED", 0)] }));
check("warnings alone do not count here, only the job state", 0,
  Model.protectionFailures({ replication: [replication("a", "SUCCESS", 2)] }));
check("an empty state is zero", 0, Model.protectionFailures(null));
check("missing lists are zero", 0, Model.protectionFailures({}));

test_case("protectionOverdue");

check("overdue rows count across all four lists", 3,
  Model.protectionOverdue({
    replication: [{ overdue: true }, { overdue: false }],
    cloudSync: [{ overdue: true }],
    snapshotTasks: [{ overdue: true }],
    scrubs: [{ overdue: false }]
  }));
check("a missing or non-boolean flag is not overdue", 0,
  Model.protectionOverdue({
    replication: [{ overdue: "true" }, {}],
    scrubs: [{ overdue: null }]
  }));
check("an empty state is zero", 0, Model.protectionOverdue(null));
check("missing lists are zero", 0, Model.protectionOverdue({}));

test_case("protectionProblems");

check("failed and overdue rows count, a failed overdue row once", 2,
  Model.protectionProblems({
    replication: [{ job: { state: "FAILED" }, overdue: true }],
    snapshotTasks: [{ state: { state: "FINISHED" }, overdue: true }],
    scrubs: [{}]
  }));
check("a no-data row counts", 1,
  Model.protectionProblems({
    snapshotTasks: [{ state: { state: "FINISHED" }, noData: true }]
  }));
check("failed, overdue and no-data together count once", 1,
  Model.protectionProblems({
    snapshotTasks: [{ state: { state: "FAILED" }, overdue: true, noData: true }]
  }));
check("a warning without a failed job is not a problem here", 0,
  Model.protectionProblems({
    replication: [{ job: { state: "SUCCESS" }, state: { warnings: ["x"] } }]
  }));
check("an empty state is zero", 0, Model.protectionProblems(null));
check("missing lists are zero", 0, Model.protectionProblems({}));

test_case("protectionNoData");

check("no-data rows count across the lists", 2,
  Model.protectionNoData({
    replication: [{ noData: true }, { noData: false }],
    snapshotTasks: [{ noData: true }],
    scrubs: [{}]
  }));
check("a string true is not a flag", 0, Model.protectionNoData({ snapshotTasks: [{ noData: "true" }] }));
check("an empty state is zero", 0, Model.protectionNoData(null));
check("missing lists are zero", 0, Model.protectionNoData({}));

test_case("protectionBadge");

check("a failed job keeps its state word", "FAILED",
  Model.protectionBadge({ job: { state: "FAILED" }, overdue: true, noData: true }));
check("an overdue healthy task reads OVERDUE", "OVERDUE",
  Model.protectionBadge({ job: { state: "SUCCESS" }, overdue: true, noData: true }));
check("a no-data task reads NO DATA", "NO DATA",
  Model.protectionBadge({ job: { state: "SUCCESS" }, noData: true }));
check("an unchecked output without no-data is not NO DATA", "SUCCESS",
  Model.protectionBadge({ job: { state: "SUCCESS" }, output: { state: "unknown" } }));
check("and it is not a problem", 0,
  Model.protectionProblems({
    snapshotTasks: [{ state: { state: "SUCCESS" }, output: { state: "unknown" } }]
  }));
check("a healthy task keeps its own state", "SUCCESS",
  Model.protectionBadge({ job: { state: "SUCCESS" } }));
check("a scrub with no state has no badge", "",
  Model.protectionBadge({ id: 1, overdue: false }));
check("a missing row has no badge", "", Model.protectionBadge(null));

test_case("protectionBadgeRank");

check("a failed row is urgent", 1,
  Model.protectionBadgeRank({ job: { state: "FAILED" } }));
check("an overdue row is urgent", 1,
  Model.protectionBadgeRank({ job: { state: "SUCCESS" }, overdue: true }));
check("a no-data row is urgent", 1,
  Model.protectionBadgeRank({ job: { state: "SUCCESS" }, noData: true }));
check("a healthy row is plain", 0,
  Model.protectionBadgeRank({ job: { state: "SUCCESS" } }));
check("a blank state is unknown", 2, Model.protectionBadgeRank({}));
check("a missing row is unknown", 2, Model.protectionBadgeRank(null));

test_case("outputLine");

check("empty says what the run wrote", "last run wrote 0 B",
  Model.outputLine({ output: { state: "empty", written: 0 } }));
check("a positive empty count is formatted", "last run wrote 1 KiB",
  Model.outputLine({ output: { state: "empty", written: 1024 } }));
check("a missing snapshot says so", "last snapshot missing",
  Model.outputLine({ output: { state: "missing" } }));
check("an unanswered check says so", "output not checked",
  Model.outputLine({ output: { state: "unknown" } }));
check("a healthy run has no line", "",
  Model.outputLine({ output: { state: "ok", written: 10 } }));
check("an unflagged row has no line", "", Model.outputLine({}));
check("a missing row has no line", "", Model.outputLine(null));

test_case("protectionRunLine");

const runNow = Date.parse("2026-10-20T00:00:00Z");
check("a recent run reads as an age", "last run 2d ago",
  Model.protectionRunLine({ lastRunAt: "2026-10-18T00:00:00Z" }, runNow));
check("an hour is an hour", "last run 1h ago",
  Model.protectionRunLine({ lastRunAt: "2026-10-19T23:00:00Z" }, runNow));
check("never run has no age", "never run",
  Model.protectionRunLine({ lastRunAt: null }, runNow));
check("an unknown source is not called never run", "last run unknown",
  Model.protectionRunLine({ lastRunKnown: false, lastRunAt: null }, runNow));
check("an unparsable timestamp is unknown", "last run unknown",
  Model.protectionRunLine({ lastRunAt: "not a date" }, runNow));
check("a missing row is unknown", "last run unknown",
  Model.protectionRunLine(null, runNow));

test_case("poolDotSeverity");

check("ONLINE is untinted", "", Model.poolDotSeverity("ONLINE"));
check("DEGRADED is a warning", "warning", Model.poolDotSeverity("DEGRADED"));
check("OFFLINE is an error", "error", Model.poolDotSeverity("OFFLINE"));
check("FAULTED is critical", "critical", Model.poolDotSeverity("FAULTED"));
check("an unknown status is critical, not healthy", "critical", Model.poolDotSeverity("SUSPENDED"));
check("a missing status is critical, not healthy", "critical", Model.poolDotSeverity(null));
check("the status is case-insensitive", "warning", Model.poolDotSeverity("degraded"));

test_case("diskDotSeverity");

check("critical is critical", "critical", Model.diskDotSeverity("critical"));
check("warning is warning", "warning", Model.diskDotSeverity("warning"));
check("ok is untinted", "", Model.diskDotSeverity("ok"));
check("an unknown band is untinted", "", Model.diskDotSeverity("unknown"));
check("a blank band is untinted", "", Model.diskDotSeverity(""));
check("a missing band is untinted", "", Model.diskDotSeverity(null));

test_case("entrySettingsEqual");

check("same settings match", true, Model.entrySettingsEqual({ id: "x", variant: "Temp" }, { variant: "Temp" }));
check("the id is ignored", true, Model.entrySettingsEqual({ id: "x", variant: "Temp" }, { id: "x", variant: "Temp" }));
check("a differing value does not match", false, Model.entrySettingsEqual({ id: "x", variant: "Temp" }, { variant: "Pool" }));
check("a missing key equals an absent key", true, Model.entrySettingsEqual({ id: "x" }, {}));
check("a missing key differs from a set one", false, Model.entrySettingsEqual({ id: "x" }, { variant: "Temp" }));
check("null and absent are the same absence", true, Model.entrySettingsEqual({ id: "x", variant: null }, {}));
check("nested values compare", false,
  Model.entrySettingsEqual({ id: "x", extra: { a: 1 } }, { extra: { a: 2 } }));
check("non-objects have equal empty settings", true, Model.entrySettingsEqual(null, undefined));

test_case("entrySelector");

const barLayout = [
  { id: "omarchy.clock" },
  { id: "io.github.h4ad.truenas", variant: "Full" },
  { id: "io.github.h4ad.truenas", variant: "Temp" },
  { id: "io.github.h4ad.truenas", variant: "CapacityBar" }
];
check("the first instance resolves to its index", 1,
  Model.entrySelector(barLayout, "io.github.h4ad.truenas", { variant: "Full" }));
check("the second instance resolves to its own index", 2,
  Model.entrySelector(barLayout, "io.github.h4ad.truenas", { variant: "Temp" }));
check("the third instance resolves to its own index", 3,
  Model.entrySelector(barLayout, "io.github.h4ad.truenas", { variant: "CapacityBar" }));
check("an unset value is no match", -1,
  Model.entrySelector(barLayout, "io.github.h4ad.truenas", { variant: "Pool" }));
check("an unknown id is no match", -1,
  Model.entrySelector(barLayout, "io.github.h4ad.other", { variant: "Full" }));
check("identical entries resolve to the first, index 0", 0,
  Model.entrySelector([{ id: "x" }, { id: "x" }], "x", {}));
check("not a list is no match", -1, Model.entrySelector(null, "x", {}));

test_case("entryLocation");

const barSections = {
  left: [{ id: "omarchy.menu" }],
  center: [{ id: "omarchy.clock" }],
  right: [
    { id: "io.github.h4ad.truenas", variant: "Full" },
    { id: "io.github.h4ad.truenas", variant: "Pool" }
  ]
};
check("the region and index are returned", { section: "right", index: 1 },
  Model.entryLocation(barSections, "io.github.h4ad.truenas", { variant: "Pool" }));
check("a left entry resolves there", { section: "left", index: 0 },
  Model.entryLocation(barSections, "omarchy.menu", {}));
check("no matching entry is null", null,
  Model.entryLocation(barSections, "io.github.h4ad.truenas", { variant: "Temp" }));
check("no layout is null", null, Model.entryLocation(null, "x", {}));

console.log("\nmodel: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
