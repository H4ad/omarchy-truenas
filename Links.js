.pragma library

// Link builders into the TrueNAS UI. Every URL is built from the configured
// base, and any URL that arrives from somewhere else is admitted only by
// safeUrl, so a link can never leave the NAS it came from.
//
// TrueNAS SCALE 25.04 (Fangtooth) serves the app under /ui. Routes checked
// against the webui source at tag TS-25.04.2 (src/app/admin.routes.ts):
//   dashboard -> /ui/dashboard
//   system    -> /ui/system
//   storage   -> /ui/storage   (the Pools page)
//   apps      -> /ui/apps
//   sharing   -> /ui/sharing   (the page titled "Shares")
// Alerts are not a route in 25.04: the topbar bell opens a panel over whatever
// page is showing. /ui/alerts is the path the design named; it lands on the
// dashboard, which is where the bell lives.
var UI_ROUTES = {
  alerts: "/ui/alerts",
  storage: "/ui/storage",
  system: "/ui/system",
  apps: "/ui/apps",
  shares: "/ui/sharing",
  dashboard: "/ui/dashboard"
};

function text(value) {
  return value === null || value === undefined ? "" : String(value);
}

// The configured base with trailing slashes gone, or "" when there is nothing
// usable to build on. A base that is not http(s) cannot be an origin we open
// links in.
function baseUrl(value) {
  var base = text(value).replace(/\/+$/, "");
  if (base === "" || !/^https?:\/\//.test(base)) return "";
  return base;
}

// The origin gate. Accepts a URL only when it is http(s) and the first
// character after the base is the end of the string or a separator, so a host
// that merely starts with the base host (nas.example.com.attacker.test) or
// hides one in userinfo (nas.example.com@evil.test) is rejected. An empty base
// is no gate at all, so it is never a pass.
function safeUrl(url, baseValue) {
  var base = baseUrl(baseValue);
  var candidate = text(url);
  if (base === "" || candidate === "") return "";
  if (!/^https?:\/\//.test(candidate)) return "";
  if (candidate.indexOf(base) !== 0) return "";
  var next = candidate.charAt(base.length);
  if (next !== "" && next !== "/" && next !== "?" && next !== "#") return "";
  return candidate;
}

function viewUrl(value, path) {
  var base = baseUrl(value);
  if (base === "") return "";
  return base + path;
}

function alertsUrl(value) {
  return viewUrl(value, UI_ROUTES.alerts);
}

function poolsUrl(value) {
  return viewUrl(value, UI_ROUTES.storage);
}

function systemUrl(value) {
  return viewUrl(value, UI_ROUTES.system);
}

function appsUrl(value) {
  return viewUrl(value, UI_ROUTES.apps);
}

function sharesUrl(value) {
  return viewUrl(value, UI_ROUTES.shares);
}

function dashboardUrl(value) {
  return viewUrl(value, UI_ROUTES.dashboard);
}
