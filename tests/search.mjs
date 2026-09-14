// Runs the pure helpers in Search.js under node. Search.js has to stay loadable
// by QML as `.import "Search.js" as Search`, so it is not a module: it is read
// and evaluated here, and its top-level declarations are collected into one
// object.
//
//   node tests/search.mjs
//
// Prints one line per assertion, in the shape tests/lib.sh's `check` prints, and
// exits non-zero if any of them failed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
// `.pragma library` and `.import` are QML script directives, not JavaScript, so
// they have to come off before node can evaluate the file.
const source = readFileSync(join(root, "Search.js"), "utf8")
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
const Search = new Function(source + "\nreturn { " + exports + " };")();

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

const alerts = [
  { level: "CRITICAL", text: "Pool storage state is DEGRADED",
    formatted: "Pool storage is DEGRADED", node: "nas-a", uuid: "c1" },
  { level: "WARNING", text: "SMART error on disk",
    formatted: "", node: "nas-b", uuid: "w1" },
  { level: "INFO", text: "Scrub finished",
    formatted: "Scrub of boot finished", node: "nas-a", uuid: "i1" }
];

test_case("contains is a case-insensitive substring");

check("finds a lower needle in mixed text", true, Search.contains("Pool storage", "storage"));
check("misses when the needle is absent", false, Search.contains("Pool storage", "boot"));
check("an empty needle is contained by everything", true, Search.contains("", ""));
check("a missing field is empty text, not an error", false, Search.contains(null, "storage"));

test_case("alerts matches level, text, formatted and node");

check("level, case-insensitively", 1, Search.alerts(alerts, "critical").length);
check("the short text", 1, Search.alerts(alerts, "degraded").length);
check("the formatted text when the short text misses", 1,
  Search.alerts(alerts, "of boot").length);
check("the node, across rows", 2, Search.alerts(alerts, "NAS-A").length);
check("a needle nothing carries", 0, Search.alerts(alerts, "nothing").length);

test_case("alerts preserves order and never mutates");

check("arrival order survives the filter", ["c1", "w1", "i1"],
  Search.alerts(alerts, "nas").map(function (a) { return a.uuid; }));
check("an empty needle returns every row", ["c1", "w1", "i1"],
  Search.alerts(alerts, "").map(function (a) { return a.uuid; }));
const alertsBefore = JSON.stringify(alerts);
Search.alerts(alerts, "critical");
check("the input list is untouched", alertsBefore, JSON.stringify(alerts));
check("the empty-needle result is a copy", false, Search.alerts(alerts, "") === alerts);
check("a non-list is an empty list", [], Search.alerts(null, "x"));

const pools = [
  { name: "storage", status: "ONLINE" },
  { name: "boot", status: "DEGRADED" },
  { name: "backup", status: "OFFLINE" }
];

test_case("pools matches name and status");

check("name, case-insensitively", ["storage"],
  Search.pools(pools, "storage").map(function (p) { return p.name; }));
check("status, case-insensitively", ["boot"],
  Search.pools(pools, "degraded").map(function (p) { return p.name; }));
check("a needle nothing carries", 0, Search.pools(pools, "archive").length);
check("an empty needle returns every pool", 3, Search.pools(pools, "").length);
const poolsBefore = JSON.stringify(pools);
Search.pools(pools, "storage");
check("the input list is untouched", poolsBefore, JSON.stringify(pools));
check("the empty-needle result is a copy", false, Search.pools(pools, "") === pools);

const disks = [
  { name: "nvme0n1", model: "NVMe_SSD_2T", type: "SSD",
    size: 2000398934016, pool: "storage", bus: "UNKNOWN" },
  { name: "sda", model: "SATA_HDD_500G", type: "HDD",
    size: 500107862016, pool: "boot-pool", bus: "ATA" },
  { name: "sdc", model: "SATA_HDD_4T", type: "HDD",
    size: 4000787030016, pool: "Backup", bus: "ATA" }
];

test_case("disks matches name, model, type, pool and bus");

check("name, case-insensitively", ["nvme0n1"],
  Search.disks(disks, "NVME").map(function (d) { return d.name; }));
check("model, case-insensitively", ["nvme0n1"],
  Search.disks(disks, "nvme").map(function (d) { return d.name; }));
check("type, across rows", ["sda", "sdc"],
  Search.disks(disks, "hdd").map(function (d) { return d.name; }));
check("pool", ["sda"],
  Search.disks(disks, "boot").map(function (d) { return d.name; }));
check("bus", ["sda", "sdc"],
  Search.disks(disks, "ata").map(function (d) { return d.name; }));
check("a needle nothing carries", 0,
  Search.disks(disks, "archive").length);

test_case("disks preserves order, copies and survives junk");

check("an empty needle returns every disk", ["nvme0n1", "sda", "sdc"],
  Search.disks(disks, "").map(function (d) { return d.name; }));
const disksBefore = JSON.stringify(disks);
Search.disks(disks, "nvme");
check("the input list is untouched", disksBefore, JSON.stringify(disks));
check("the empty-needle result is a copy", false, Search.disks(disks, "") === disks);
check("a non-list is an empty list", [], Search.disks(null, "x"));
check("a bare string is not walked", [], Search.disks("nvme", "x"));
check("a row without fields does not throw", 0,
  Search.disks([{}], "x").length);
check("null rows are skipped, not fatal", 0,
  Search.disks([null, undefined, 4], "x").length);
check("an empty field never matches a needle", 0,
  Search.disks([{ name: null, model: undefined, pool: "", bus: null, type: null }], "x").length);

const services = [
  { id: 4, service: "cifs", state: "RUNNING", enable: true },
  { id: 5, service: "ups", state: "STOPPED", enable: false },
  { id: 6, service: "nvmet", state: "STOPPED", enable: false }
];

test_case("services matches service, state and id");

check("name, case-insensitively", ["cifs"],
  Search.services(services, "CIFS").map(function (s) { return s.service; }));
check("state, across rows", ["ups", "nvmet"],
  Search.services(services, "stopped").map(function (s) { return s.service; }));
check("id, stringified from a number", ["ups"],
  Search.services(services, "5").map(function (s) { return s.service; }));
check("a needle nothing carries", 0, Search.services(services, "archive").length);

test_case("services preserves order, copies and survives junk");

check("an empty needle returns every service", ["cifs", "ups", "nvmet"],
  Search.services(services, "").map(function (s) { return s.service; }));
check("matching order is input order", ["ups", "nvmet"],
  Search.services(services, "stopped").map(function (s) { return s.service; }));
const servicesBefore = JSON.stringify(services);
Search.services(services, "cifs");
check("the input list is untouched", servicesBefore, JSON.stringify(services));
check("the empty-needle result is a copy", false, Search.services(services, "") === services);
check("a non-list is an empty list", [], Search.services(null, "x"));
check("a bare string is not walked", [], Search.services("cifs", "x"));
check("a row without fields does not throw", 0, Search.services([{}], "x").length);
check("null rows are skipped, not fatal", 0,
  Search.services([null, undefined, 4], "x").length);
check("an empty field never matches a needle", 0,
  Search.services([{ service: null, state: undefined, id: null }], "x").length);

const apps = [
  { id: "appc", name: "appc", title: "appc", state: "RUNNING",
    train: "community", appVersion: "16.0.4-rootless", version: "16.0.4-rootless_1.2.39" },
  { id: "appb", name: "appb", title: "appb", state: "STOPPED",
    train: "community", appVersion: "2.1.0", version: "2.1.0_1.0.0" },
  { id: "appa", name: "appa", title: "AI Memory", state: "RUNNING",
    train: "custom", appVersion: "1.0.0", version: "1.0.0_1.0.0" }
];

test_case("apps matches name, title, state, train, appVersion and version");

check("name, case-insensitively", ["appb"],
  Search.apps(apps, "appb").map(function (a) { return a.name; }));
check("title when the name misses", ["appa"],
  Search.apps(apps, "AI Memory").map(function (a) { return a.name; }));
check("state, across rows", ["appc", "appa"],
  Search.apps(apps, "running").map(function (a) { return a.name; }));
check("train", ["appa"],
  Search.apps(apps, "custom").map(function (a) { return a.name; }));
check("appVersion", ["appb"],
  Search.apps(apps, "2.1.0").map(function (a) { return a.name; }));
check("version", ["appc"],
  Search.apps(apps, "rootless_1.2.39").map(function (a) { return a.name; }));
check("a needle nothing carries", 0, Search.apps(apps, "archive").length);

test_case("apps preserves order, copies and survives junk");

check("an empty needle returns every app", ["appc", "appb", "appa"],
  Search.apps(apps, "").map(function (a) { return a.name; }));
check("matching order is input order", ["appc", "appa"],
  Search.apps(apps, "running").map(function (a) { return a.name; }));
const appsBefore = JSON.stringify(apps);
Search.apps(apps, "appc");
check("the input list is untouched", appsBefore, JSON.stringify(apps));
check("the empty-needle result is a copy", false, Search.apps(apps, "") === apps);
check("a non-list is an empty list", [], Search.apps(null, "x"));
check("a bare string is not walked", [], Search.apps("appc", "x"));
check("a row without fields does not throw", 0, Search.apps([{}], "x").length);
check("null rows are skipped, not fatal", 0,
  Search.apps([null, undefined, 4], "x").length);
check("an empty field never matches a needle", 0,
  Search.apps([{ name: null, title: "", state: null, train: undefined,
    appVersion: null, version: "" }], "x").length);

const replicationTasks = [
  { name: "storage-to-backup", direction: "PUSH", transport: "LOCAL",
    targetDataset: "Backup/replica-storage",
    state: { state: "FINISHED" }, job: { state: "SUCCESS" } },
  { name: "backup-to-offsite", direction: "PULL", transport: "SSH",
    targetDataset: "storage/offsite",
    state: { state: "PENDING" }, job: null }
];

test_case("replication matches name, direction, transport, target and state");

check("name, case-insensitively", ["storage-to-backup"],
  Search.replication(replicationTasks, "storage-TO").map(function (r) { return r.name; }));
check("direction", ["backup-to-offsite"],
  Search.replication(replicationTasks, "pull").map(function (r) { return r.name; }));
check("transport", ["backup-to-offsite"],
  Search.replication(replicationTasks, "ssh").map(function (r) { return r.name; }));
check("target dataset", ["storage-to-backup"],
  Search.replication(replicationTasks, "replica").map(function (r) { return r.name; }));
check("the task state when the job is null", ["backup-to-offsite"],
  Search.replication(replicationTasks, "pending").map(function (r) { return r.name; }));
check("the job state", ["storage-to-backup"],
  Search.replication(replicationTasks, "success").map(function (r) { return r.name; }));
check("a needle nothing carries", 0, Search.replication(replicationTasks, "archive").length);

test_case("replication preserves order, copies and survives junk");

check("an empty needle returns every task", ["storage-to-backup", "backup-to-offsite"],
  Search.replication(replicationTasks, "").map(function (r) { return r.name; }));
const replicationBefore = JSON.stringify(replicationTasks);
Search.replication(replicationTasks, "ssh");
check("the input list is untouched", replicationBefore, JSON.stringify(replicationTasks));
check("the empty-needle result is a copy", false, Search.replication(replicationTasks, "") === replicationTasks);
check("a non-list is an empty list", [], Search.replication(null, "x"));
check("a bare string is not walked", [], Search.replication("storage", "x"));
check("a row without fields does not throw", 0, Search.replication([{}], "x").length);
check("null rows are skipped, not fatal", 0, Search.replication([null, undefined, 4], "x").length);

const cloudSyncTasks = [
  { name: "clouda", path: "/mnt/storage/photos", direction: "PUSH",
    transferMode: "SYNC", job: { state: "SUCCESS" } },
  { name: "cloudb", path: "/mnt/Backup/backup", direction: "PULL",
    transferMode: "COPY", job: { state: "FAILED" } }
];

test_case("cloudSync matches name, path, direction, mode and job state");

check("name, case-insensitively", ["clouda"],
  Search.cloudSync(cloudSyncTasks, "clouda").map(function (t) { return t.name; }));
check("path", ["cloudb"],
  Search.cloudSync(cloudSyncTasks, "backup/backup").map(function (t) { return t.name; }));
check("direction", ["cloudb"],
  Search.cloudSync(cloudSyncTasks, "pull").map(function (t) { return t.name; }));
check("transfer mode", ["cloudb"],
  Search.cloudSync(cloudSyncTasks, "copy").map(function (t) { return t.name; }));
check("the job state", ["cloudb"],
  Search.cloudSync(cloudSyncTasks, "failed").map(function (t) { return t.name; }));
check("a needle nothing carries", 0, Search.cloudSync(cloudSyncTasks, "archive").length);

test_case("cloudSync preserves order, copies and survives junk");

check("an empty needle returns every task", ["clouda", "cloudb"],
  Search.cloudSync(cloudSyncTasks, "").map(function (t) { return t.name; }));
const cloudSyncBefore = JSON.stringify(cloudSyncTasks);
Search.cloudSync(cloudSyncTasks, "clouda");
check("the input list is untouched", cloudSyncBefore, JSON.stringify(cloudSyncTasks));
check("the empty-needle result is a copy", false, Search.cloudSync(cloudSyncTasks, "") === cloudSyncTasks);
check("a non-list is an empty list", [], Search.cloudSync(null, "x"));
check("a bare string is not walked", [], Search.cloudSync("clouda", "x"));
check("a row without fields does not throw", 0, Search.cloudSync([{}], "x").length);
check("null rows are skipped, not fatal", 0, Search.cloudSync([null, undefined, 4], "x").length);

const snapshotTaskRows = [
  { dataset: "storage", namingSchema: "auto-hourly-%Y",
    state: { state: "FINISHED", lastSnapshot: "storage@auto-hourly-1" } },
  { dataset: "Backup", namingSchema: "auto-daily-%Y",
    state: { state: "PENDING", lastSnapshot: null } }
];

test_case("snapshotTasks matches dataset, naming schema, state and snapshot");

check("dataset, case-insensitively", ["storage"],
  Search.snapshotTasks(snapshotTaskRows, "storage").map(function (t) { return t.dataset; }));
check("naming schema", ["storage"],
  Search.snapshotTasks(snapshotTaskRows, "hourly").map(function (t) { return t.dataset; }));
check("the task state", ["Backup"],
  Search.snapshotTasks(snapshotTaskRows, "pending").map(function (t) { return t.dataset; }));
check("the last snapshot", ["storage"],
  Search.snapshotTasks(snapshotTaskRows, "auto-hourly-1").map(function (t) { return t.dataset; }));
check("a needle nothing carries", 0, Search.snapshotTasks(snapshotTaskRows, "archive").length);

test_case("snapshotTasks preserves order, copies and survives junk");

check("an empty needle returns every task", ["storage", "Backup"],
  Search.snapshotTasks(snapshotTaskRows, "").map(function (t) { return t.dataset; }));
const snapshotBefore = JSON.stringify(snapshotTaskRows);
Search.snapshotTasks(snapshotTaskRows, "storage");
check("the input list is untouched", snapshotBefore, JSON.stringify(snapshotTaskRows));
check("the empty-needle result is a copy", false, Search.snapshotTasks(snapshotTaskRows, "") === snapshotTaskRows);
check("a non-list is an empty list", [], Search.snapshotTasks(null, "x"));
check("a bare string is not walked", [], Search.snapshotTasks("storage", "x"));
check("a row without fields does not throw", 0, Search.snapshotTasks([{}], "x").length);
check("null rows are skipped, not fatal", 0, Search.snapshotTasks([null, undefined, 4], "x").length);

const scrubRows = [
  { pool: "storage", description: "monthly scrub", threshold: 35, enabled: true },
  { pool: "Backup", description: "", threshold: 35, enabled: false }
];

test_case("scrubs matches pool, description, threshold and enabled");

check("pool, case-insensitively", ["storage"],
  Search.scrubs(scrubRows, "storage").map(function (t) { return t.pool; }));
check("description", ["storage"],
  Search.scrubs(scrubRows, "monthly").map(function (t) { return t.pool; }));
check("the threshold, stringified from a number", ["storage", "Backup"],
  Search.scrubs(scrubRows, "35").map(function (t) { return t.pool; }));
check("the enabled flag", ["storage"],
  Search.scrubs(scrubRows, "true").map(function (t) { return t.pool; }));
check("a needle nothing carries", 0, Search.scrubs(scrubRows, "archive").length);

test_case("scrubs preserves order, copies and survives junk");

check("an empty needle returns every task", ["storage", "Backup"],
  Search.scrubs(scrubRows, "").map(function (t) { return t.pool; }));
const scrubsBefore = JSON.stringify(scrubRows);
Search.scrubs(scrubRows, "storage");
check("the input list is untouched", scrubsBefore, JSON.stringify(scrubRows));
check("the empty-needle result is a copy", false, Search.scrubs(scrubRows, "") === scrubRows);
check("a non-list is an empty list", [], Search.scrubs(null, "x"));
check("a bare string is not walked", [], Search.scrubs("storage", "x"));
check("a row without fields does not throw", 0, Search.scrubs([{}], "x").length);
check("null rows are skipped, not fatal", 0, Search.scrubs([null, undefined, 4], "x").length);

const shareRows = [
  { name: "default", path: "/mnt/storage/default", comment: "", purpose: "DEFAULT_SHARE" },
  { name: "backups", path: "/mnt/storage/backup", comment: "nightly copies", purpose: "SMB_PRESET" },
  { path: "/mnt/Backup/media", comment: "", purpose: "" }
];

test_case("shares matches name, path, comment and purpose");

check("name, case-insensitively", ["backups"],
  Search.shares(shareRows, "BACKUPS").map(function (s) { return s.name || s.path; }));
check("path", ["backups"],
  Search.shares(shareRows, "storage/backup").map(function (s) { return s.name || s.path; }));
check("comment", ["backups"],
  Search.shares(shareRows, "nightly").map(function (s) { return s.name || s.path; }));
check("purpose", ["default"],
  Search.shares(shareRows, "default_share").map(function (s) { return s.name || s.path; }));
check("a row with no name still matches on its path", ["/mnt/Backup/media"],
  Search.shares(shareRows, "media").map(function (s) { return s.name || s.path; }));
check("a needle nothing carries", 0, Search.shares(shareRows, "archive").length);

test_case("shares preserves order, copies and survives junk");

check("an empty needle returns every share", ["default", "backups", "/mnt/Backup/media"],
  Search.shares(shareRows, "").map(function (s) { return s.name || s.path; }));
check("matching order is input order", ["backups", "/mnt/Backup/media"],
  Search.shares(shareRows, "backup").map(function (s) { return s.name || s.path; }));
const sharesBefore = JSON.stringify(shareRows);
Search.shares(shareRows, "backup");
check("the input list is untouched", sharesBefore, JSON.stringify(shareRows));
check("the empty-needle result is a copy", false, Search.shares(shareRows, "") === shareRows);
check("a non-list is an empty list", [], Search.shares(null, "x"));
check("a bare string is not walked", [], Search.shares("default", "x"));
check("a row without fields does not throw", 0, Search.shares([{}], "x").length);
check("null rows are skipped, not fatal", 0,
  Search.shares([null, undefined, 4], "x").length);
check("an empty field never matches a needle", 0,
  Search.shares([{ name: null, path: "", comment: undefined, purpose: null }], "x").length);

const interfaceRows = [
  { name: "enp4s0", type: "PHYSICAL", linkState: "LINK_STATE_UP",
    mediaType: "Ethernet", mediaSubtype: "1000Mb/s Twisted Pair",
    addresses: [{ type: "INET", address: "192.0.2.10", netmask: 24 }] },
  { name: "br0", type: "BRIDGE", linkState: "LINK_STATE_DOWN",
    mediaType: "Ethernet", mediaSubtype: "",
    addresses: [{ type: "INET6", address: "2001:db8::20", netmask: 64 }] }
];

test_case("interfaces matches name, type, link, media and addresses");

check("name, case-insensitively", ["enp4s0"],
  Search.interfaces(interfaceRows, "ENP4S0").map(function (n) { return n.name; }));
check("type", ["br0"],
  Search.interfaces(interfaceRows, "bridge").map(function (n) { return n.name; }));
check("link state", ["enp4s0"],
  Search.interfaces(interfaceRows, "LINK_STATE_UP").map(function (n) { return n.name; }));
check("media type", ["enp4s0", "br0"],
  Search.interfaces(interfaceRows, "ethernet").map(function (n) { return n.name; }));
check("media subtype", ["enp4s0"],
  Search.interfaces(interfaceRows, "twisted pair").map(function (n) { return n.name; }));
check("an address match", ["enp4s0"],
  Search.interfaces(interfaceRows, "192.0.2.10").map(function (n) { return n.name; }));
check("an IPv6 address match", ["br0"],
  Search.interfaces(interfaceRows, "2001:db8").map(function (n) { return n.name; }));
check("a needle nothing carries", 0,
  Search.interfaces(interfaceRows, "archive").length);

test_case("interfaces preserves order, copies and survives junk");

check("an empty needle returns every interface", ["enp4s0", "br0"],
  Search.interfaces(interfaceRows, "").map(function (n) { return n.name; }));
const interfacesBefore = JSON.stringify(interfaceRows);
Search.interfaces(interfaceRows, "bridge");
check("the input list is untouched", interfacesBefore, JSON.stringify(interfaceRows));
check("the empty-needle result is a copy", false,
  Search.interfaces(interfaceRows, "") === interfaceRows);
check("a non-list is an empty list", [], Search.interfaces(null, "x"));
check("a bare string is not walked", [], Search.interfaces("enp4s0", "x"));
check("a row without fields does not throw", 0, Search.interfaces([{}], "x").length);
check("null rows are skipped, not fatal", 0,
  Search.interfaces([null, undefined, 4], "x").length);
check("a row with no addresses still matches on its name", ["lo"],
  Search.interfaces([{ name: "lo", type: "PHYSICAL", linkState: "LINK_STATE_UP",
    mediaType: "", mediaSubtype: "" }], "lo").map(function (n) { return n.name; }));

console.log("\nsearch: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
