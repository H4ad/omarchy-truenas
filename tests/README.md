# Tests

```bash
./tests/run.sh
```

No network, no desktop, no bats. `tests/stubs/` shadows `curl` and
`omarchy-notification-send` on `PATH`, `tests/fixtures/` holds the canned
responses, and every case runs the real `bin/truenas-poll`.

## Adding tests

`run.sh` sources `lib.sh` and then every file in `cases/` in name order, into the
same shell, which is how they share the pass and fail counters. A case file holds
`test_case` blocks and nothing else. Helpers belong in `lib.sh`.

One file per task, so two tasks landing at once never edit the same file.

The node suites (`model.mjs`, `search.mjs`, `bar-variants.mjs`, `links.mjs`) are
named in `run.sh`; a suite whose file is missing is a failure, not a skip. They
have to stay loadable by QML, so they are plain scripts rather than modules:
`.pragma` and `.import` lines are stripped before the file is evaluated.

`setup` writes the credentials file at mode 600 and points `XDG_STATE_HOME` at
the temp workspace, so a case can assert the isolation rather than assume it.
