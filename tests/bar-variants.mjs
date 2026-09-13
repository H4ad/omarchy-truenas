// Runs BarVariants.js under node. Like Model.js it has to stay loadable by QML
// as `import "BarVariants.js" as BarVariants`, so it is not a module: it is read
// and evaluated here, and its top-level declarations are collected into one
// object. The loader is the one tests/links.mjs uses.
//
// This suite deliberately loads BarVariants.js and nothing else. The file is
// standalone by contract: a value it prints arrives in `view`, never pulled out
// of Model.js, so a break in Model.js cannot make these assertions pass.
//
//   node tests/bar-variants.mjs
//
// Prints one line per assertion, in the shape tests/lib.sh's `check` prints, and
// exits non-zero if any of them failed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

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

function evaluated(file) {
  // `.pragma library` and `.import` are QML script directives, not JavaScript,
  // so they come off before node parses the file.
  const source = readFileSync(join(root, file), "utf8")
    .replace(/^\.(pragma|import)\b.*$/gm, "");
  const exports = declaredNames(source)
    .map(function (name) { return name + ": " + name; })
    .join(", ");
  return new Function(source + "\nreturn { " + exports + " };")();
}

const BarVariants = evaluated("BarVariants.js");

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

// The widget owns the glyph set. "G" is the normal glyph, "P" the plug an
// unreachable NAS gets, "C" the cog an unconfigured one gets.
const GLYPHS = { main: "G", offline: "P", unconfigured: "C" };

// The `view` contract, with every field so a test only names the ones it reads.
function view(extra) {
  const base = {
    mode: "quiet",
    alertCount: 0,
    capacityText: "",
    worstPool: "",
    worstLevel: "",
    degraded: false
  };
  for (const key in (extra || {})) base[key] = extra[key];
  return base;
}

function segmentsFor(variant, v, glyphs) {
  return BarVariants.segmentsFor(variant, v, glyphs === undefined ? GLYPHS : glyphs);
}

function render(variant, v, glyphs) {
  return BarVariants.textFor(segmentsFor(variant, v, glyphs));
}

function severities(variant, v) {
  return segmentsFor(variant, v).map(function (segment) { return segment.severity; });
}

// ------------------------------------------------------------------ the settings

test_case("the six variants");
check("the manifest order", ["Default", "Icon", "Alerts", "Capacity", "Pool", "Full"],
  BarVariants.VARIANTS);
check("Default is the built-in fallback", "Default", BarVariants.DEFAULT_VARIANT);

test_case("resolveVariant");
check("the manifest spelling is pinned", "Alerts", BarVariants.resolveVariant("Alerts"));
check("case does not matter", "Capacity", BarVariants.resolveVariant("capacity"));
check("an upper-case spelling is still canonical", "Full", BarVariants.resolveVariant("FULL"));
check("Default stays Default", "Default", BarVariants.resolveVariant("Default"));
check("an empty setting is Default", "Default", BarVariants.resolveVariant(""));
check("nothing at all is Default", "Default", BarVariants.resolveVariant(null));
check("undefined too", "Default", BarVariants.resolveVariant(undefined));
check("a singular typo is Default", "Default", BarVariants.resolveVariant("Alert"));
check("a variant nobody implemented is Default", "Default", BarVariants.resolveVariant("Sparkline"));
check("whitespace is not a variant", "Default", BarVariants.resolveVariant(" Alerts "));
BarVariants.VARIANTS.forEach(function (variant) {
  check(variant + " resolves to itself, never widened", variant, BarVariants.resolveVariant(variant));
});

// --------------------------------------------------------- the modes that override

test_case("offline overrides every variant");
BarVariants.VARIANTS.forEach(function (variant) {
  const segs = segmentsFor(variant, view({
    mode: "offline", alertCount: 7, capacityText: "88%",
    worstPool: "DEGRADED", worstLevel: "critical", degraded: true
  }));
  const text = BarVariants.textFor(segs);
  check(variant + " shows the plug glyph", true, text.indexOf("P") !== -1);
  check(variant + " prints no number", false, /[0-9]/.test(text));
  check(variant + " prints no capacity", false, text.indexOf("88") !== -1);
  check(variant + " is exactly one segment", 1, segs.length);
});

test_case("unconfigured overrides every variant");
BarVariants.VARIANTS.forEach(function (variant) {
  const segs = segmentsFor(variant, view({
    mode: "unconfigured", alertCount: 7, capacityText: "88%",
    worstPool: "DEGRADED", worstLevel: "critical", degraded: true
  }));
  const text = BarVariants.textFor(segs);
  check(variant + " shows the cog glyph", true, text.indexOf("C") !== -1);
  check(variant + " prints no number", false, /[0-9]/.test(text));
  check(variant + " is exactly one segment", 1, segs.length);
});

test_case("the override glyph falls back when a set leaves one out");
check("offline falls back to the main glyph", "G",
  BarVariants.textFor(segmentsFor("Full", view({ mode: "offline" }), { main: "G" })));
check("unconfigured falls back to the plug", "P",
  BarVariants.textFor(segmentsFor("Full", view({ mode: "unconfigured" }), { main: "G", offline: "P" })));
check("no glyph set at all is still one empty segment", "",
  BarVariants.textFor(segmentsFor("Full", view({ mode: "offline" }), {})));

// -------------------------------------------------------------------- Default

test_case("Default shows the alert count when firing");
check("an alert count carries the bar", "G 5",
  render("Default", view({ mode: "firing", alertCount: 5, capacityText: "71%", worstLevel: "critical" })));
check("the count takes the worst level", ["", "critical"],
  severities("Default", view({ mode: "firing", alertCount: 5, worstLevel: "critical" })));
check("a degraded mode shows the alerts too", "G 3",
  render("Default", view({ mode: "degraded", alertCount: 3, capacityText: "71%", worstLevel: "warning" })));

test_case("Default shows capacity when quiet");
check("the fullest pool's capacity", "G 71%",
  render("Default", view({ mode: "quiet", capacityText: "71%", worstLevel: "" })));
check("a degraded pool with no alerts still says capacity", "G 71%",
  render("Default", view({ mode: "quiet", degraded: true, capacityText: "71%", worstLevel: "warning" })));
check("no capacity and no alerts is the glyph alone", "G",
  render("Default", view({ mode: "quiet" })));

// ----------------------------------------------------------------------- Icon

test_case("Icon is the glyph, tinted by the worst state");
check("a quietly healthy icon", "G", render("Icon", view({ mode: "quiet", capacityText: "71%" })));
check("a firing icon is still one glyph", "G",
  render("Icon", view({ mode: "firing", alertCount: 9, capacityText: "71%" })));
check("the tint is the worst level", ["warning"],
  severities("Icon", view({ mode: "degraded", worstLevel: "warning" })));
check("a healthy icon is untinted", [""],
  severities("Icon", view({ mode: "quiet" })));

// --------------------------------------------------------------------- Alerts

test_case("Alerts is the active count");
check("a firing count", "G 5",
  render("Alerts", view({ mode: "firing", alertCount: 5, worstLevel: "critical" })));
check("the count carries the worst level", ["", "critical"],
  severities("Alerts", view({ mode: "firing", alertCount: 5, worstLevel: "critical" })));

test_case("Alerts at zero renders nothing, not the string zero");
// A successful poll with no alerts spends no bar slot on the absence. A genuine
// zero is a real measurement, but it is the same measurement as "nothing to
// say", so the count is dropped rather than printed as "0".
check("no count segment", "G", render("Alerts", view({ mode: "quiet", alertCount: 0 })));
check("there is no digit in the render", false,
  /[0-9]/.test(render("Alerts", view({ mode: "quiet", alertCount: 0 }))));
check("exactly the glyph survives", 1,
  segmentsFor("Alerts", view({ mode: "quiet", alertCount: 0 })).length);
check("a string zero is not a count either", "G",
  render("Alerts", view({ mode: "quiet", alertCount: "0" })));
check("a missing count is not a crash", "G",
  render("Alerts", view({ mode: "quiet", alertCount: null })));
check("a negative count is not printed", "G",
  render("Alerts", view({ mode: "quiet", alertCount: -1 })));

// ------------------------------------------------------------------- Capacity

test_case("Capacity is the fullest pool");
check("a known capacity", "G 71%",
  render("Capacity", view({ mode: "quiet", capacityText: "71%", worstLevel: "warning" })));
check("the capacity carries the worst level", ["", "warning"],
  severities("Capacity", view({ mode: "quiet", capacityText: "71%", worstLevel: "warning" })));

test_case("Capacity with nothing known prints nothing, never 0%");
check("an empty capacity", "G",
  render("Capacity", view({ mode: "quiet", capacityText: "" })));
check("a null capacity", "G",
  render("Capacity", view({ mode: "quiet", capacityText: null })));
check("a missing capacity", "G",
  render("Capacity", view({ mode: "quiet" })));
check("and never a fake zero percent", false,
  /0%/.test(render("Capacity", view({ mode: "quiet", capacityText: "" }))));
check("exactly the glyph survives", 1,
  segmentsFor("Capacity", view({ mode: "quiet", capacityText: "" })).length);

// ----------------------------------------------------------------------- Pool

test_case("Pool is the worst status word");
check("a degraded pool", "G DEGRADED",
  render("Pool", view({ mode: "degraded", worstPool: "DEGRADED", worstLevel: "warning" })));
check("the word carries the worst level", ["", "warning"],
  severities("Pool", view({ mode: "degraded", worstPool: "DEGRADED", worstLevel: "warning" })));
check("no pool prints nothing", "G",
  render("Pool", view({ mode: "quiet", worstPool: "" })));
check("a null pool prints nothing", "G",
  render("Pool", view({ mode: "quiet", worstPool: null })));

// ----------------------------------------------------------------------- Full

test_case("Full is alerts and capacity");
check("both halves, in order", "G 3 · 71%",
  render("Full", view({ mode: "firing", alertCount: 3, capacityText: "71%", worstLevel: "warning" })));

test_case("Full drops an unknown half");
check("no alerts drops the first half", "G 71%",
  render("Full", view({ mode: "quiet", alertCount: 0, capacityText: "71%" })));
check("no capacity drops the second half", "G 3",
  render("Full", view({ mode: "firing", alertCount: 3, capacityText: "" })));
check("neither half leaves the glyph alone", "G",
  render("Full", view({ mode: "quiet", alertCount: 0, capacityText: "" })));
check("an unknown capacity is never half a zero", false,
  /0%/.test(render("Full", view({ mode: "firing", alertCount: 3, capacityText: "" }))));

// -------------------------------------------------------------------- textFor

test_case("textFor");
check("segments are joined with one space", "a b",
  BarVariants.textFor([{ text: "a", severity: "" }, { text: "b", severity: "critical" }]));
check("an empty segment does not leave a double space", "a b",
  BarVariants.textFor([{ text: "a" }, { text: "" }, { text: "b" }]));
check("no segments, no text", "", BarVariants.textFor([]));
check("a null list", "", BarVariants.textFor(null));

// --------------------------------------------------------------- isMultiColour

test_case("isMultiColour needs more than one distinct severity");
check("critical beside warning is two colours", true,
  BarVariants.isMultiColour([{ text: "3", severity: "critical" }, { text: "71%", severity: "warning" }]));
check("one severity repeated is one colour", false,
  BarVariants.isMultiColour([{ text: "3", severity: "critical" }, { text: "5", severity: "critical" }]));
check("one severity beside the untinted glyph is one colour", false,
  BarVariants.isMultiColour([{ text: "G", severity: "" }, { text: "3", severity: "critical" }]));
check("nothing tinted is one colour", false,
  BarVariants.isMultiColour([{ text: "G", severity: "" }]));
check("no segments at all", false, BarVariants.isMultiColour([]));
check("a null list", false, BarVariants.isMultiColour(null));

// ------------------------------------------------------------- the segment shape

test_case("every segment is { text, severity } with a known severity");
const KNOWN = ["critical", "error", "warning", "notice", "info", ""];
const samples = [];
BarVariants.VARIANTS.forEach(function (variant) {
  samples.push(segmentsFor(variant, view({
    mode: "firing", alertCount: 4, capacityText: "71%",
    worstPool: "DEGRADED", worstLevel: "warning"
  })));
});
samples.push(segmentsFor("Full", view({ mode: "offline" })));
samples.push(segmentsFor("Full", view({ mode: "unconfigured" })));
const flat = samples.reduce(function (all, list) { return all.concat(list); }, []);
check("no severity is outside the documented set", [],
  flat.map(function (segment) { return segment.severity; })
    .filter(function (severity) { return KNOWN.indexOf(severity) === -1; }));
check("no text is anything but a string", [],
  flat.map(function (segment) { return segment.text; })
    .filter(function (text) { return typeof text !== "string"; }));
check("every segment has both keys", [],
  flat.filter(function (segment) {
    return !Object.prototype.hasOwnProperty.call(segment, "text")
      || !Object.prototype.hasOwnProperty.call(segment, "severity");
  }));

test_case("an empty view does not throw");
check("no view prints the glyph", "G", render("Default", null));
check("no glyphs prints no glyph", "5",
  render("Alerts", view({ mode: "firing", alertCount: 5, worstLevel: "critical" }), {}));

test_case("the file stands alone");
// BarVariants.js reads only what the caller hands it. Reaching into Model.js
// would make a bar that is right while the model is right, and silently wrong
// the moment Model changes shape. The comments may say the name; the code may
// not use it.
const barCode = readFileSync(join(root, "BarVariants.js"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/\/\/.*$/gm, "");
check("BarVariants.js never uses Model in code", false, /\bModel\b/.test(barCode));
check("the suite loads BarVariants.js and nothing else", false,
  /evaluated\(\s*"Model\.js"\s*\)/.test(readFileSync(fileURLToPath(import.meta.url), "utf8")));

console.log("\nbar variants: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
