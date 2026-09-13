// Runs the pure helpers in Links.js under node. Links.js has to stay loadable
// by QML as `.import "Links.js" as Links`, so it is not a module: it is read and
// evaluated here, and its top-level declarations are collected into one object.
//
//   node tests/links.mjs
//
// Prints one line per assertion, in the shape tests/lib.sh's `check` prints, and
// exits non-zero if any of them failed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
// `.pragma library` and `.import` are QML script directives, not JavaScript, so
// they have to come off before node can evaluate the file.
const source = readFileSync(join(root, "Links.js"), "utf8")
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
const Links = new Function(source + "\nreturn { " + exports + " };")();

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

const base = "https://nas.example.com";

test_case("safeUrl accepts only the configured origin");

check("the base itself", base, Links.safeUrl(base, base));
check("a path under the base", base + "/ui/alerts", Links.safeUrl(base + "/ui/alerts", base));
check("a query under the base", base + "/ui/storage?id=1",
  Links.safeUrl(base + "/ui/storage?id=1", base));
check("a fragment under the base", base + "/ui/system#tab",
  Links.safeUrl(base + "/ui/system#tab", base));
check("a base with a trailing slash is normalized", base + "/ui/apps",
  Links.safeUrl(base + "/ui/apps", base + "/"));

test_case("safeUrl rejects a suffix that is not the origin");

check("a sibling host", "", Links.safeUrl("https://nas.example.com.attacker.test/steal", base));
check("a host whose name merely starts with the base", "",
  Links.safeUrl("https://nas.example.com.comevil.test/x", base));
check("the userinfo form", "", Links.safeUrl("https://nas.example.com@evil.test", base));

test_case("safeUrl rejects a missing base and a non-http scheme");

check("an empty base is no gate", "", Links.safeUrl(base + "/ui/alerts", ""));
check("a missing base is no gate", "", Links.safeUrl(base + "/ui/alerts", null));
check("a non-http scheme", "", Links.safeUrl("ftp://nas.example.com/ui", base));
check("a javascript URL", "", Links.safeUrl("javascript:alert(1)", base));
check("an empty URL", "", Links.safeUrl("", base));

test_case("view builders build under the configured base");

check("alerts", base + "/ui/alerts", Links.alertsUrl(base));
check("pools is the storage page", base + "/ui/storage", Links.poolsUrl(base));
check("system", base + "/ui/system", Links.systemUrl(base));
check("apps", base + "/ui/apps", Links.appsUrl(base));
check("shares", base + "/ui/sharing", Links.sharesUrl(base));
check("dashboard", base + "/ui/dashboard", Links.dashboardUrl(base));
check("a trailing slash is not doubled", base + "/ui/alerts", Links.alertsUrl(base + "/"));

test_case("view builders return nothing without a base");

check("alerts", "", Links.alertsUrl(""));
check("pools", "", Links.poolsUrl(""));
check("system", "", Links.systemUrl(""));
check("apps", "", Links.appsUrl(""));
check("shares", "", Links.sharesUrl(""));
check("dashboard", "", Links.dashboardUrl(""));
check("a non-http base is not a base", "", Links.alertsUrl("ftp://nas.example.com"));

console.log("\nlinks: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
