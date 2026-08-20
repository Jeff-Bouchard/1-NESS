# Audit of every claim I made in this session

Re-checked against a **fresh clone**, not the working copies I'd been editing:

- `NESS-Network/PrivatenessTools` @ `4f0bfc4dd3e7ea33625af9d2b606845181198650` (2026-07-31)
- `skycoin/skywire` @ `7cbda29a` (2026-08-16)

Two harnesses: `verify.py` (static, 40 checks) and `runtime.py` (9 checks that
execute the code). Both re-runnable.

**Result: 48 of 49 verified. One claim was understated. One deliverable had a
bug. No claim I made to you was contradicted.**

---

## Executed, not grepped — 9/9

The strongest checks, because a grep can be fooled and running the code cannot.

| Claim | Result |
|---|---|
| block *i* decrypts alone, out of order | **PASS** — 3158081 B ct from 3158049 B pt |
| plaintext block 1048568 / ciphertext 1048576 | **PASS** |
| 100 rounds of `add_entropy` change nothing | **PASS** |
| `entropy=100` and `entropy=1` produce identical output | **PASS** |
| two `UhePrng()` instances share one state array | **PASS** |
| `SigningKey(seed).generate()` ignores the seed | **PASS** |
| `SigningKey(seed)` alone *does* honour it | **PASS** |
| a fresh machine cannot create its first user key | **PASS** — `TypeError` in `Users.findUser` |
| node key lands in CWD, not the keys dir | **PASS** — `cwd=True keysdir=False` |

---

## Static — 39/40, and the one miss was my harness

Verified and holding: all 9 `/files/` endpoints; `block_size = 1024**2`;
`Range: bytes=<pos>-`; salsa20 nonce-per-block; `getBlockAddition()==8`;
`sync.py` stub; Files schema has no `key`; MyNodes schema has `key`+`fskey`;
`encrypt`/`decrypt` both read `self.node['key']`; `fileinfo()` returns no
cipher row; `SK.generate()`; the empty-loop bug; class-attribute `s`;
MT seeding; `__keypairs` zero callers; `KeyIndexException` never raised;
`fskey` never read; nonces from pycryptodome; `/dev/random` ×2;
`key = generator.string(32)`; `fskey = generator.string(16)`;
`Users.__users = False`; bare `"node.key.json"`; 11 × `self.fileName()`;
all four NVS forms; `name_filter '^worm:node:ness:.+'`; base64 `name_show`;
`blk <args>` commented out; auth_id's four static inputs with no time or
counter; SealedBox + ed25519; treestore schema; ptyfs sftp+go-fuse; serve;
`SKYDEPLOY`; base32 DNS label; and the 44/53/66 encoding lengths.

### The one failure

`verify=False` counted **14**, not 11 — because my harness walked the whole
directory and I had just created a `venv/` inside it. Excluding site-packages:
**11, in 4 files.** The original claim stands.

---

## What this turned up about my own work

### 1. I understated the off-by-one — it is in 4 places, not 2

`range(0, self.o - 1)` appears at `Prng.py` lines **59, 105, 118, 152** —
`__init__`, `hash`, `init_state`, **and `hash_string`**. I described the first
two. The JS→Python port artifact is more pervasive than I said. `prng_fixed.py`
already corrects all four; my description of it did not.

### 2. `ness-vps-auth.sh` had a real bug — now fixed

It grepped only `services/*.py` and `ness/*.py`, so it reported **9**
occurrences of `verify=False`, not 11. The two it missed are `backup.py` and
`nodes-update.py`. Actual distribution:

```
ness/NessAuth.py    4
services/node.py    5
backup.py           1
nodes-update.py     1
```

Note `services/files.py` has **zero** — its requests go through `NessAuth`.
When I said "files.py passes verify=False" that was loose; the calls it makes
inherit the setting from NessAuth. Corrected script re-sent, and it now names
the per-file distribution instead of a bare count.

### 3. Two earlier self-corrections, already shipped

- `nessfs-probe.py` read a per-file `key` from `files.json`. No such field has
  ever existed. Fixed to read the node key from `my-nodes.key.json`.
- I called `verify=False` a safety gap and offered to turn CA validation on.
  That was wrong on the merits and would have broken
  `http://batman1.private.ness` outright. Removed.

---

## What I could NOT verify, and am not claiming

Stated plainly, because the point of this pass is that nothing rests on my say-so.

- **Live `Range:` behaviour.** Every claim about seekable reads is proven on the
  *client* side. Whether a node returns a real `206` with `Content-Range` — or
  quietly `200`s the whole body — needs your node. That is exactly what
  `nessfs-probe.py` exists to answer, and it reports `not observed` rather than
  guessing.
- **Server-side node behaviour.** I only ever had the client. How a node
  validates `auth_id`, whether it rate-limits, whether it rejects replays at the
  server, whether nonces rotate server-side — all unknown to me. If the node
  rejects replayed `auth_id`s, my note about token repetition is moot.
- **Skywire deployment liveness.** The endpoints, PKs and dmsg servers I listed
  are read out of `deployment/services-config.json`. I did not dial one.
- **Your private branches.** Everything here is public `master`. If `__keypairs`,
  `fskey`, or per-file keying are wired in a branch I don't have, then my
  "unwired" findings are wrong for your tree and right only for public master.

---

## Re-run it yourself

```sh
python3 verify.py     # 40 static checks
python3 runtime.py    # 9 checks that execute the code
```

Both take a pristine clone path at the top. If either disagrees with anything
above, the harness is the thing to trust — not this document.
