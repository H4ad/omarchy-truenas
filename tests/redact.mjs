// Runs Redact.js under node. Like Model.js it has to stay loadable by QML as
// `import "Redact.js" as Redact`, so it is not a module: it is read and evaluated
// here, and its top-level declarations are collected into one object. The loader
// is the one tests/model.mjs uses.
//
//   node tests/redact.mjs
//
// Prints one line per assertion, in the shape tests/lib.sh's `check` prints, and
// exits non-zero if any of them failed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(root, "Redact.js"), "utf8")
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
const Redact = new Function(source + "\nreturn { " + exports + " };")();

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

function sample() {
  return {
    schema: 1,
    updatedAt: "2026-09-20T00:00:00Z",
    connection: { ok: true, version: "25.10.6", message: "connected to monster" },
    system: { hostname: "monster", version: "25.10.6", uptimeSeconds: 100 },
    counts: { total: 1, warning: 1 },
    alerts: [ { level: "warning", text: "pool storage is DEGRADED",
                formatted: "pool storage is DEGRADED", node: "monster", uuid: "u1" } ],
    pools: [ { name: "storage", status: "ONLINE", usedPct: 6 } ],
    disks: [ { name: "sda", model: "SATA_HDD_4T", pool: "storage", tempC: 37 } ],
    services: [ { id: "cifs", service: "cifs", state: "RUNNING" } ],
    apps: [ { id: "appa", name: "forgejo", title: "Forgejo", state: "RUNNING", version: "1.0" } ],
    replication: [ { id: 1, name: "storage-to-backup",
                     targetDataset: "Backup/media", sourceDatasets: ["storage/media"] } ],
    cloudSync: [ { id: 2, name: "offsite", path: "/mnt/storage/media" } ],
    snapshotTasks: [ { id: 3, dataset: "storage", state: { lastSnapshot: "storage@auto-1" },
                       output: { state: "empty", written: 0, snapshot: "storage@auto-1" } } ],
    scrubs: [ { id: 4, pool: "storage", description: "monthly scrub of storage" } ],
    shares: {
      smb: [ { id: "s1", name: "media", path: "/mnt/storage/media" } ],
      nfs: [ { id: "n1", path: "/mnt/storage/media" } ],
      iscsi: [ { id: "i1", name: "iqn.2005-10", alias: "backup" } ]
    },
    network: [ { name: "enp4s0", linkState: "LINK_STATE_UP",
                 addresses: [ { type: "INET", address: "192.168.15.201", netmask: 24 } ] } ],
    warnings: [ { section: "app", error: "timeout",
                  message: "monster did not answer for storage" } ]
  };
}

function startsWith(value, prefix) {
  return typeof value === "string" && value.indexOf(prefix) === 0;
}

test_case("levels");
check("off is rank 0", 0, Redact.rank("off"));
check("network is rank 1", 1, Redact.rank("network"));
check("names is rank 2", 2, Redact.rank("names"));
check("all is rank 3", 3, Redact.rank("all"));
check("an unknown level normalizes to off", "off", Redact.normalize("verbose"));
check("a missing level normalizes to off", "off", Redact.normalize(null));
check("a mixed-case level is accepted", "names", Redact.normalize("Names"));
check("off is not on", false, Redact.isOn("off"));
check("network is on", true, Redact.isOn("network"));
check("describe names names the categories", true, Redact.describe("names").indexOf("pools") !== -1);

test_case("off leaves the object alone");
{
  const state = sample();
  check("apply off returns the same object", true, Redact.apply(state, "off") === state);
  const doc = { instance: { baseUrl: "https://nas.example" } };
  check("applyConfig off returns the same object", true, Redact.applyConfig(doc, "off") === doc);
}

test_case("network hides identity, keeps the world");
{
  const state = sample();
  const before = JSON.stringify(state);
  const out = Redact.apply(state, "network");
  check("the input is not mutated", before, JSON.stringify(state));
  check("hostname is a fake host", true, startsWith(out.system.hostname, "nas-"));
  check("version survives at network", "25.10.6", out.system.version);
  check("a pool name survives at network", "storage", out.pools[0].name);
  check("a disk model survives at network", "SATA_HDD_4T", out.disks[0].model);
  check("an address is TEST-NET-1", true, startsWith(out.network[0].addresses[0].address, "192.0.2."));
  check("the CIDR suffix is kept", true, Redact.ipName("10.0.0.1/16").endsWith("/16"));
  check("the netmask is not an address", 24, out.network[0].addresses[0].netmask);
  check("the alert node is a fake host", true, startsWith(out.alerts[0].node, "nas-"));
  check("free text loses the hostname", false,
    out.connection.message.indexOf("monster") !== -1);
  check("free text keeps a pool name at network", true,
    out.alerts[0].text.indexOf("storage") !== -1);
}

test_case("names hides names, keeps the version");
{
  const out = Redact.apply(sample(), "names");
  check("a pool name is a token", true, startsWith(out.pools[0].name, "item-"));
  check("a disk name is a token", true, startsWith(out.disks[0].name, "item-"));
  check("a disk model is a model token", true, startsWith(out.disks[0].model, "model-"));
  check("a disk's pool is the pool token", out.pools[0].name, out.disks[0].pool);
  check("an app title is a token", true, startsWith(out.apps[0].title, "item-"));
  check("an interface name is a token", true, startsWith(out.network[0].name, "item-"));
  check("a dataset path keeps its slashes", true,
    out.replication[0].targetDataset.indexOf("/") !== -1);
  check("a dataset's pool component matches the pool token", out.pools[0].name,
    out.replication[0].sourceDatasets[0].split("/")[0]);
  check("a snapshot keeps its @", true, out.snapshotTasks[0].state.lastSnapshot.indexOf("@") !== -1);
  check("the output snapshot gets the same token", out.snapshotTasks[0].state.lastSnapshot,
    out.snapshotTasks[0].output.snapshot);
  check("a scrub description keeps readable prose", true,
    out.scrubs[0].description.indexOf("monthly") !== -1);
  check("free text loses a pool name", false,
    out.alerts[0].text.indexOf("storage") !== -1);
  check("free text substitutes the pool token", true,
    out.alerts[0].text.indexOf(out.pools[0].name) !== -1);
  check("a warning message loses the hostname", false,
    out.warnings[0].message.indexOf("monster") !== -1);
  check("version survives at names", "25.10.6", out.system.version);
  check("a service name survives at names", "cifs", out.services[0].service);
}

test_case("all hides the version and free text");
{
  const out = Redact.apply(sample(), "all");
  check("version is a placeholder", "x.y.z", out.system.version);
  check("connection version is a placeholder", "x.y.z", out.connection.version);
  check("a service name is a token", true, startsWith(out.services[0].service, "service-"));
  check("alert text is hidden", "hidden for recording", out.alerts[0].text);
  check("formatted text is hidden", "hidden for recording", out.alerts[0].formatted);
  check("a warning message is hidden", "hidden for recording", out.warnings[0].message);
  check("an empty text stays empty", "", Redact.apply({ alerts: [{ text: "" }] }, "all").alerts[0].text);
}

test_case("an address written only in prose is faked");
{
  // The field map only substitutes a value it has seen as a field. A client
  // address in an alert body is in no field, which is the case the other suites
  // miss: their sample always carries the address it looks for.
  const state = {
    network: [ { name: "enp4s0", addresses: [ { address: "192.168.15.2", netmask: 24 } ] } ],
    alerts: [ { level: "warning", uuid: "u1", text: "authenticated 12 times from "
      + "127.0.0.1, 192.168.15.2 and 192.168.15.99. The REST API goes in version "
      + "25.10.6, build 10.20.30.40.50, link fe80::1" } ],
    warnings: [ { section: "app", error: "timeout", message:
      "could not reach https://portal.example.lan:8443/ui from 10.0.0.7 at 17:24:50" } ]
  };
  const out = Redact.apply(state, "network");
  const text = out.alerts[0].text;
  check("an address that is no field is faked", false, text.indexOf("192.168.15.99") !== -1);
  check("a full stop after it is not part of it", false, text.indexOf("192.168.15.99.") !== -1);
  check("it lands in TEST-NET-1", true, text.indexOf("192.0.2.") !== -1);
  check("a field's address reads the same in both places", true,
    text.indexOf(out.network[0].addresses[0].address) !== -1);
  check("loopback names no host and stays", true, text.indexOf("127.0.0.1") !== -1);
  check("an IPv6 literal is faked", true,
    text.indexOf("fe80::") === -1 && text.indexOf("2001:db8::") !== -1);
  check("a three-part version is not an address", true, text.indexOf("25.10.6") !== -1);
  check("a five-part version is not one either", true, text.indexOf("10.20.30.40.50") !== -1);

  const message = out.warnings[0].message;
  check("a URL host in prose is faked", false, message.indexOf("portal.example.lan") !== -1);
  check("its port and path survive", true, message.indexOf(":8443/ui") !== -1);
  check("a bare address in prose is faked", false, message.indexOf("10.0.0.7") !== -1);
  check("a clock time is not an address", true, message.indexOf("17:24:50") !== -1);
  check("off leaves prose alone", "from 10.0.0.7",
    Redact.apply({ warnings: [ { message: "from 10.0.0.7" } ] }, "off").warnings[0].message);
}

test_case("stable pseudonyms");
{
  const first = Redact.apply(sample(), "names");
  const second = Redact.apply(sample(), "names");
  check("the same input gives the same output", JSON.stringify(first), JSON.stringify(second));
  check("two different pools give different tokens", true,
    Redact.apply({ pools: [{ name: "storage" }, { name: "Backup" }] }, "names")
      .pools[0].name !==
    Redact.apply({ pools: [{ name: "storage" }, { name: "Backup" }] }, "names")
      .pools[1].name);
}

test_case("config documents");
{
  const raw = { schema: 1, instances: [ { id: "nas", baseUrl: "https://192.168.15.201:4433" } ] };
  const rawBefore = JSON.stringify(raw);
  const redacted = Redact.applyConfig(raw, "network");
  check("the raw config is not mutated", rawBefore, JSON.stringify(raw));
  check("the scheme and port survive", true,
    redacted.instances[0].baseUrl.indexOf("https://nas-") === 0
      && redacted.instances[0].baseUrl.endsWith(":4433"));
  check("the address is gone", false,
    redacted.instances[0].baseUrl.indexOf("192.168.15.201") !== -1);

  const list = { instance: { id: "nas", baseUrl: "https://nas.example:4433" }, keySet: true, redact: "names" };
  const listOut = Redact.applyConfig(list, "network");
  check("the config list base URL is redacted", true,
    listOut.instance.baseUrl.indexOf("nas.example") === -1);
  check("the redact level is not a base URL and survives", "names", listOut.redact);
  check("the real config list is not mutated", "https://nas.example:4433", list.instance.baseUrl);
}

test_case("printed URLs");
{
  check("off prints the real URL", "https://nas.example:4433/ui",
    Redact.url("https://nas.example:4433/ui", "off"));
  check("network fakes the host", true,
    Redact.url("https://nas.example:4433/ui", "network").indexOf("nas.example") === -1);
  check("network keeps the path", true,
    Redact.url("https://nas.example:4433/ui", "network").endsWith(":4433/ui"));
  check("a bare host becomes a fake host", true,
    startsWith(Redact.url("nas.example", "network"), "nas-"));
  check("an IPv6 URL keeps its brackets", true,
    Redact.redactUrl("https://[2001:db8::1]:443").indexOf("[") !== -1);
}

console.log("\nredact: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
