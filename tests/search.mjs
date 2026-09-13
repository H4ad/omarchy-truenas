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

console.log("\nsearch: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
