# TrueNAS for Omarchy

TrueNAS pool health and capacity, active alerts and system state on the Omarchy
bar, with desktop notifications when something degrades and a popout for pools,
alerts and system detail.

![The TrueNAS bar item and Health popout](preview.png)

Verified against a live TrueNAS 25.10.6 (two pools, real alert levels, the
self-signed certificate handled through `insecureTLS`).

Run `truenasctl login` once to point the plugin at your NAS and store the API
key at mode 600. After that the bar and popout read the state the poller writes.
The API notes are in [docs/02-truenas-api.md](docs/02-truenas-api.md), what ships
and what does not in [docs/03-features.md](docs/03-features.md), and the traps
that have already cost time in [docs/11-pitfalls.md](docs/11-pitfalls.md); read
the pitfalls before changing anything, most of them fail silently.

**Planned:** shares and network are a later milestone and are not implemented
yet.
