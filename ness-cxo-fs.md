# PrivateNess FILES + Skywire CXO — a two-backend network filesystem

Reviewed against:

- `github.com/NESS-Network/PrivatenessTools` @ master
- `github.com/skycoin/skywire` @ `7cbda29a` (2026-08-16)
- `ness.sh` v2.8 (the `nesssh_10.txt` you sent, 3516 lines)

---

## 1. What the FILES service actually is

It is **not** a filesystem. It is a per-user, flat, append-only object
store with client-side encryption, plus a directory index that exists
only on your own disk.

### Wire protocol

Everything is HTTP + JSON against a node URL. From `services/files.py`:

| Endpoint | Method | Auth mode | Purpose |
|---|---|---|---|
| `/files/list` | POST | two-way | flat list of `{shadowname, id, size}` |
| `/files/touch` | POST | two-way | create/resume; returns `id` + bytes already stored |
| `/files/append/<id>/<shadow>/<auth_id>` | POST | auth_id | append one block |
| `/files/fileinfo` | POST | two-way | size, id, links |
| `/files/download/<id>/<shadow>/<auth_id>` | GET | auth_id | body, honours `Range:` |
| `/files/remove` | POST | two-way | delete |
| `/files/quota` | POST | two-way | usage |
| `/files/rewrite` | POST | two-way | truncate + replace (used by `backup`) |
| `/files/pub/<id>-<shadow>-<alt_id>` | GET | none | public link |

Two auth modes, both in `ness/NessAuth.py`:

- **two-way encryption** — request is `{data: sealed-box(payload, node_pub),
  sig: ed25519(ciphertext, user_sk), username}`; the reply is
  `{data, sig}`, verified against the node's verify key and opened with
  your private key. Control plane.
- **auth_id** — a derived token spliced into the URL *path*:
  `…/<shadowname>/<urlencoded auth_id>`. Bulk plane (append, download).

### Storage model

- Block size **1 MiB** (`block_size = 1024**2`).
- Upload = `touch` → returns bytes already there → `append` the remainder.
  **Resumable by construction.**
- Download sends `Range: bytes=<local size>-` and appends. **Also resumable,
  and this is the hook that makes random reads possible.**
- **One salsa20 key per (user, node) — not per file.** The README claims
  per-file keying and it is not true of this code: `NessKeys/keys/Files.py`
  validates each file entry as `{filename, filepath, size, status, progress,
  paused, directory}` with no key field, the key lives once per node in
  `my-nodes.key.json`, and `services/files.py:564` feeds it to every file:
  `BlockCryptor(cryptor, bytes(self.node['key'][:32], 'utf8'), …)`.
  So one compromised key is every file on that node, past and future.
  (`fskey`, generated beside it at `FileManager.py:93`, is stored and never
  read — plausibly the intended per-file derivation seed, never wired.)
- `BlockCryptor` encrypts **each 1 MiB block independently**, prepending a
  fresh 8-byte nonce (`Salsa20.encrypt` → `cipher.nonce + ciphertext`).
  So plaintext block = 1 048 568 B, ciphertext block = 1 048 576 B, and
  **block *i* decrypts without block *i−1*.** Seekable. This is the single
  most important property for a mount.
- The node sees only: a random `shadowname` (`abcd.12`), a 40-hex id, a size,
  and ciphertext. No filename, no path, no plaintext.
- Public files are stored *unencrypted* with `shadowname == filename`.

### What lives only on your client

`~/.privateness-keys/directories.json` and `files.json`. Directories are
integer IDs. `move` rewrites local JSON and never touches the node.
**The node has no concept of a directory, a rename, or an mtime.**

### Missing pieces, named plainly

- No random write. Only append-at-EOF and whole-file `rewrite`.
- No rename, mkdir, rmdir, chmod, chown, mtime, atime on the node.
- No locking, no leases, no change notification.
- No multi-client coherence. Two machines holding the same key diverge
  silently — and `sync.py` is literally `print('Not implemented jet')`.
- `files.json` is one JSON blob rewritten in full on every change. Fine at
  10³ files, painful at 10⁵.
- `auth_id` signs four static values — node_url, node_nonce, username,
  user_nonce — with no method, path, body hash or timestamp, so the token
  repeats and replays against that same node. Bounded: download yields
  ciphertext, prng spends quota, append writes garbage. Closing it is a
  protocol change, not a transport one.
  (`verify=False` appears 11 times across 4 files and is **not** a defect:
  the channel is sealed-box encrypted and ed25519-signed against keys taken
  from the chain. CA validation would add an authority, not a guarantee, and
  would break a node at `http://batman1.private.ness` outright.)

---

## 2. Can you make it NFS-like?

**A single-writer FUSE mount: yes, and it is a weekend-sized project.**
**Real NFS semantics (concurrent writers, byte-range writes, locking):
no, not without a node-side change.**

Here is the honest mapping.

| FUSE op | Cost | How |
|---|---|---|
| `getattr`, `lookup`, `readdir` | **zero network** | read `files.json` / `directories.json` |
| `open`, `read` | one ranged GET per 1 MiB block | `Range: bytes=i*1048576-((i+1)*1048576-1)`, strip 8-byte nonce, salsa20-decrypt |
| `mkdir`, `rmdir`, `rename` | zero network | local index edit; invisible to any other device |
| `write` | deferred | write-back cache, whole-file re-upload on `release` |
| `truncate` | whole-file | `rewrite` |
| `flock`, `setlk` | ✗ | must be faked locally or refused |
| `utimens`, `chmod` | ✗ | store in your own manifest, not on the node |

The read path is genuinely good: metadata is local so `ls -R` costs nothing,
and per-block independent encryption means `dd skip=…` fetches exactly one
1 MiB range. That is better than sshfs on a cold cache.

The write path is the compromise everyone makes — this is
`rclone mount --vfs-cache-mode full`: buffer locally, upload on close. You
lose `O_APPEND` correctness under concurrency and you lose partial-file
updates of big files, and you accept it.

The remaining gap is **rate, not absence**. EmerNVS already provides the
shared namespace (§4a) — `worm:user:ness:<user>`, `worm:node:ness:<url>`,
and `name_filter ^worm:node:ness:.+` to enumerate every node on the chain.
What NVS cannot do is absorb a write per file operation: each update is a
transaction with a fee, a block interval, and a value ceiling (your own
`NESS_NVS_MAX=20480`). So the namespace is anchored on-chain and *moved*
off-chain — which is where CXO earns its place.

> The raw material for the off-chain half already exists too:
> `uploadEncryptString` / `/files/rewrite` is how `backup` stuffs a JSON blob
> into the store under a fixed shadowname. Putting the manifest set there is
> the zero-new-dependency version of what follows.

---

## 3. What Skywire ships today

Current master has more than CXO, and some of it is closer to NFS than CXO is.

### `pkg/cxo/treestore` — the interesting one

A **path-keyed hierarchical store published as a CXO object graph**.

```go
type TreeNode  struct { Children registry.Refs }
type TreeEntry struct { Name string; Sub registry.Ref; Leaf []byte }
```

Paths are slash-separated segments. Content-addressed, so an unchanged
subtree keeps its hash and subscribers never refetch it — only the
O(depth) chain from a changed leaf to the root is re-encoded and rebroadcast.

- `Publisher`: `Put`, `PutBatch`, `Get`, `Delete`, `PrunePrefix`, `Walk`,
  `Flush`, `SetAllowlist` (subscriber PK allowlist), over **dmsg** or TCP.
- `Subscriber`: `Connect`, `SetPrefixes` (prefix filtering), `Get`, `Walk`,
  reconnect watchdog.
- CLI: `skywire cli visor cxo feeds ls|add|rm`, `cxo status|refresh|fetch <feed> <path>`.
- Standalone daemon: `cxo daemon`, `cxo cli feed share|list`,
  `cxo cli tcp|udp subscribe <pk>@<addr>`, `cxo cli root tree|last`.

The schema comment is explicit that leaves are inlined and meant to stay
small — *"if leaves grow large, switch Leaf to a registry.Ref"*. **So CXO is
your directory tree, not your bulk storage.** Treat that as a hard rule.

### `skywire cli pty fs` (ptyfs) — sshfs without the ssh

Already in the tree: FUSE mount of a peer visor's filesystem over **sftp on a
noise-XK stream**, `github.com/pkg/sftp` → `hanwen/go-fuse`. Flags: `--ro`,
`--remote-root`, attr/entry TTLs, `--standalone` (ephemeral dmsg client).
Linux-only. Auth = noise XK pins the server PK, dmsgpty whitelist gates the
client PK. No passwords, no CA.

This is the closest thing to a network filesystem in the whole stack and it
already exists.

### `skywire cli serve` — tunnel anything

`serve add <port> --to 127.0.0.1:<port>` plus
`serve whitelist <port> <pk>,<pk>` exposes a local TCP port over
dmsg/`.skynet` behind a PK allowlist. Which means: **you can run an actual
NFSv3/9p/WebDAV server and carry it over the mesh**, with PK auth instead of
`/etc/exports`. Ugly, effective, zero new code.

### Also

`skywire cli skychat send-file` streams files peer-to-peer over an encrypted
transport (`SkychatFilePort`). Not a filesystem, but a working bulk-transfer
path over dmsg you can borrow.

---

## 4. The design: split metadata from data, give each two backends

The two systems fail in **opposite directions**, which is the whole reason
this works:

|  | PrivateNess FILES | Skywire CXO / dmsg |
|---|---|---|
| shape | durable server-side blobs, quota'd | gossiped content-addressed tree |
| addressing | node URL over HTTPS | public key, NAT-traversing |
| dies when | your node is down / clearnet blocked | no peer online holds the objects |
| good at | megabytes | kilobytes, and *agreement* |
| bad at | agreement (no sync at all) | megabytes |

So:

```
┌──────────────────────────────────────────────┐
│  FUSE daemon  (go-fuse — same lib as ptyfs)  │
└───────┬───────────────────────┬──────────────┘
        │ namespace             │ bytes
        ▼                       ▼
┌───────────────┐       ┌──────────────────┐
│  MANIFEST     │       │  CHUNK FETCHER   │
│  primary: CXO │       │  primary: FILES  │
│   treestore   │       │   /files/download│
│  fallback:    │       │   + Range        │
│   /files/     │       │  fallback: dmsg  │
│   rewrite blob│       │   chunk-serve /  │
│               │       │   ptyfs peer     │
└───────────────┘       └──────────────────┘
        ▲                       ▲
        └── discovery: Emercoin NVS ──┘
            (emercoin-cli, or ai.emercoin.com MCP read_record)
```

### Layer 1 — namespace

Canonical form is a treestore path space:

```
/<vol>/dirs/<dir-id>              → {name, parent, mtime}
/<vol>/files/<escaped/path>       → manifest JSON (below)
/<vol>/meta/version               → lamport counter
```

Manifest leaf, a few hundred bytes:

```json
{
  "v": 41,
  "by": "03ab…<device pk>",
  "size": 5242880,
  "mtime": 1755300000,
  "cipher": "salsa20",
  "keyref": "…",
  "chunks": [
    {"n":0,"h":"sha3-256:…","files_id":"84ac…","node":"https://node.ness.cx"},
    {"n":1,"h":"sha3-256:…","files_id":"84ac…","node":"https://node.ness.cx"}
  ],
  "holders": ["03ab…", "02cd…"]
}
```

- Publisher runs on whichever device is writing; `SetAllowlist` = your own
  device PKs, so nobody else can even subscribe.
- Subscribers use `SetPrefixes` to pull only the volumes they mount.
- **Fallback:** the same manifest set, serialized and pushed through
  `uploadEncryptString` → `/files/rewrite` under a fixed shadowname
  (`.nessfs-manifest`). Exactly the mechanism `backup` already uses.

Reconciliation: per-path `(lamport v, device pk)`. Higher `v` wins; equal `v`
with different content hash is a genuine conflict → materialize **both**, as
`name` and `name.conflict-<pk>-<ts>`. Never merge silently. Dropbox's rule,
and it is the right one.

### Layer 2 — bytes

Fixed 1 MiB chunks — match `files.py`'s `block_size` exactly so a chunk *is*
a FILES block and no re-chunking is ever needed. Chunk id = SHA3-256 of
ciphertext.

- **Backend A — FILES.** `touch`/`append` to write; `download` +
  `Range: bytes=i*1048576-…` to read one chunk. Strip the 8-byte nonce,
  salsa20-decrypt. Durable, quota'd, survives every peer being offline.
- **Backend B — skywire.** Do *not* put chunks in CXO leaves. Instead:
  run a ~200-line chunk server (`GET /c/<hash>` from a local cache dir) and
  publish it with `skywire cli serve add 7801 --to 127.0.0.1:7801` +
  `serve whitelist 7801 <your pks>`. Peers fetch by PK. Use CXO only to
  *announce* the `holders` list — small leaves, exactly what it's for.
  A read-only variant with zero new code: `skywire cli pty fs mount --ro`
  a peer and read its cache directory directly.

### Layer 3 — the mount

One daemon, go-fuse:

- `readdir`/`getattr`/`lookup` — from the materialized treestore view. No network.
- `read` — chunk fetcher with an ordered, health-scored backend list;
  per-chunk failover; local cache dir.
- `write` — write-back cache. On `release`: chunk → encrypt → push to every
  healthy backend → `Put` the new manifest → mirror to `/files/rewrite`.
- Flags: `--ro`, `--prefer files|skywire`, `--cache-dir`, `--hedge 300ms`.

### Fallback policy, concretely

**Health probes** (cheap, every 15 s):

- FILES — `GET <node>/node/nodes`, the existing `nodePing` in `services/node.py`.
- Skywire — `skywire-cli visor pk` answers, and `cxo status` shows a
  last-root age under threshold.

**Reads — hedged, not failover.** Issue to the preferred backend; if no
first byte within `--hedge` (300 ms is a sane default over dmsg), fire the
second in parallel and take whichever answers. Failover-after-timeout costs
you the full timeout on every degraded read; hedging costs one wasted request.

**Writes — one ack, durable outbox.** Return success on the first backend
ack. Queue the others in an on-disk outbox and drain on reconnect. The
manifest `Put` is the commit point: a chunk that exists but is unreferenced
is garbage, a manifest that references a missing chunk is corruption — so
**always push chunks before the manifest, on every backend.**

**Discovery and ordering — see §4a.** The backend preference list is not a
config flag; it is an on-chain SRV record.

---

## 4a. EmerNVS is the shared namespace — and SRV is the failover primitive

### What is already on-chain

From `NessKeys/keys/*.py` and `ness/BlockchainRPC.py`:

| NVS name | Value | Written by |
|---|---|---|
| `worm:user:ness:<username>` | `<worm>` XML: user public, verify, nonce, signatures | `./user worm` |
| `worm:node:ness:<url>` | `<worm>` XML: url, network, nonce, verify, public, master-user, tariff, **services** | `./keygen node` |
| `worm:faucet:ness:<url>` | faucet worm | `./keygen faucet` |
| `dns:<host>` | EmerDNS, pipe-separated: `A=…\|NS=…\|SD=www,ftp` | `ness dns` |

And the enumeration primitive:

```python
name_filter(['^worm:node:ness:.+', 0, 0, 0, '', ''])   # ness/BlockchainRPC.py:53
name_show([name, '', 'base64'])                        #                    :50
```

That is a real directory service: globally consistent, signed, ordered,
enumerable by anyone, and it survives every node and every peer being
offline. **It is the correct root of the namespace.** The earlier framing of
"no shared namespace" was wrong; the accurate statement is that NVS is the
right layer for things that change on the order of days and the wrong layer
for things that change per write.

### The three tiers, by rate of change

| Tier | Holds | Changes every | Mechanism |
|---|---|---|---|
| **EmerNVS** | identity, node + service discovery, skywire PK, volume root pointer | days–months | `worm:*:ness:*`, `dns:*` |
| **CXO treestore** | per-file manifests, holder lists | seconds | `Put` / `Walk` over dmsg |
| **FILES** | 1 MiB chunks | continuously | `touch` / `append` / `download`+`Range` |

Each tier is the fallback of the one above it in *reach* and the one below
it in *speed*. The property no other tier has: a cold client with nothing
but a chain view resolves node list **and** visor PK in one lookup and is
back in business.

### SRV, not a `--prefer` flag

`SRV = priority | weight | port | target` is a backend preference list that
was standardised in RFC 2782. It is strictly better than the `--prefer`
flag proposed in §4 because it lives on-chain, so every device agrees
without local config:

```
dns:_nessfs._tcp.<host>
  SRV=10|60|443|node.ness.cx            ← FILES over HTTPS, preferred
 |SRV=10|40|443|node2.ness.cx           ← same priority: weighted spread
 |SRV=20|100|7801|<pk-base32>.skynet    ← skywire chunk-serve, fallback
```

Lower priority wins; equal priority splits by weight. Failover *and* load
spreading come free, and `ness.sh` already has the reader —
`doom_srv()` at line 1726, `dig +short SRV` with an `nslookup` fallback.
The script's own caution at line 1821 ("the SRV encoding below is a
CANDIDATE, not an assertion") is the right posture; this makes it an
assertion for `_nessfs._tcp` specifically.

Note the constraint the script already states at line 1831: **the SRV target
must itself resolve.** For a skywire target that means the PK has to be a
legal hostname label.

### base64 vs base32 — the one real gotcha

A skywire public key is 33 bytes. Three encodings, three different jobs:

| Encoding | Length | Padding | Legal as a DNS label? |
|---|---|---|---|
| hex | 66 | — | yes, but long |
| **base64** | **44** | **none** (33 ÷ 3 = 11 exactly) | **no** |
| base32 (lowercase, RFC 4648) | 53 | — | yes |

- **base64 is fine — in record *data*.** TXT and PTR payloads are opaque
  octet strings; 44 chars with zero padding is the most compact form that
  round-trips cleanly. Good choice for `TXT="pk=<base64>"`.
- **base64 cannot be a *label*.** Labels are case-insensitive per RFC 1035
  §3.1 and `+` / `/` are not legal there. So a base64 PK cannot be an SRV
  *target*, cannot be a `<pk>.skynet` hostname, and cannot be fed to
  skywire's own parser.
- **Skywire itself uses base32 for exactly this reason.**
  `cipher.PubKey.DNSLabel()` / `ParseDNSLabel` (see `cmd/smb/README.md`):
  *"lowercase RFC 4648 base32 label (53 chars — fits in a single 63-octet
  label per RFC 1035 §2.3.1)"*. The skymail bridge addresses peers as
  `user@<host>.<pk-base32>.skynet`.

**Recommendation:** carry both, and say which is which.

```
dns:<host>   TXT=skywire-pk-b64=<44 chars>
            |SRV=20|100|7801|<53-char-base32>.skynet
```

The base32 form is what any skywire-side consumer can parse without new
code; the base64 form is the compact one for anything reading the TXT
directly. Emitting only base64 means `ParseDNSLabel` rejects your record and
every skywire integration needs a custom decoder — a self-inflicted fork of
an encoding that already had a settled answer.

### Chain read path, with its own fallback

`emercoin-cli name_show` / `name_filter` locally; `read_record` on the
`ai.emercoin.com/mcp` server when there is no local wallet — its read tools
need no credentials, so it is an unauthenticated resolver of last resort.
(`store_memory` / `register_identity` need a GitHub bearer token and are not
needed here.)

---

## 4b. Pooling scrap space — why fixed chunks pay for themselves

The problem: many drives, each with a free-space remnant too small to be
worth managing on its own.

Whole-file placement cannot use these. A 4 GB file will not go into four
1 GB scraps, so each scrap is dead weight until something small enough
happens along. This is the classic bin-packing failure and it is why people
reach for mergerfs / Storage Spaces / DrivePool.

**Fixed 1 MiB immutable chunks dissolve the problem instead of managing it.**
Chunks never grow and never get renamed — the two properties that make union
filesystems hard — so placement is a one-line decision and utilisation is
bounded by:

```
wasted ≤ 1 MiB per scrap
```

Ten scraps averaging 2 GB → ~20 GB usable, ~10 MiB lost. Not ~0 GB usable,
which is what whole-file placement gives you for large files.

So the local chunk store is not one directory, it is a **list** of
directories with a placement policy:

```
--chunk-dir D:\.nessfs\chunks
--chunk-dir F:\.nessfs\chunks
--chunk-dir "G:\odds and ends\.nessfs\chunks"
--placement fill-smallest-first     # reclaim scraps
--placement most-free               # spread wear (mergerfs 'mfs')
```

`fill-smallest-first` is the right default here: it drains the scraps that
are otherwise useless before touching the drive that still has room for
something big.

Because chunks are content-addressed, a chunk's location is not part of its
identity — a scrap can be evacuated by copying and updating an index, with
no manifest change and no reader disruption. Losing a whole scrap drive
degrades to a cache miss and a refetch, not corruption.

**Same mechanism pools across machines.** A scrap on another visor is one
more entry in the SRV weight list of §4a. Local scraps and remote scraps are
the same abstraction; only latency differs.

**Windows note.** `ness.sh` supports Git Bash, and the paths above are
Windows paths. FUSE is Linux-only — for a mount on Windows the adapter is
WinFsp (or Dokan). The chunk-pool layer itself is plain file I/O and is
portable as-is; only the mount head needs a second implementation. A CLI-only
`get` / `put` / `sync` against the pool works everywhere today with no
mount at all, and is worth building first for that reason.

---

## 4c. Running the nodes yourself: placement, quota, correlation

Eight self-run nodes change the placement problem from *market* to *policy*.
Three consequences worth designing for.

**1. Quota is already the free-space map.** `/files/quota` per node × 8 is
exactly the input the placement policy needs, and it exists today. No new
endpoint. Resist the temptation to special-case your own nodes and bypass
the accounting — running the real quota path against yourself is what keeps
it honest, and it is a free test harness for the day a node is not yours.

**2. Redundancy: start at 2×, graduate to erasure coding.** With n=8,
replication is wasteful at the scale scrap-pooling implies:

| Scheme | Overhead | Survives |
|---|---|---|
| 2× replication | 2.00× | any 1 node |
| 3× replication | 3.00× | any 2 nodes |
| Reed–Solomon 4+2 | 1.50× | any 2 nodes |
| Reed–Solomon 6+2 | 1.33× | any 2 nodes |

RS over fixed 1 MiB chunks is the natural fit — shards are uniform, so the
encoder is trivial and the manifest just grows a `shards[]` array beside
`chunks[]`. But it is a step-5 feature, not a step-1 one: 2× replication is
twenty lines and gets the pool working.

**3. The honest caveat — correlated failure.** Eight nodes under one
administrator share an update cadence, a config generation, a backup habit,
and often a power feed, ISP, or hypervisor. Erasure coding assumes
independent failures; against a bad config push or an expired cert rolled
out everywhere, k-of-n across eight correlated nodes buys much less than the
arithmetic suggests.

The cheap mitigation is not more nodes — it is **one placement target that
is not yours**, as an anti-correlation anchor. One peer's node, or one
unrelated store, carrying a full copy of the manifest tier (which is small —
kilobytes per file) even if not the chunk tier. That single asymmetry is
worth more than doubling the count of nodes that all fail the same way.

Paying yourself for your own service is a coherent arrangement and the
tariff/quota machinery already models it. It just does not, on its own,
make eight nodes into eight independent failure domains.

---

## 5. Where this touches `ness.sh`

The script is in good shape for this — the observation framework
(`verified` / `reported` / `claimed`, `obs_chk`, the trophy-vs-check
distinction) is exactly the discipline a two-backend mount needs, because
"which backend served this byte" is the same kind of question as "was this
trophy recomputed or claimed".

Two gaps:

- The skywire section (`sky`, `sky_status`, `sky_servers`, `cmd_connect`)
  wraps **only** `skywire-cli vpn *` and `visor pk`. Nothing touches dmsg,
  `serve`, `pty fs`, or `cxo`. Adding `sky_cxo_status()` and
  `sky_feed_age()` alongside `sky_is_up()` — with the same
  negation-checked-first rule — is the natural extension.
- `SERVICES` defaults to `prng,files` and is passed straight to
  `keygen node`. A mount that also serves chunks over dmsg would want a
  third token there.

Natural new verbs: `ness mount [--ro]`, `ness sync`, `ness serve-chunks`.
And `hexbar`'s sixth cell (`served`) has an obvious new lighting condition.

---

## 6. Build order

1. **Read-only mount, FILES only.** Parse `files.json` / `directories.json`,
   go-fuse, ranged chunk reads. Proves the seekable-block claim end to end.
   No CXO yet. Smallest thing that is genuinely useful.
2. **Write-back cache.** `rewrite` on release. Now it's a working
   single-writer filesystem.
3. **Manifest into treestore.** Publisher on one device, subscriber on the
   others, allowlist to your PKs. Now two machines see one namespace.
4. **Chunk server behind `skywire cli serve`.** Second byte backend, hedged
   reads, health probes.
5. **Conflict materialization + outbox drain.** The part everyone skips and
   then regrets.

Step 1 is a few hundred lines and answers the only question that could
still kill this: whether ranged reads against a live node behave the way
`services/files.py` implies.

---

## 7. Two things to fix regardless

- **`verify=False` everywhere (11 sites).** The control plane survives it —
  sealed-box plus ed25519 — but `auth_id` travels in the URL path on
  `append` and `download`, so it lands in proxy logs and in any MITM's hands,
  and it is replayable. Either bind the token to the request (method + path +
  body hash + timestamp) or move it to a header and turn TLS verification on.
- **`sync.py` is a stub.** Anyone reading the repo reasonably assumes
  multi-device sync exists. It does not. Either build it (as above) or say so
  in the README.
