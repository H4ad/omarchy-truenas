.pragma library

// Display-only redaction for recording and screenshots. It rewrites the parsed
// state and config objects before the bar, menu and panel render them, and
// touches nothing on disk: the credentials file and every state file keep the
// real values. `.pragma library` gives every importer the same code, and every
// function here is pure, so each importer computes the same pseudonym for the
// same real value without sharing any state.
//
// The replacement is a stable pseudonym, not a blank: the same hostname always
// becomes the same fake hostname, so a recording stays readable and two rows
// that shared a pool still visibly share it. The mapping is a hash of the real
// value, so it survives a reload and never depends on first-seen order.

var LEVELS = ["off", "network", "names", "all"];

// The whole free-form string at the strictest level. Prose can name anything the
// field list does not know about, so it is hidden rather than substituted.
var HIDDEN_TEXT = "hidden for recording";

function normalize(level) {
  var value = String(level === undefined || level === null ? "" : level).toLowerCase();
  for (var i = 0; i < LEVELS.length; i++) if (LEVELS[i] === value) return value;
  return "off";
}

function rank(level) {
  var value = normalize(level);
  for (var i = 0; i < LEVELS.length; i++) if (LEVELS[i] === value) return i;
  return 0;
}

function isOn(level) { return rank(level) > 0; }

function describe(level) {
  switch (normalize(level)) {
    case "network": return "addresses, hostnames and the base URL are hidden";
    case "names":   return "network, plus pools, datasets, shares, apps, disks, interfaces and tasks";
    case "all":     return "everything, including the version and free-form alert text";
    default:        return "nothing is hidden";
  }
}

// ------------------------------------------------------------- pseudonyms

// FNV-1a, 32-bit. Chosen for being short, dependency-free and stable across
// engines; nothing here is a security boundary, so a hash collision only means
// two different real names read as the same fake one.
function hash(value) {
  var text = String(value);
  var h = 0x811c9dc5;
  for (var i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h >>> 0;
}

function code(value, length) {
  var text = hash(value).toString(36);
  while (text.length < length) text = "0" + text;
  return text.slice(0, length);
}

function hostName(value) { return "nas-" + code(value, 4); }

// An address keeps its shape and its CIDR suffix, so "192.168.1.5/24" reads as
// an address in a prefix, not as a word. The IPv4 block is TEST-NET-1, reserved
// for documentation, so a fake address can never collide with a real host.
function ipName(value) {
  var text = String(value);
  var suffix = "";
  var slash = text.indexOf("/");
  if (slash !== -1) {
    suffix = text.slice(slash);
    text = text.slice(0, slash);
  }
  if (text.indexOf(":") !== -1) return "2001:db8::" + code(text, 4) + suffix;
  return "192.0.2." + (hash(text) % 254 + 1) + suffix;
}

function itemName(value) { return "item-" + code(value, 5); }
function modelName(value) { return "model-" + code(value, 4); }
function serviceName(value) { return "service-" + code(value, 4); }
function versionName() { return "x.y.z"; }

// A path is redacted component by component, so a dataset under a pool keeps
// showing the same pool token the pool row uses.
function pathName(value) {
  var parts = String(value).split("/");
  var out = [];
  for (var i = 0; i < parts.length; i++) {
    out.push(parts[i] === "" ? "" : itemName(parts[i]));
  }
  return out.join("/");
}

function snapshotName(value) {
  var text = String(value);
  var at = text.indexOf("@");
  if (at === -1) return pathName(text);
  return pathName(text.slice(0, at)) + "@" + itemName(text.slice(at + 1));
}

function pseudonym(kind, value) {
  switch (kind) {
    case "host":     return hostName(value);
    case "ip":       return ipName(value);
    case "path":     return pathName(value);
    case "snapshot": return snapshotName(value);
    case "model":    return modelName(value);
    case "service":  return serviceName(value);
    case "version":  return versionName(value);
    default:         return itemName(value);
  }
}

// -------------------------------------------------------------- the field map

// Which field names are identifying, by the name alone rather than by section,
// so a new section is covered the moment it reuses one of these keys. `error`
// is deliberately absent: it is a code the UI matches on, not prose.
function kindFor(key) {
  switch (key) {
    case "hostname":
    case "node":           return "host";
    case "address":        return "ip";
    case "path":
    case "dataset":
    case "targetDataset":
    case "sourceDatasets": return "path";
    case "lastSnapshot":   return "snapshot";
    case "name":
    case "pool":
    case "alias":
    case "title":          return "name";
    case "model":          return "model";
    case "service":        return "service";
    case "version":        return "version";
    case "text":
    case "formatted":
    case "message":
    case "description":    return "text";
    default:               return "";
  }
}

// The level at which a kind starts being hidden.
function gate(kind) {
  switch (kind) {
    case "host":
    case "ip":      return 1;
    case "name":
    case "path":
    case "snapshot":
    case "model":   return 2;
    case "service":
    case "version": return 3;
    default:        return 0;
  }
}

function isList(value) {
  return !!value && typeof value !== "string" && typeof value.length === "number";
}

// Every real value hidden at this level, mapped to its pseudonym, so the same
// value inside free-form prose can be substituted. Path components are added
// too, because an alert names a pool or a dataset, never the whole path.
function collect(node, level, map) {
  if (!node || typeof node !== "object") return map;
  if (isList(node)) {
    for (var i = 0; i < node.length; i++) collect(node[i], level, map);
    return map;
  }
  for (var key in node) {
    var value = node[key];
    var kind = kindFor(key);
    if (kind !== "" && kind !== "text") {
      var need = gate(kind);
      if (level >= need) {
        if (typeof value === "string") addValue(map, kind, value);
        else if (isList(value)) {
          for (var j = 0; j < value.length; j++)
            if (typeof value[j] === "string") addValue(map, kind, value[j]);
        }
      }
    }
    if (value && typeof value === "object") collect(value, level, map);
  }
  return map;
}

function addValue(map, kind, value) {
  if (value === "") return;
  map[value] = pseudonym(kind, value);
  if (kind === "path" || kind === "snapshot") {
    var parts = String(value).replace(/@/g, "/").split("/");
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] !== "" && map[parts[i]] === undefined) map[parts[i]] = itemName(parts[i]);
    }
  }
}

function substitute(text, map) {
  var out = String(text);
  var keys = [];
  for (var key in map) keys.push(key);
  // Longest first: replacing "storage" before "storage/media" would leave a
  // half-token behind.
  keys.sort(function (a, b) { return b.length - a.length; });
  for (var i = 0; i < keys.length; i++) {
    if (keys[i] === "") continue;
    out = out.split(keys[i]).join(map[keys[i]]);
  }
  return out;
}

function walk(node, level, map) {
  if (node === null || node === undefined) return node;
  if (isList(node)) {
    var list = [];
    for (var i = 0; i < node.length; i++) list.push(walk(node[i], level, map));
    return list;
  }
  if (typeof node !== "object") return node;
  var out = {};
  for (var key in node) {
    var value = node[key];
    var kind = kindFor(key);
    if (kind === "text") {
      if (level >= 3) out[key] = value === "" ? "" : HIDDEN_TEXT;
      else if (typeof value === "string") out[key] = substitute(value, map);
      else out[key] = value;
      continue;
    }
    var need = gate(kind);
    if (kind !== "" && level >= need) {
      if (typeof value === "string") { out[key] = pseudonym(kind, value); continue; }
      if (isList(value)) {
        var items = [];
        for (var j = 0; j < value.length; j++) {
          items.push(typeof value[j] === "string" ? pseudonym(kind, value[j]) : walk(value[j], level, map));
        }
        out[key] = items;
        continue;
      }
    }
    out[key] = walk(value, level, map);
  }
  return out;
}

// Returns a redacted copy of a parsed state.json. The input is never mutated,
// and "off" returns it untouched so the common path allocates nothing.
function apply(state, level) {
  var r = rank(level);
  if (r === 0 || !state || typeof state !== "object") return state;
  return walk(state, r, collect(state, r, {}));
}

// A base URL, or any host, redacted for display. The scheme, the userinfo, the
// port and the path survive, so the shape still reads as a URL. Callers keep the
// real URL for building links; only the printed copy goes through here.
function redactUrl(value) {
  var text = String(value);
  var match = /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^\/?#]*)([\s\S]*)$/.exec(text);
  if (!match) return hostName(text);
  var authority = match[2];
  var userinfo = "";
  var at = authority.indexOf("@");
  if (at !== -1) {
    userinfo = authority.slice(0, at + 1);
    authority = authority.slice(at + 1);
  }
  var host = authority;
  var port = "";
  if (authority.charAt(0) === "[") {
    // A bracketed IPv6 authority keeps its brackets, so the URL stays parseable.
    var close = authority.indexOf("]");
    if (close !== -1) {
      host = authority.slice(0, close + 1);
      port = authority.slice(close + 1);
    }
  } else {
    var colon = authority.lastIndexOf(":");
    if (colon !== -1) {
      port = authority.slice(colon);
      host = authority.slice(0, colon);
    }
  }
  var fake = host.charAt(0) === "["
    ? "[" + ipName(host.slice(1, -1)) + "]"
    : hostName(host);
  return match[1] + userinfo + fake + port + match[3];
}

function url(value, level) {
  return rank(level) === 0 ? String(value) : redactUrl(value);
}

// A copy of a parsed config document with its base URL redacted. Both shapes are
// handled: config.json's `instances` array and `truenasctl config list`'s single
// `instance`. The real document stays for building links.
function applyConfig(doc, level) {
  if (rank(level) === 0 || !doc || typeof doc !== "object") return doc;
  var out = {};
  for (var key in doc) out[key] = doc[key];
  if (out.instance && typeof out.instance === "object") {
    var one = {};
    for (var a in out.instance) one[a] = out.instance[a];
    if (typeof one.baseUrl === "string") one.baseUrl = redactUrl(one.baseUrl);
    out.instance = one;
  }
  if (isList(out.instances)) {
    var many = [];
    for (var i = 0; i < out.instances.length; i++) {
      var item = out.instances[i];
      if (item && typeof item === "object") {
        var copy = {};
        for (var b in item) copy[b] = item[b];
        if (typeof copy.baseUrl === "string") copy.baseUrl = redactUrl(copy.baseUrl);
        many.push(copy);
      } else {
        many.push(item);
      }
    }
    out.instances = many;
  }
  return out;
}
