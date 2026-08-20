# NESS Observationary 1.1

This is the cross-network descendant of three earlier artifacts:

- `privateness_wheel-1.html` - the architecture wheel
- `worm-mission-control-honest-state.html` - UNKNOWN until observed
- `ness_dashboard_real_bundle_v0.3` - live loopback observation and listener control

It also carries `ness.sh` 2.9, whose EmerEyes-derived gate keeps two facts separate:

1. **source** - chain, wire, visor, local keys, or local configuration
2. **check** - verified, failed, reported, claimed, or absent

A report is not a verification. A configured value is not a measurement. An installed transport is not an active route. The UI never collapses those distinctions.

The surface re-observes every five seconds while visible. Tap an OFF, NOT OBSERVED, or unknown component to run a scoped observation immediately. If the manager observes a recognized installed `systemd` unit, it offers a two-step **Start locally** action, shows the exact command first, starts without `sudo`, and probes again. It never installs packages or guesses daemon arguments.

## Start

```bash
chmod +x start-observationary.sh ness.sh
./start-observationary.sh
```

The manager binds only to loopback and asks the operating system for an available high port. It opens the browser after the port is known.

For a read-only snapshot:

```bash
./snapshot-observationary.sh
```

Then open `ness_dashboard_real.html` and import `ness-observationary-state.json`.

## Three views

- **Architecture** shows the derived composition and labels relationships as policy or evidence. It never claims a route is live.
- **Repository evidence** distinguishes implementation, formal artifact, prototype, deployment policy, and future work.
- **This machine** uses only local probes. Unknown means not probed. Not observed means the probe ran and found no evidence.

The **Run independent-derivation gate** button explicitly runs:

```bash
NO_COLOR=1 NESS_QUIET=1 bash ness.sh --raw --no-probe verify
```

It is not run automatically during the five-second refresh; it runs only when touched.

## POPRF, not VOPRF

`PO` in this architecture means **partially oblivious PRF (POPRF)**. PrivateNESS uses POPRF because a WORM object provides the shared public `info` context. The oblivious input remains hidden while the computation is bound to that public WORM object and remains verifiable. VOPRF was deliberately retired because it verifies the server key but does not provide that public-context binding.

## Evidence snapshot used by the map

Verified against GitHub on 2026-08-17:

| Surface | Evidence | Honest classification |
| --- | --- | --- |
| Emercoin NVS + RandPay | `emercoin/emercoin` commit `c8c9d3fca964ae164c2ec045eb975431807836d2`; `RandPayRequest.cpp`; `randpay-test.sh` | implemented |
| Emercoin agent identity/memory | `emercoin/emer-ai-tools` commit `7fb1239c6fb40e1415150945a423aab5f12315b2`; README says MVP verified end-to-end on mainnet | implemented MVP |
| PrivateNESS keys, WORM records, encrypted node/files client | `Jeff-Bouchard/PrivatenessTools` commit `1fe3531a1fe525f9a606348e473814fcebb3ca44` | implemented |
| Service node API | `NESS-Network/PrivatenessNodeReference` commit `54483bad2e93b67c2f46b46dc519fd4b51e91549` | implemented reference, old snapshot |
| NESS chain | `NESS-Network/ness3` commit `db00bfccf672635eb87a2af1a7d431f970eb572e` | implemented code; live status requires the local probe |
| Data Poisoner | `Jeff-Bouchard/privateness-data-poisoner` dev commit `4d229a9f54a9ffb179e5b146732ed93b0d18497b` | implemented; public branch evidence is older than the >0.19 artifact lineage |
| HTTP 402 Apache module | `Jeff-Bouchard/mod_402` commit `6ff8e2d30caab3a0cfa207547cb644c44a0a15dd` | core handler prototype; PrivateNESS provider is a stub |
| PrivateNESS MCP over HTTP/3 | `Jeff-Bouchard/privateness-mcp-app` commit `8698f23c8f0baf4dc8cb0654c3ce3162ce21c454` | transport skeleton; authentication verification and NCH debit are placeholders |

The formal WORM core, POPRF capability integration, unified LBRTY/SoftEther/Skywire route scheduler, and autonomous monetizing derived-agent swarm are shown as artifact, policy, prototype, or future work unless this machine produces stronger evidence. VOPRF remains visible only as a retired design decision.

## Local probes

- NESS health: `http://127.0.0.1:6660/api/v1/health`
- Emercoin RPC reachability: `127.0.0.1:6662`
- Emercoin height, best hash, and `dpo:PrivateNESS.Network`: local `emercoin-cli`, when usable
- x402 daemon: `/run/ness402d.sock`
- LBRTY, SoftEther, Skywire, Yggdrasil, I2P, and Tor: executable/process evidence
- Skywire: visor public-key probe when `skywire cli visor pk` is available
- source trees: local paths plus Git commit when a `.git` directory is present
- listeners: `ss`, `netstat`, or `lsof`, depending on platform

No Internet endpoint is used to fabricate local health.
