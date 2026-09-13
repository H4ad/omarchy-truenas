.pragma library

// List filtering for the panel's alert and pool rows. Pure functions only: no
// QML types, so the whole thing runs under node in tests/search.mjs. Every
// filter returns a new array and never touches the one it was given.

// Array.isArray is false for the QVariantList sequence wrapper a QML var
// property hands to a plain function, and a bare string would otherwise be
// walked one character at a time.
function arrayLike(value) {
  return !!value && typeof value !== "string" && typeof value.length === "number";
}

function text(value) {
  return value === null || value === undefined ? "" : String(value);
}

// Case-insensitive substring. A missing field is "", which never contains a
// non-empty needle; an empty needle is contained by everything, which is how an
// empty box comes to mean "no filter".
function contains(haystack, needle) {
  var search = text(needle).toLowerCase();
  if (search === "") return true;
  return text(haystack).toLowerCase().indexOf(search) !== -1;
}

function copy(list) {
  var out = [];
  if (!arrayLike(list)) return out;
  for (var i = 0; i < list.length; i++) out.push(list[i]);
  return out;
}

// An alert matches on its raw level, its short text, its formatted text and the
// node it fired on. An empty needle copies the list, so clearing the box hands
// back every row in the order the poller wrote it.
function alerts(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var alert = items[i];
    if (!alert || typeof alert !== "object") continue;
    if (contains(alert.level, needle)
        || contains(alert.text, needle)
        || contains(alert.formatted, needle)
        || contains(alert.node, needle)) {
      out.push(alert);
    }
  }
  return out;
}

// A pool matches on its name and its status.
function pools(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var pool = items[i];
    if (!pool || typeof pool !== "object") continue;
    if (contains(pool.name, needle) || contains(pool.status, needle)) out.push(pool);
  }
  return out;
}
