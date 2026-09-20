# Migrating off the deprecated REST API

Scope and step order for moving the plugin from REST `/api/v2.0` to the
JSON-RPC 2.0 API over WebSocket at `/api/current`, and for dropping the REST
path once that is done. This is a plan, not a report: nothing here has been
measured live yet except where it cites `docs/02-truenas-api.md`.

## When this matters

REST was deprecated in TrueNAS 25.04 and is removed in TrueNAS 26. The plugin
pins 25.10, so nothing forces the move today. The trigger is a 26 release
candidate, or a decision to remove REST regardless. Until then the seam below
keeps the cost contained, and the `1.0.0` question in
[plans/2026-09-14-truenas-milestone-6.md](plans/2026-09-14-truenas-milestone-6.md)
stays open.

## The seam today

Every request goes through one helper, so the transport change is small:

- `tn_http_request` / `tn_http_get`, `bin/truenas-lib.sh:257` and `:290`.
- `tn_dialect`, `bin/truenas-lib.sh:252`, hardcoded to `rest-v2.0`.
- `tn_classify`, `bin/truenas-lib.sh:294`, maps HTTP status and curl exit codes.
- `tn_error_message`, `bin/truenas-lib.sh:336`, reads the REST error bodies.
- Consumers: `bin/truenas-poll` (`fetch`, `:255`), `bin/truenas-api`
  (`:125`, `:127`), `bin/truenasctl:227`.

The design claim that the migration is "a change to one function"
(`plans/2026-09-13-truenas-plugin-design.md:70`) holds for the transport. It does
not hold for the operation map, the error model, or the test harness, which are
the three work items below.

## Operations to map

15 read paths in `bin/truenas-poll` and 12 write verbs in `bin/truenas-api`. The
JSON-RPC method names are confirmed for milestone 1 in `docs/02-truenas-api.md`
(`system.info`, `alert.list`, `pool.query`, `alert.dismiss`, `alert.restore`).
The rest follow the same namespace pattern but must be confirmed against a live
`/api/current` before they are written down as fact. No table of guesses belongs
in `docs/02`.

Shape changes to expect, from the REST quirks already recorded:

- Path parameters move into the params object: `cloudsync/id/{id}/sync` and
  `pool/snapshottask/id/{id}/run` become `{id}` in params.
- `replication/run` sends a bare integer today; JSON-RPC params are an object or
  an array, so confirm which one it accepts.
- The POST-only disk routes keep their shapes: `{name:[...]}` for temperatures,
  `{type:"USED"}` for details.
- App writes return a job id and run async. WebSocket has job events and
  `core.get_jobs`; the poll does not need them, but the option is there.

## The blocker: a WebSocket client

This is the reason WS-only was rejected up front
(`plans/2026-09-13-truenas-plugin-design.md:75`). The plugin needs only `curl`
and `jq` today. WebSocket needs a client that is not on the desktop by default:
`websocat` and `wscat` are not installed here, and neither Python `websockets`
nor `websocket-client` is present.

Pick one and record the decision before writing transport code:

1. Bundle a static `websocat` binary with the plugin. No runtime package
   dependency, but a binary to ship and trust.
2. Depend on a Python WebSocket library. Small wrapper, but a pip dependency on
   an Omarchy box.
3. A small Node helper, since `node` is already on this machine. Same shipping
   question.

Whichever it is, the helper must own the connection and speak one call in, one
JSON response out, so the shell side stays a function call. Keep the API key out
of argv, the way `tn_http_request` does today.

## Connection lifecycle

REST is stateless per call. WebSocket is one session: handshake, auth
(`auth.login_with_api_key`, or the key on the handshake, to be measured), call
ids, response correlation, event frames, teardown. A poll is a short-lived
process that issues 15 reads, so the natural shape is one connection per poll
that runs the reads back to back and closes, not a resident daemon. A cold poll
also becomes one handshake and one auth instead of 15 stateless requests, which
relieves the rate limit in `docs/11-pitfalls.md:691`.

## Error model

`tn_classify` reads `401`, `403`, `404`, `5xx` and curl exit codes. JSON-RPC has
no per-call HTTP status and reports errors as codes in the response. Map them
once, in the same place, and keep the stable vocabulary the views consume
(`unauthenticated`, `forbidden`, `not_found`, `server_error`, `timeout`,
`unreachable`). `expect_shape` and the per-section `shape` cases
(`bin/truenas-poll:269`) do not change: a 200 is still not success until the body
has the promised shape, and that check moves to the JSON-RPC result.

`tn_dialect` becomes a real probe: try `/api/current`, fall back to
`rest-v2.0`, and record the result in `state.connection.dialect`. The Health tab
already reads that field.

## Test harness

The largest piece of work, and the one the "one function" claim misses.
`tests/stubs/curl` fakes REST by matching `/api/v2.0/...` paths, and six case
files drive it:

| Case | Size |
| --- | --- |
| `tests/cases/10-poll.sh` | 41K |
| `tests/cases/11-notify.sh` | 49K |
| `tests/cases/12-config.sh` | 8.5K |
| `tests/cases/13-meta.sh` | 31K |
| `tests/cases/14-ctl.sh` | 43K |
| `tests/cases/15-api.sh` | 16K |

The stub boundary moves. Either stub the new WebSocket helper and re-express
each expected call as a JSON-RPC request, or keep `curl` and route the helper
through it. The first is honest; the second keeps a fake alive. Budget more time
here than for the transport and the operation map combined.

## Step order

1. Spike. Stand up the chosen WS client on the desktop against the live NAS.
   Prove auth, one read (`system.info`) and one write (`alert.dismiss`). Record
   the exact handshake and params shapes in `docs/02-truenas-api.md`. This
   settles the dependency and the method map before any real edit.
2. Transport. Add the WS call path behind `tn_http_request`'s name, or beside it,
   so call sites do not change until the map does.
3. Error model. Rewrite `tn_classify` and `tn_error_message` for JSON-RPC, keep
   the vocabulary.
4. Operation map. Move the 15 reads and 12 writes, verifying each against the
   live box, including the quirk list above.
5. Dialect probe. Make `tn_dialect` real and keep the REST fallback.
6. Tests. Migrate the harness.
7. Remove REST. Only once every section is confirmed on `/api/current`: delete
   the fallback, the REST paths, the `curl` stub and the `rest-v2.0` branch.
8. Docs. Update `docs/02-truenas-api.md`, `docs/11-pitfalls.md:677`,
   `README.md:83` and this file.

## Acceptance

Every read and write answers over `/api/current`, `state.connection.dialect`
reports the generation used, the full shell suite and the node suites are green,
and `truenasctl test` passes against the live 25.10 box. REST is removed only
after all of that.

## Risks

- A WS client dependency on a desktop that has none today. Resolve it in the
  spike, not in the transport code.
- Auth over the handshake versus `auth.login_with_api_key` is unmeasured. A
  wrong guess is a 401 on every call.
- Async jobs behave differently over WS (events versus a job id). The poll reads
  back rather than trusting the write, so this is a watch item, not a redesign.
- The test rewrite is where the schedule slips. Treat the six case files as the
  estimate, not the endpoint count.
