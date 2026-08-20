# ns74 fleet identity — decentralized, no shared secret

## The problem with the old model

The earlier design derived every key from one `master.seed` copied to every
node. For a fleet of 21 independent core-nodes that is a single point of
failure: steal one node, steal the whole fleet's identity. That is a shared
secret wearing a decentralization costume.

## The model now

Each core-node holds **only its own key**, generated locally, secret never
leaving the box. The fleet is bound by a verifiable chain of Emercoin NVS
records — authority flows through on-chain record ownership, not shared key
material:

    dpo:ness:ns74            EmerDPO org-ownership assertion
        |                    owner = PrivateNess org EMC address  (the trust root)
        v
    worm:user:ness:<master>  the org master-user identity (existing PrivateNess key)
        |                    every node names this master-user
        v
    worm:node:ness:<url>     per-node record: own verify key, own owner address,
                             master-user="<master>", self-signed

Why this is actually decentralized:

  - **No shared secret.** Compromising one node's key compromises only that node.
  - **Own entropy.** Each node's key is generated on the node, from OS entropy
    (or the real PrivatenessTools keygen). It is never transmitted.
  - **On-chain authority.** Every NVS record has an owner EMC address; only that
    address can update or revoke it (Emercoin NVS semantics). Revoke a node by
    updating one record. Add node 22 by publishing one more.
  - **Client-verifiable membership.** A client proves a node belongs to ns74 by
    walking the chain up: node record self-signature valid? -> names the trusted
    master-user? -> master-user record owned by the trusted org address? All
    three must hold.

## Reuses existing PrivateNess PKI

This is not a parallel identity system. It uses:

  - **PrivatenessTools keygen** (`keygen node <url> <tariff> <master> "<svcs>" inet <e>`)
    when present; a built-in ed25519 generator (same key shape) as fallback.
  - The **worm:node / worm:user** record format from NESS-Network/NessNode,
    including the `master-user=` field that already models the org->node link.
  - **Emercoin NVS** ownership for authority and **EmerDPO** (`dpo:`) for the
    org-ownership assertion.

## Finding the trust root

You need two values, discoverable from your own emercoind:

    ns74ctl node discover

It queries NVS for existing `worm:user:ness:*` and `dpo:ness:*` records and
reports the owner address(es). Set in ns74.env:

    NS74_MASTER_USER   the master-user name nodes chain to (e.g. ness, ns74)
    NS74_ORG_ADDRESS   the EMC address that owns the org records (trust root)

If nothing exists yet, create it once: `keygen user ns74 100`, publish
`worm:user:ness:ns74` from the org EMC address; that address becomes the root.

## Commands

    ns74ctl node discover              find the org chain to attach to
    ns74ctl node gen [url]             generate THIS node's own key (local)
    ns74ctl node worm [url]            emit this node's signed chained record
    ns74ctl node verify <file>         verify a node record chains to the org

Per-node NVS keys:  worm:node:ness:<url>

## Verified in build

  - 3 independent nodes each generate a DIFFERENT key (no shared seed);
  - each emits a chained worm:node record naming the org master-user;
  - a client verifies all three chain to the trusted org;
  - ATTACKS REJECTED: wrong master-user (INVALID), forged URL on a real record
    (self-signature fails), swapped verify key (self-signature fails);
  - full flow works through ns74ctl end to end.

## The consistency tradeoff (chosen: per-node now, threshold later)

Per-node keys mean the gate's blind passes and POPRF entropy are keyed per node:
a pass bought at node 3 verifies at node 3. For DNS resolution this is fine
(each node independently resolves). For "land anywhere" entropy/passes, the
future path is a **threshold key** (DKG across the 21 nodes: one fleet public
key, no node holds the secret, t-of-n to evaluate) — designed for, not built
yet. Ship decentralized identity now; add threshold POPRF when 21 nodes exist
to run the ceremony.
