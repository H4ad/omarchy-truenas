# TrueNAS plugin milestone 5 recon: shares and network

Date: 2026-09-14. Live box: TrueNAS 25.10.6 at
`https://nas.example:4433`, self-signed TLS. Read-only probes.

This document records what the live API actually answers for the endpoints the
milestone-5 design names (`docs/plans/2026-09-13-truenas-plugin-design.md`, the
meta cadence list and the `shares`, `sessions` and `network` keys of
`state.json`). The design's endpoint list is a guess; this is the measurement.
Three of the named routes do not exist and are replaced.

## How this was probed

The key is read from the credentials file and passed to curl through a `--config`
document on stdin, never in argv:

```bash
KEY=$(sed -n 's/^TRUENAS_API_KEY=//p' ~/.config/omarchy/truenas/credentials)
curl -sk -o /tmp/out.json -w '%{http_code}\n' \
  --config <(printf 'header = "Authorization: Bearer %s"\n' "$KEY") \
  -H 'Content-Type: application/json' \
  https://nas.example:4433/api/v2.0/<path>
jq . /tmp/out.json
```

One shell trap hit while doing this: the process substitution has to stay inline
in the curl invocation. Storing the curl options in a bash array first closes the
`/dev/fd/*` file before curl reads it, and curl fails with
`option --config: error encountered when reading a file`. The same recipe is used
in `bin/truenas-lib.sh`, so the poller is not affected.

No share, export or interface was created, edited or deleted. The only non-GET
requests were deliberately invalid bodies on the create routes (`"x"`, `[]`) plus
`POST /smb` and `PUT /interface` with `{}`; all four were rejected before any
handler ran, which is what produced the error shapes below.

The API reference used to confirm the route names is the generated v25.10.5
reference at `https://api.truenas.com/v25.10/` (`index.html` lists every method).

## Endpoint summary

| Purpose | Method | Path | HTTP | Answer |
| --- | --- | --- | --- | --- |
| SMB shares | GET | `/api/v2.0/sharing/smb` | 200 | JSON array of share objects |
| NFS exports | GET | `/api/v2.0/sharing/nfs` | 200 | JSON array of export objects |
| iSCSI targets | GET | `/api/v2.0/iscsi/target` | 200 | JSON array (empty on this box) |
| iSCSI extents | GET | `/api/v2.0/iscsi/extent` | 200 | JSON array (empty) |
| iSCSI portals | GET | `/api/v2.0/iscsi/portal` | 200 | JSON array (empty) |
| iSCSI target-extent map | GET | `/api/v2.0/iscsi/targetextent` | 200 | JSON array (empty) |
| iSCSI initiators | GET | `/api/v2.0/iscsi/initiator` | 200 | JSON array (empty) |
| iSCSI global config | GET | `/api/v2.0/iscsi/global` | 200 | JSON object |
| SMB global config | GET | `/api/v2.0/smb` | 200 | JSON object |
| network interfaces | GET | `/api/v2.0/interface` | 200 | JSON array of interface objects |
| WebDAV shares | GET | `/api/v2.0/sharing/webdav` | 404 | `text/plain` `404: Not Found` |
| WebDAV (short name) | GET | `/api/v2.0/webdav` | 404 | `text/plain` `404: Not Found` |
| SMB status / sessions | GET | `/api/v2.0/smb/status` | 404 | `text/plain` `404: Not Found` |
| SMB sessions (guess) | GET | `/api/v2.0/smb/sessions` | 404 | `text/plain` `404: Not Found` |
| interfaces (design name) | GET | `/api/v2.0/network/interface` | 404 | `text/plain` `404: Not Found` |
| list query routes | POST | `/api/v2.0/sharing/smb/query` | 404 | `text/plain` `404: Not Found` |
| list query routes | GET | `/api/v2.0/interface/query` | 404 | `text/plain` `404: Not Found` |

Every list route above is a plain `GET` on the collection. There is no
`/query` route: a `POST` or `GET` to `/sharing/smb/query` or `/interface/query`
is `404`, matching the milestone-3 finding that `/app/query` is `404`. Filtering
is client-side, as it is for services and apps.

## Shares

### GET /api/v2.0/sharing/smb

Returns a JSON array, one object per SMB share. Three shares exist on the box
(`default`, `backup`, `media`). One row, sanitized:

```json
[
  {
    "id": 1,
    "purpose": "DEFAULT_SHARE",
    "name": "default",
    "path": "/mnt/storage/default",
    "enabled": true,
    "comment": "",
    "readonly": false,
    "browsable": true,
    "access_based_share_enumeration": false,
    "locked": false,
    "audit": { "enable": false, "watch_list": [], "ignore_list": [] },
    "options": { "aapl_name_mangling": false, "hostsallow": [], "hostsdeny": [] }
  }
]
```

Fields and types:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | Share id |
| `purpose` | string | Share preset, `DEFAULT_SHARE` here. The preset list comes from `sharing.smb.presets`; only `DEFAULT_SHARE` was observed |
| `name` | string | Share name, unique |
| `path` | string | Dataset path, e.g. `/mnt/storage/default` |
| `enabled` | boolean | Admin on/off toggle |
| `comment` | string | Free text, often empty |
| `readonly` | boolean | Read-only flag |
| `browsable` | boolean | Appears in browse lists |
| `access_based_share_enumeration` | boolean | ABE |
| `locked` | boolean | True when the backing dataset is locked (encrypted and not unlocked); independent of `enabled` |
| `audit` | object | `{enable, watch_list[], ignore_list[]}` |
| `options` | object | `{aapl_name_mangling, hostsallow[], hostsdeny[]}` |

For the Shares view, cache and display `id`, `name`, `path`, `enabled`,
`locked`, `purpose`, `comment` and `readonly`. The `audit` and `options` objects
are not needed; drop them before the meta write, following the M2/M3 rule that
the cache holds only the fields the normalizer consumes.

### GET /api/v2.0/sharing/nfs

Returns a JSON array, one object per NFS export. One export exists. Sanitized:

```json
[
  {
    "id": 1,
    "path": "/mnt/storage/default",
    "aliases": [],
    "comment": "",
    "networks": [],
    "hosts": [],
    "ro": false,
    "maproot_user": "nobody",
    "maproot_group": "nobody",
    "mapall_user": null,
    "mapall_group": null,
    "security": [],
    "enabled": true,
    "locked": false,
    "expose_snapshots": false
  }
]
```

Fields and types:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | Export id |
| `path` | string | Dataset path |
| `aliases` | array of string | Alternate names, empty by default |
| `comment` | string | Free text |
| `networks` | array of string | Allowed networks in CIDR form |
| `hosts` | array of string | Allowed hosts |
| `ro` | boolean | Read-only |
| `maproot_user` / `maproot_group` | string or null | Identity mapped for root |
| `mapall_user` / `mapall_group` | string or null | Identity all clients map to |
| `security` | array of string | Kerberos modes; empty means the service default |
| `enabled` | boolean | Admin on/off toggle |
| `locked` | boolean | Same meaning as the SMB share flag |
| `expose_snapshots` | boolean | Whether `.zfs/snapshot` is visible |

`ro` here is the read-only flag; the SMB row calls the same idea `readonly`. The
two share types do not share a field vocabulary, so the normalizer needs one
row function per type rather than a generic mapper.

### GET /api/v2.0/iscsi/target

`sharing/iscsi` does not exist. The iSCSI surface lives under `/api/v2.0/iscsi/`
and no single route is "the iSCSI shares". The five collections were probed on
this box and all are empty arrays (`[]`):

- `/iscsi/target` (the closest thing to an iSCSI share; one row per target)
- `/iscsi/extent` (the backing storage)
- `/iscsi/portal`
- `/iscsi/targetextent` (the target-to-extent map)
- `/iscsi/initiator`

So there is no live row to show. The documented `iscsi.target.query` row shape
(from `https://api.truenas.com/v25.10/api_methods_iscsi.target.query.html`) is:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | Target id |
| `name` | string | Target name, maximum 120 characters |
| `alias` | string or null | Optional alias |
| `mode` | string enum | `ISCSI`, `FC` or `BOTH`; default `ISCSI` |
| `groups` | array of object | `{portal:int, initiator:int|null, authmethod:"NONE"|"CHAP"|"CHAP_MUTUAL", auth:int|null, auth_networks:string[]}` |
| `rel_tgt_id` | integer | Relative target id assigned by the system |
| `iscsi_parameters` | object or null | Optional, `{QueuedCommands: 32|128|null}` |

A target has no `enabled` or `locked` flag in the documented schema; it exists or
it does not, and `groups` carry the auth settings. The global config at
`/iscsi/global` is one object: `{id, basename, isns_servers[], listen_port,
pool_avail_threshold, alua, iser}`. On the live box `basename` is
`iqn.2005-10.org.freenas.ctl`, `listen_port` is `3260`, and `alua` and `iser` are
false.

The count the design calls `shares.iscsi` should be `length` of
`/iscsi/target`, not a union of the five collections.

### WebDAV: no route

There is no WebDAV share endpoint on 25.10.6, and neither
`/api/v2.0/sharing/webdav` nor `/api/v2.0/webdav` exists (both `404`,
`text/plain`). The 25.10.5 API reference lists no `webdav` or `sharing.webdav`
method at all, and neither does the 25.04 reference. WebDAV is not a native share
in this generation; the release notes list WebDAV only as an application in the
catalog.

The design's `shares.webdav` key and the `webdav` count have no source and should
be dropped from `state.json` and from the milestone-5 endpoint list. This is the
same outcome as the M2 SMART decision: a feature the design assumed that the
installed API does not expose.

### SMB status and sessions: no route

`/api/v2.0/smb/status` is `404` and there is no `smb.status` or `smb.sessions`
method in the 25.10 reference. The `smb` namespace has only `smb.config`,
`smb.update`, `smb.bindip_choices` and `smb.unixcharset_choices`. The design's
`sessions.smb` list, and the live SMB session count it implies, cannot be
sourced from this API and should be dropped.

What the SMB namespace does expose is the global config at `GET /api/v2.0/smb`
(a single object, not an array). Sanitized, with `server_sid` redacted:

```json
{
  "id": 1,
  "netbiosname": "truenas",
  "netbiosalias": [],
  "workgroup": "WORKGROUP",
  "description": "TrueNAS Server",
  "enable_smb1": false,
  "unixcharset": "UTF-8",
  "localmaster": true,
  "syslog": false,
  "aapl_extensions": false,
  "admin_group": null,
  "guest": "nobody",
  "filemask": "DEFAULT",
  "dirmask": "DEFAULT",
  "ntlmv1_auth": false,
  "multichannel": false,
  "encryption": "DEFAULT",
  "bindip": [],
  "server_sid": "<redacted>",
  "smb_options": "",
  "debug": false
}
```

This is optional for M5. If the Shares view wants a header, `netbiosname`,
`workgroup` and `encryption` are the useful fields; `server_sid` and `bindip`
are not needed and should not be cached.

## Network

### GET /api/v2.0/interface

The design's `/network/interface` is `404`; the route is `/interface`. It returns
a JSON array, one object per interface. One interface exists, `enp4s0`, of type
`PHYSICAL`. Sanitized, with link addresses and the IPv6 address redacted and the
IPv4 addresses replaced with placeholders:

```json
[
  {
    "name": "enp4s0",
    "type": "PHYSICAL",
    "description": "",
    "fake": false,
    "id": "enp4s0",
    "ipv4_dhcp": false,
    "ipv6_auto": false,
    "mtu": 9000,
    "aliases": [
      { "type": "INET", "address": "<lan-ipv4-a>", "netmask": 24 },
      { "type": "INET", "address": "<lan-ipv4-b>", "netmask": 24 }
    ],
    "state": {
      "name": "enp4s0",
      "orig_name": "enp4s0",
      "description": "enp4s0",
      "cloned": false,
      "mtu": 9000,
      "flags": ["UP", "BROADCAST", "RUNNING", "MULTICAST", "LOWER_UP"],
      "nd6_flags": [],
      "capabilities": [],
      "link_state": "LINK_STATE_UP",
      "media_type": "Ethernet",
      "media_subtype": "autoselect",
      "active_media_type": "Ethernet",
      "active_media_subtype": "1000Mb/s Twisted Pair",
      "supported_media": ["10baseT/Half", "10baseT/Full", "100baseT/Half",
                          "100baseT/Full", "1000baseT/Full", "Autoneg", "TP",
                          "MII", "Pause", "Asym_Pause"],
      "media_options": null,
      "link_address": "<redacted-mac>",
      "permanent_link_address": "<redacted-mac>",
      "hardware_link_address": "<redacted-mac>",
      "rx_queues": 1,
      "tx_queues": 1,
      "aliases": [
        { "type": "INET", "address": "<lan-ipv4-b>", "netmask": 24,
          "broadcast": "<lan-broadcast>" },
        { "type": "INET", "address": "<lan-ipv4-a>", "netmask": 24,
          "broadcast": "<lan-broadcast>" },
        { "type": "INET6", "address": "<redacted-ipv6>", "netmask": 64 }
      ],
      "vrrp_config": null,
      "ports": [],
      "xmit_hash_policy": null,
      "lacpdu_rate": null
    }
  }
]
```

Top-level keys of one object: `aliases`, `description`, `fake`, `id`,
`ipv4_dhcp`, `ipv6_auto`, `mtu`, `name`, `state`, `type`. Two observations that
matter for the normalizer:

- `id` equals `name` for a physical interface. `type` is one of `PHYSICAL`,
  `BRIDGE`, `LINK_AGGREGATION`, `VLAN` (only `PHYSICAL` was observed).
- There is no top-level `link_state`, `media_type` or `active_media_type`. Those
  values live only under the nested `state` object, so the design's
  `network[].linkState` has to read `state.link_state`, not a flat field. A jq
  path that asks for `.link_state` at the top level silently yields `null`.

`state.link_state` vocabulary: `LINK_STATE_UP` was the only value observed. The
other values from the TrueNAS enum are `LINK_STATE_DOWN` and
`LINK_STATE_UNKNOWN`, which the normalizer should treat as not-up rather than
mapping to a boolean that loses the difference.

Media fields: `state.media_type` and `state.media_subtype` describe the
configured media, `state.active_media_type` and `state.active_media_subtype` the
negotiated link (`Ethernet`, `1000Mb/s Twisted Pair` here), and
`state.supported_media` the list the driver advertises. For a compact display,
`active_media_subtype` is the human-precise value (the link speed), while
`active_media_type` is just `Ethernet`.

Aliases and addresses: each alias is `{type, address, netmask, broadcast?}`
where `type` is `INET` or `INET6`. `netmask` is the CIDR prefix length as an
integer (`24`, `64`), not a dotted-quad string, so it formats as `/24`. The
top-level `aliases` are the configured addresses and carry no `broadcast`; the
nested `state.aliases` are the runtime addresses and do carry `broadcast` plus
the link-local IPv6. For a status view the runtime `state.aliases` is the honest
source (it reflects what the interface actually has), while the top-level
`aliases` reflects configuration. Caching both is unnecessary; cache one and say
which. The M5 plan should pick `state.aliases` for a live view and note that
`broadcast` and link-local IPv6 come with it.

## Error shapes

The routes that do not exist answer `text/plain`, not JSON:

```
404: Not Found
405: Method Not Allowed
```

`POST /api/v2.0/smb` and `PUT /api/v2.0/interface` both answer `405` with that
body, which confirms a route exists but the method is wrong. A malformed JSON
body is a `500` (`500 Internal Server Error`, `text/plain`, body
`Server got itself in trouble`), so the poller should never treat a 5xx as a
shape problem.

A body that fails model validation on a create route answers `422` with a JSON
error document, not the `400 {"message": ...}` shape milestone 3 recorded for the
service and app handlers:

```
POST /api/v2.0/sharing/smb
{"data": [{"message": "Input should be a valid dictionary or instance of SmbShareCreate", "errno": 22}]}
```

`POST /api/v2.0/sharing/nfs` with a non-object body answers the same shape with
`NfsShareCreate`. The milestone-3 `400 {"message": "<attr> attribute expected."}`
is the older handler style; the sharing and iSCSI create routes go through the
newer model layer and answer `422 {"data":[{"message","errno"}]}`. A read path
only sees the `404`/`405` text bodies and the `200` payloads, so this mainly
matters if M5 adds share write verbs later.

For completeness: an unauthenticated request answers `401` with an empty body, as
recorded in `docs/02-truenas-api.md`; `403` is `forbidden` and `5xx` is
`server_error` through `tn_classify`. Success bodies are
`application/json; charset=utf-8`.

## Mapping to the design's state.json

| Design key | Source | Action |
| --- | --- | --- |
| `shares.smb` | `length` of `GET /sharing/smb` | Keep |
| `shares.nfs` | `length` of `GET /sharing/nfs` | Keep |
| `shares.iscsi` | `length` of `GET /iscsi/target` | Keep, fix the path |
| `shares.webdav` | none | Drop: no route on 25.10 |
| `sessions.smb` | none | Drop: no status or sessions route |
| `network[].name` | `/interface` `.name` | Keep |
| `network[].linkState` | `/interface` `.state.link_state` | Keep, fix the path |
| `network[].addresses` | `/interface` `.state.aliases` (or top-level `.aliases`) | Keep, pick one source |

The meta cadence in the design lists `sharing/{smb,nfs,iscsi,webdav}` and
`smb/status` and `network/interface`. The corrected meta set for M5 is
`/sharing/smb`, `/sharing/nfs`, `/iscsi/target` and `/interface`, four calls
instead of six. If the Shares view also wants the SMB global header, add
`/smb` as a fifth. Each list route is a `GET` on the collection and the answer
shapes are arrays of objects, so `expect_shape 'type == "array"'` applies to all
four, and a non-empty object check applies to `/smb` if it is used.

Following the M2/M3 pattern, cache only the consumed fields per section under
their wire names, drop the `audit`/`options` blobs, `server_sid` and the MAC
addresses before the write, and require all M5 sections in `meta_is_stale` so an
older meta reads as stale once and self-heals.

## What could not be verified

- **The iSCSI target row shape.** The live box has zero iSCSI targets, extents,
  portals, target-extent maps and initiators, so the field names and types above
  come from the v25.10.5 reference (`iscsi.target.query`), not from a live
  response. The first box with a target is the first real measurement; put a
  non-empty `iscsi/target` fixture in the test suite and mark it synthetic.
- **`state.link_state` values other than up.** Only `enp4s0` in
  `LINK_STATE_UP` was observed; the down and unknown spellings are from the
  TrueNAS enum, not measured.
- **Bridge, VLAN and link-aggregation interfaces.** Only one `PHYSICAL`
  interface exists, so the `BRIDGE`/`VLAN`/`LINK_AGGREGATION` row shapes are
  unverified.
- **Whether an SMB or NFS share can report `locked: true`.** No locked dataset
  exists, so `locked` was only seen as `false`.
- **SMB session counts.** No route exposes them; confirmed absent, not merely
  hidden.
- **The write paths.** `POST /sharing/smb`, `PUT /sharing/smb/{id}`,
  `POST /sharing/nfs`, `DELETE /sharing/smb/{id}` and the iSCSI create routes
  were not exercised: the task was read-only and creating or deleting a share is
  out of scope. The `422` and `405` bodies above came from deliberately invalid
  requests that no handler accepted.
