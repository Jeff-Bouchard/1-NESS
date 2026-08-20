# Retired: the shared-seed model

`ns74.sh` and the standalone shared `master.seed` are retired. That design
derived every node's identity from ONE seed copied to every node — a single
point of failure: steal one node, steal the fleet's identity. It was, in the
words of DECENTRALIZED-IDENTITY.md, "a shared secret wearing a decentralization
costume."

They are not shipped here. If you have an old `ns74.sh` in place, stop using it
and switch to `ns74ctl`.

## What replaces it

- **Fleet identity** is per-node. Each core-node runs `ns74ctl node gen`
  (`ns74-identity.py gen-node`) to generate its OWN ed25519 key, locally, secret
  never leaving the box. Nodes are bound into the fleet by an on-chain NVS chain
  — `dpo:ness:ns74` -> `worm:user:ness:<master>` -> `worm:node:ness:<url>` — not
  by shared key material. Compromising one node compromises only that node.

- **The local gate seed** (`~/.privateness-keys/master.seed`, created by
  `ns74ctl seed`) is a DIFFERENT thing: it derives only THIS node's gate key —
  the entropy-gate token, the DNSCrypt/provider key, and this node's WORM
  signing key for its own public configs. It is never shared, and losing it
  affects only this node.

Two keys, two jobs, neither shared. That is the whole correction.
