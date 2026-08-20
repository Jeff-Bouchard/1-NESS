#!/usr/bin/env python3
"""
nessfs-probe — does the FILES service behave the way services/files.py implies?

Answers exactly one question, against a live node, with no fabricated values:

    can a 1 MiB ciphertext block be fetched ALONE, OUT OF ORDER, and decrypted
    without any other block — i.e. is a seekable read-only mount possible?

The client-side half of that claim is already settled and does not need a node
(see PROOF below). What only a live node can answer is whether
/files/download honours `Range:` with a real 206, or quietly returns 200 and
the whole body — which would make every random read cost the whole file.

Run it from a PrivatenessTools checkout, with a user selected and a node
joined:

    ./node sel https://your-node
    python3 nessfs-probe.py                    # uses ~/.privateness-keys
    python3 nessfs-probe.py --keep             # don't remove the probe file
    python3 nessfs-probe.py --size 3           # blocks to upload (default 3)

HOUSE RULE, inherited from ness.sh: nothing here invents a number to make a
screen look alive. Every figure printed is measured. A check that could not
run prints `not observed` and is never counted as a pass.

PROOF (client-side half, already verified without a node):
    NessKeys/BlockCryptor.py encrypts each block independently and
    NessKeys/cryptors/Salsa20.py prepends a fresh 8-byte nonce per block:
        cipher = salsa20.new(key=key); return cipher.nonce + cipher.encrypt(data)
    so ciphertext block = 1048576 B, plaintext block = 1048568 B, and block i
    decrypts standalone. Re-run that proof any time with --selftest.
"""

import argparse
import hashlib
import os
import sys
import time

BLOCK = 1024 ** 2          # services/files.py: files.block_size
ADD = 8                    # Salsa20.getBlockAddition() — nonce prepended
RBC = BLOCK - ADD          # 1048568 plaintext bytes per block

# ── reporting, in the ness.sh idiom ─────────────────────────────
# verified : recomputed here, against bytes that came back
# failed   : the check ran and contradicted the claim
# absent   : could not be run — never counted either way
RESULTS = []


def mark(name, state, detail=""):
    RESULTS.append((name, state, detail))
    sym = {"verified": "\033[38;5;178m*\033[0m",
           "failed": "\033[31mx\033[0m",
           "absent": "\033[2m.\033[0m"}[state]
    print(f"  {sym} {name:<34} {state:<9} {detail}")


def selftest():
    """The client-side half. No node, no network, no excuses."""
    sys.path.insert(0, os.getcwd())
    try:
        from NessKeys.cryptors.Salsa20 import Salsa20
    except ImportError:
        mark("block-independent decrypt", "absent",
             "run from a PrivatenessTools checkout (NessKeys not importable)")
        return False

    c = Salsa20()
    if c.getBlockAddition() != ADD:
        mark("nonce width", "failed",
             f"getBlockAddition()={c.getBlockAddition()}, expected {ADD}")
        return False

    key = os.urandom(32)
    n = RBC * 3 + 12345
    pt = bytes((i * 7 + (i >> 16)) & 0xFF for i in range(n))

    ct = b"".join(Salsa20().encrypt(pt[i * RBC:(i + 1) * RBC], key)
                  for i in range((n + RBC - 1) // RBC))

    ok = True
    for i in (2, 0, 3, 1):                     # deliberately out of order
        blk = ct[i * BLOCK:(i + 1) * BLOCK]
        ok &= Salsa20().decrypt(blk, key) == pt[i * RBC:(i + 1) * RBC]

    mark("block-independent decrypt", "verified" if ok else "failed",
         f"{len(ct)} B ciphertext from {n} B plaintext, 4 blocks, out of order")
    return ok


def plaintext_range(off, length):
    """Which ciphertext byte ranges must be fetched to serve a plaintext read."""
    first = off // RBC
    last = (off + length - 1) // RBC
    return [(i, i * BLOCK, (i + 1) * BLOCK - 1) for i in range(first, last + 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=3, help="blocks to upload")
    ap.add_argument("--keep", action="store_true", help="leave the probe file on the node")
    ap.add_argument("--selftest", action="store_true", help="client-side proof only, no node")
    args = ap.parse_args()

    print("\n\033[1m⬢ nessfs-probe\033[0m — does FILES behave the way services/files.py implies?\n")
    print("\033[2m  client-side\033[0m")
    crypto_ok = selftest()
    if args.selftest:
        summary(node_touched=False)
        return 0 if crypto_ok else 1

    print("\n\033[2m  against your node\033[0m")

    try:
        sys.path.insert(0, os.getcwd())
        from framework.Container import Container
        from ness.NessAuth import NessAuth
    except ImportError as e:
        mark("PrivatenessTools import", "absent", f"run from a checkout ({e})")
        summary()
        return 2

    import requests

    try:
        fm = Container.FileManager()
        fm.initKeys()
        svc = fm.files if hasattr(fm, "files") else None
    except Exception as e:
        mark("keys + node selection", "absent", str(e))
        summary()
        return 2
    mark("keys + node selection", "verified", "user selected, node joined")

    # ---- upload a known pattern -------------------------------------------
    n = RBC * args.size + 4242
    pt = bytes((i * 7 + (i >> 16)) & 0xFF for i in range(n))
    want_sha = hashlib.sha256(pt).hexdigest()
    path = f"/tmp/nessfs-probe-{int(time.time())}.bin"
    with open(path, "wb") as f:
        f.write(pt)

    try:
        fm.UploadEncrypt(path)
        fm.saveKeys()
    except Exception as e:
        mark("upload (encrypted)", "failed", str(e))
        summary()
        return 1
    mark("upload (encrypted)", "verified", f"{n} B plaintext, {args.size + 1} blocks")

    # Locate what we just uploaded and build the authed download URL exactly
    # as services/files.py:__fileinfo does.
    try:
        entry = next(e for e in svc.dir()
                     if e.get("size", 0) >= n)          # ciphertext is larger
        file_id = entry["id"]
        node = svc.nodes.findNode(svc.node_name)
        shadow = svc.myNodes.findNode(svc.username, svc.node_name)["shadowname"]
        auth = NessAuth()
        url = (node["url"] + "/files/download/" + file_id + "/" + shadow + "/" +
               auth.auth_id(svc.Users.getPrivateKey(), node["url"], node["nonce"],
                            svc.Users.getUsername(), svc.Users.getNonce()))
    except Exception as e:
        mark("locate uploaded object", "failed", str(e))
        summary()
        return 1
    mark("locate uploaded object", "verified", f"id {file_id[:12]}… size {entry['size']}")

    # ---- THE question: is Range honoured, with a real 206? ----------------
    i = min(2, args.size - 1)
    lo, hi = i * BLOCK, (i + 1) * BLOCK - 1
    r = requests.get(url, headers={"Range": f"bytes={lo}-{hi}"},
                     stream=True, verify=False)

    if r.status_code == 206:
        mark("Range honoured (206)", "verified",
             f"Content-Range: {r.headers.get('Content-Range', '<absent>')}")
    elif r.status_code == 200:
        mark("Range honoured (206)", "failed",
             "200 + full body — every random read costs the whole file")
    else:
        mark("Range honoured (206)", "failed", f"status {r.status_code}")

    body = r.content
    mark("ranged body length", "verified" if len(body) == BLOCK else "failed",
         f"{len(body)} B (expected {BLOCK})")

    # ---- does that lone block decrypt to the right plaintext? -------------
    if len(body) == BLOCK:
        from NessKeys.cryptors.Salsa20 import Salsa20
        # The key is NOT per file. files.json carries no key field at all —
        # its schema is {filename, filepath, size, status, progress, paused,
        # directory}. The salsa20 key lives once per (user, node) in
        # my-nodes.key.json, base64-encoded, and services/files.py uses it for
        # every file on that node:
        #     BlockCryptor(cryptor, bytes(self.node['key'][:32], 'utf8'), ...)
        from base64 import b64decode
        node_entry = svc.myNodes.findNode(svc.username, svc.node_name)
        fkey = node_entry.get("key") if node_entry else None
        if not fkey:
            mark("lone block -> plaintext", "absent",
                 "no node key in my-nodes.key.json for this (user, node)")
        else:
            k = b64decode(fkey)[:32]
            got = Salsa20().decrypt(body, k)
            want = pt[i * RBC:(i + 1) * RBC]
            mark("lone block -> plaintext", "verified" if got == want else "failed",
                 f"block {i}, {len(got)} B, sha256 "
                 f"{hashlib.sha256(got).hexdigest()[:12]}…")
    else:
        mark("lone block -> plaintext", "absent", "no full block to decrypt")

    # ---- out-of-order + resume -------------------------------------------
    order_ok = True
    for j in (args.size, 0, 1):
        if j > args.size:
            continue
        rr = requests.get(url, stream=True, verify=False,
                          headers={"Range": f"bytes={j*BLOCK}-{(j+1)*BLOCK-1}"})
        order_ok &= rr.status_code == 206
    mark("out-of-order block fetch", "verified" if order_ok else "failed",
         "blocks requested descending then ascending")

    mid = BLOCK + 1000
    rr = requests.get(url, headers={"Range": f"bytes={mid}-"},
                      stream=True, verify=False)
    mark("open-ended Range (resume)", "verified" if rr.status_code == 206 else "failed",
         f"bytes={mid}- -> {rr.status_code}")

    if not args.keep:
        try:
            svc.remove(entry["shadowname"] if "shadowname" in entry else file_id)
            mark("probe file removed", "verified", "")
        except Exception as e:
            mark("probe file removed", "absent", f"remove it yourself: {e}")
    os.unlink(path)

    return summary()


def summary(node_touched=True):
    v = sum(1 for _, s, _ in RESULTS if s == "verified")
    f = sum(1 for _, s, _ in RESULTS if s == "failed")
    a = sum(1 for _, s, _ in RESULTS if s == "absent")
    print()
    print(f"  \033[1m{v} verified\033[0m · {f} failed · {a} not observed")
    if not node_touched:
        print("\n  The client-side half holds. \033[2mNo node was contacted, so nothing is"
              "\n  claimed about Range support — run without --selftest for that.\033[0m\n")
    elif f == 0 and a == 0:
        print("\n  A seekable read-only mount is supported by this node.\n")
    elif f:
        print("\n  \033[31mThe ranged-read contract does not hold here.\033[0m "
              "A mount would have to\n  fetch whole files. Read the failed lines above before building on it.\n")
    else:
        print("\n  Some checks could not run. Nothing above is claimed for them.\n")
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
