.pragma library

// List filtering for the panel's alert, pool and disk rows. Pure functions only: no
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

// A disk matches on its device name, its model, its type, the pool it belongs
// to and its bus. Empty fields never match a non-empty needle, so a row the
// poller could not describe is only ever reached by the empty needle.
function disks(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var disk = items[i];
    if (!disk || typeof disk !== "object") continue;
    if (contains(disk.name, needle)
        || contains(disk.model, needle)
        || contains(disk.type, needle)
        || contains(disk.pool, needle)
        || contains(disk.bus, needle)) {
      out.push(disk);
    }
  }
  return out;
}

// A service matches on its name, its state and its id. The id is a number on
// the wire and contains stringifies it, so a search for "4" finds it.
function services(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var service = items[i];
    if (!service || typeof service !== "object") continue;
    if (contains(service.service, needle)
        || contains(service.state, needle)
        || contains(service.id, needle)) {
      out.push(service);
    }
  }
  return out;
}

// An app matches on its name, title, state, train, appVersion and version.
// Empty fields never match a non-empty needle, so a row the poller could not
// describe is only ever reached by the empty needle.
function apps(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var app = items[i];
    if (!app || typeof app !== "object") continue;
    if (contains(app.name, needle)
        || contains(app.title, needle)
        || contains(app.state, needle)
        || contains(app.train, needle)
        || contains(app.appVersion, needle)
        || contains(app.version, needle)) {
      out.push(app);
    }
  }
  return out;
}

// A replication task matches on its name, direction, transport, target dataset
// and either the task state or the job state. The nested state and job are
// guarded, so a row whose job is null still matches on the task state.
function replication(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var task = items[i];
    if (!task || typeof task !== "object") continue;
    if (contains(task.name, needle)
        || contains(task.direction, needle)
        || contains(task.transport, needle)
        || contains(task.targetDataset, needle)
        || contains(task.state && task.state.state, needle)
        || contains(task.job && task.job.state, needle)) {
      out.push(task);
    }
  }
  return out;
}

// A cloud sync task matches on its name, path, direction, transfer mode and job
// state.
function cloudSync(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var task = items[i];
    if (!task || typeof task !== "object") continue;
    if (contains(task.name, needle)
        || contains(task.path, needle)
        || contains(task.direction, needle)
        || contains(task.transferMode, needle)
        || contains(task.job && task.job.state, needle)) {
      out.push(task);
    }
  }
  return out;
}

// A periodic snapshot task matches on its dataset, naming schema, task state
// and last snapshot.
function snapshotTasks(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var task = items[i];
    if (!task || typeof task !== "object") continue;
    if (contains(task.dataset, needle)
        || contains(task.namingSchema, needle)
        || contains(task.state && task.state.state, needle)
        || contains(task.state && task.state.lastSnapshot, needle)) {
      out.push(task);
    }
  }
  return out;
}

// A scrub task matches on its pool name, description, threshold and enabled
// flag. The threshold is a number and contains stringifies it.
function scrubs(list, needle) {
  var items = arrayLike(list) ? list : [];
  if (text(needle) === "") return copy(items);
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var task = items[i];
    if (!task || typeof task !== "object") continue;
    if (contains(task.pool, needle)
        || contains(task.description, needle)
        || contains(task.threshold, needle)
        || contains(task.enabled, needle)) {
      out.push(task);
    }
  }
  return out;
}
