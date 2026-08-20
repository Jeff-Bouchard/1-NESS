# Skywire deployment — what it is made of, and how to run your own

Extracted from `github.com/skycoin/skywire` @ `7cbda29a` (2026-08-16).
Every value below is read out of the repo, not remembered.

Primary sources: `deployment/services-config.json`,
`deployment/services-config-clearnet.json`, `deployment/config.go`,
`deployment/deploy_config.go`, `NETWORK_DATA.md`, `cmd/svc/`.

---

## 1. The parts

A Skywire deployment is **six discovery services + a fleet of dmsg servers +
three sets of well-known PKs**. Everything else (visors, apps, VPN, skychat)
is a client of those.

| Service | Slug | Does |
|---|---|---|
| DMSG Discovery | `dmsgd` | registry of dmsg clients and servers; who to dial to reach a PK |
| Transport Discovery | `tpd` | registry of established transports between visors |
| Address Resolver | `ar` | PK → reachable address for direct (stcpr/sudph) transports; NAT hole-punch broker |
| Route Finder | `rf` | path computation across the transport graph |
| Service Discovery | `sd` | who offers what (proxy, vpn, visor, …) |
| Uptime Tracker | `ut` | liveness history; feeds the reward system |

Plus:

- **DMSG servers** — the relay fleet. Bootstrap depends on these; nothing
  else works if a visor cannot reach one.
- **Config bootstrapper** (`conf`) — hands a fresh visor its services config.
- **Route setup nodes** — build multi-hop routes on request.
- **Transport setup nodes** — PKs allowed to create transports remotely.
- **STUN servers** — for sudph NAT traversal.
- Optional: geoip, network-monitor, reward system.

Source of truth per service is its own package —
`pkg/dmsg/discovery/api`, `pkg/transport-discovery/api`,
`pkg/address-resolver/api`, `pkg/route-finder/api`,
`pkg/service-discovery/api`, `pkg/uptime-tracker/api` — with endpoint
inventories collected in `pkg/skyenv/svcendpoints/svcendpoints.go`.

---

## 2. Current public deployment (`prod`)

Dual-addressed: every service answers on both HTTP and dmsg. The dmsg
address is the one that survives clearnet interference — and
`config gen --dmsghttp` is documented as **the default**.

| Service | HTTP | dmsg |
|---|---|---|
| DMSG Discovery | `http://dmsgd.skywire.skycoin.com` | `dmsg://022e607e0914d6e7ccda7587f95790c09e126bbd506cc476a1eda852325aadd1aa:80` |
| Transport Discovery | `http://tpd.skywire.skycoin.com` | `dmsg://02b307aee5c8ce1666c63891f8af25ad2f0a47a243914c963942b3ba35b9d095ae:80` |
| Address Resolver | `http://ar.skywire.skycoin.com` | `dmsg://03234b2ee4128d1f78c180d06911102906c80795dfe41bd6253f2619c8b6252a02:80` |
| Route Finder | `http://rf.skywire.skycoin.com` | `dmsg://039d89c5eedfda4a28b0c58b0b643eff949f08e4f68c8357278081d26f5a592d74:80` |
| Service Discovery | `http://sd.skycoin.com` | `dmsg://0204890f9def4f9a5448c2e824c6a4afc85fd1f877322320898fafdf407cc6fef7:80` |
| Uptime Tracker | `http://ut.skywire.skycoin.com` | `dmsg://022c424caa6239ba7d1d9d8f7dab56cd5ec6ae2ea9ad97bb94ad4b48f62a540d3f:80` |
| Config bootstrapper | `http://conf.skywire.skycoin.com` | `dmsg://021f751cb8690a96585e10c4d253513cd208bd659fd4f6c227ad49d2b75eec1ff2:80` |
| Reward system | `https://theskywirenetwork.net` | `dmsg://036a70e6956061778e1883e928c1236189db14dfd446df23d83e45c321b330c91f:80` |

**DMSG servers (prod, 9):**

| PK | Address | WSS |
|---|---|---|
| `0281a102c82820e811368c8d028cf11b1a985043b726b1bcdb8fce89b27384b2cb` | `139.162.160.227:30086` | yes |
| `0371ab4bcff7b121f4b91f6856d6740c6f9dc1fe716977850aeb5d84378b300a13` | `45.79.213.251:30087` | yes |
| `0255117bf8d4687dacd5f7ac4c241f008060f1972911552a5b67b76f0e7922f5c7` | `172.105.179.5:30085` | — |
| `02c483938539bd7820f72e48ed6056bab68e221e1108d23965a2903221495e4af7` | `172.104.166.8:30084` | — |
| `03f57e7cf26c0764c5ab659a606add056ddf8bfad4f5bc7e8613cad05e5f228adf` | `172.235.168.146:30081` | — |
| `0326978f5a53aff537dbb47fed58b1f123af3b00132d365f1309a14db4168dcff7` | `70.121.13.123:9083` | — |
| `02a2d4c346dabd165fd555dfdba4a7f4d18786fe7e055e562397cd5102bdd7f8dd` | `45.79.124.73:30082` | — |
| `03717576ada5b1744e395c66c2bb11cea73b0e23d0dcd54422139b1a7f12e962c4` | `172.105.110.46:30083` | — |
| `02a49bc0aa1b5b78f638e9189be4ed095bac5d6839c828465a8350f80ac07629c0` | `143.42.59.213:30088` | — |

WSS servers use `<pk-base32>.theskywirenetwork.net/dmsg` — note the
`wss_domain_suffix` field, and note that the label is **base32**, the same
encoding constraint discussed for NVS records.

**Route setup nodes (2):** `0324579f003e…58557`, `024fbd3997d4…ce438`
**Transport setup (10):** see `services-config.json` → `transport_setup`
**STUN (2):** `139.162.160.227:3478`, `172.104.247.120:3478`
**test env:** same shapes at `*.skywire.dev`, ports offset **+10000** from prod.

> The `test` and `prod` blocks share every discovery PK today — they differ
> only in HTTP hostnames, geoip, the extra prod dmsg server, and WSS entries.
> Do not assume `test` is an isolated network.

---

## 3. Running your own — the one hook that matters

```
SKYDEPLOY=/path/to/your-services-config.json
```

`deployment/config_native.go` reads it at package init and it replaces the
embedded `services-config.json` wholesale, for **every** skywire binary —
visor, cli, dmsg tools, services. That is the entire override mechanism.
No rebuild, no fork.

Start from the real thing rather than a blank file:

```sh
skywire svc conf svcconf    > mine.json     # full embedded config
skywire svc conf dmsgconf   > mine.json     # dmsg-only subset (http stripped)
skywire svc conf httpconf   > mine.json     # http-only subset
```

Edit the six `*_dmsg` endpoints, `dmsg_servers`, `route_setup_nodes`,
`transport_setup`, then:

```sh
export SKYDEPLOY=/etc/skywire/mine.json
skywire cli config gen -o /etc/skywire/skywire-config.json
```

`config gen` also documents this directly at `gen.go:499`.

### Generating each service's own config

```sh
skywire cli config gen --dmsgdisc     # dmsg-discovery
skywire cli config gen --dmsgsrv      # dmsg-server
skywire cli config gen --tpd          # transport-discovery
skywire cli config gen --sd           # service-discovery
skywire cli config gen --ar           # address-resolver
skywire cli config gen --rf           # route-finder
skywire cli config gen --sn           # route setup node
```

### One file for all operational settings

`deployment/deploy_config.go` defines a unified format that extends
services-config with per-service operational config — listen addr, keyfile
path, redis URL + pool size, dmsg-disc URL, pprof addr, entry TTL,
deregistration whitelist, listener `mode` (`http` | `dmsg` | `dual`),
postgres host (UT), GODEBUG.

```sh
skywire svc deploy-template --env prod > /etc/skywire/deploy.json
skywire svc tpd --deploy-config /etc/skywire/deploy.json --env prod
```

Flags override file values when both are given. **Secret keys live in
separate keyfiles referenced by path, never inline** — so the config file
itself is shareable.

### Service binaries

Under `cmd/svc/`: `address-resolver`, `route-finder`, `service-discovery`,
`transport-discovery`, `uptime-tracker`, `setup-node`, `transport-setup`,
`config-bootstrapper`, `stun-server`, `geoip`, `network-monitor`, `conf`,
`sw-env`, and `skywire-services` (the umbrella). All also reachable as
`skywire svc <name>`.

### Minimum viable private deployment

1. **dmsg-discovery** + **at least 2 dmsg servers** — nothing works without
   these. `--minsess` defaults to 2, so a one-server deployment leaves every
   visor permanently under its session target.
2. **transport-discovery** — visors can dial but the graph is invisible without it.
3. **address-resolver** — needed for direct stcpr/sudph; skip it and
   everything relays through dmsg (slower, works).
4. **route-finder** + **route setup nodes** — needed for multi-hop only.
   With `--min-hops 1`, direct routes work without them.
5. **service-discovery** — needed to *find* services; not to use a known PK.
6. **uptime-tracker** — only if you want uptime history or rewards.

So the true floor is **dmsg-discovery + 2 dmsg servers + transport-discovery**.
Redis backs tpd/ar/sd; postgres backs ut.

---

## 4. Observing it

```sh
skywire cli svc health              # all services: status, latency, protocol, version, PK
skywire cli svc dmsgd all-servers   # every dmsg server
skywire cli svc dmsgd server-clients        # clients grouped by server
skywire cli svc dmsgd clients <pk>          # clients on one server
skywire cli svc tpd stats | versions | per-key-stats | bandwidth
skywire cli svc check <pk>          # is this PK registered in the address resolver?
skywire cli sd                      # combined sd + tpd network view
skywire cli visor dht get <pk> tp   # DHT equivalent, no service needed
```

`svc health` output columns are STATUS / LATENCY / PROTOCOL / VERSION / PK —
and it distinguishes `http` from `dmsg` per service, which is exactly the
distinction that matters when clearnet is degraded but the mesh is fine.

All `skywire cli` network-data commands try visor RPC first and honour
`--direct` to bypass it.

---

## 5. CXO is already inside the deployment

Not just an app-level feature — `pkg/skyenv/skyenv.go` reserves dmsg ports
for deployment services publishing over CXO:

- `DmsgSDServicesCXOPort` — service-discovery publishes its service list
- `DmsgDMSGDClientsByServerCXOPort` — dmsg-discovery publishes clients-by-server
- `DmsgDMSGDRegistrationCXOPort` — dmsg-discovery registration feed
- `DmsgCXOPort` (50) — the visor's own telemetry feed

Meaning discovery data is **already replicated as CXO feeds**, not only
served over HTTP. A private deployment can subscribe to those feeds rather
than polling — and the treestore design in the filesystem doc uses the same
machinery, so there is one mechanism to operate, not two.

---

## 6. What to pin down before standing yours up

- **Which PKs are yours.** Generate service keypairs first; every config
  references them. Keyfiles, not inline SKs.
- **dmsg server reachability.** They need routable addresses and open ports.
  This is the single hardest requirement and the one that decides whether the
  deployment works at all.
- **`--minsess`.** Default 2. Run at least 2 dmsg servers or lower it
  deliberately.
- **Redis and Postgres.** tpd/ar/sd want redis; ut wants postgres.
- **WSS or not.** Needed only for browser/WASM clients; requires the
  base32-label domain suffix and certs.
- **Isolation.** A private `SKYDEPLOY` isolates *discovery*, not traffic —
  a visor with public transport-setup PKs in its config can still be reached
  by them. Strip `transport_setup` and `route_setup_nodes` to your own PKs
  if isolation is the point.
