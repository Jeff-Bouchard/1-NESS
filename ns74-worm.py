#!/usr/bin/env python3
"""
ns74-worm.py — publish ns74's public configs as signed WORM objects.

Eat our own dog food: every publicly-shareable ns74 artifact (DNS stamps, the
x402 manifest, the resolver descriptor) is emitted as a signed WORM record in
the same format the NESS network already uses (Alex014/WORM, NessNode), keyed
into Emercoin NVS under  worm:ns74:<name>. Anyone can verify it; nobody can
forge or silently alter it; it's anchored on-chain, not sitting as a mutable
file on a box.

The signing identity is DERIVED from the fleet master seed (SLIP-0010 ed25519,
path m/7'/74'/6' = worm publishing), so THIS node signs its own public configs
with its own key, derived from its own local gate seed. A rebuilt node
reproduces its own key. Fleet identity is a SEPARATE, per-node key (see
ns74-identity.py); this seed is never shared between nodes.

WORM format (from NESS-Network/NessNode):
    <worm>
      <config type="ness" service="ns74" name="..." nonce="<b64 salt>"
              tags="..." verify="<b64 ed25519 verify key>" sig="<b64 sig>">
        <payload>
      </config>
    </worm>
NVS record:  worm:ns74:<name>  ->  the XML above

Commands:
    ns74-worm.py sign   <master.seed> <name> [--tags a,b] [--file f | --stdin]
    ns74-worm.py verify <worm.xml>
    ns74-worm.py nvskey <name>                 # prints the NVS key
    ns74-worm.py publish <master.seed> <name> ... --emc-rpc URL --emc-user U --emc-pass P

Requires: pynacl
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

try:
    import nacl.signing
except ImportError:
    sys.exit("need pynacl:  pip install pynacl")

HARDENED = 0x80000000
WORM_PATH = [7 + HARDENED, 74 + HARDENED, 6 + HARDENED]  # worm publishing identity


def _master(seed):
    I = hmac.new(b"ed25519 seed", seed, hashlib.sha512).digest()
    return I[:32], I[32:]


def _ckd(k, c, i):
    I = hmac.new(c, b"\x00" + k + i.to_bytes(4, "big"), hashlib.sha512).digest()
    return I[:32], I[32:]


def derive_signing_key(seed):
    k, c = _master(seed)
    for i in WORM_PATH:
        k, c = _ckd(k, c, i)
    return nacl.signing.SigningKey(k)


def load_seed(path):
    raw = open(path).read().strip()
    seed = bytes.fromhex(raw)
    if len(seed) < 16:
        sys.exit("master seed must be hex, >=16 bytes")
    return seed


def canonical(name, payload, nonce, tags):
    # what gets signed: a stable join of the fields that matter, so verification
    # is independent of XML whitespace/attribute order.
    return b"|".join([
        b"ns74-worm-v1", name.encode(), tags.encode(),
        base64.b64encode(nonce), payload.encode(),
    ])


def cmd_sign(args):
    seed = load_seed(args.seed)
    sk = derive_signing_key(seed)
    verify_key = bytes(sk.verify_key)

    if args.file:
        payload = open(args.file).read().strip()
    elif args.stdin:
        payload = sys.stdin.read().strip()
    else:
        sys.exit("need --file or --stdin for the payload")

    nonce = os.urandom(16)
    tags = args.tags or "ns74"
    sig = sk.sign(canonical(args.name, payload, nonce, tags)).signature

    root = ET.Element("worm")
    cfg = ET.SubElement(root, "config", {
        "type": "ness", "service": "ns74", "name": args.name,
        "nonce": base64.b64encode(nonce).decode(),
        "tags": tags,
        "verify": base64.b64encode(verify_key).decode(),
        "sig": base64.b64encode(sig).decode(),
    })
    cfg.text = "\n    " + payload + "\n  "
    xml = ET.tostring(root, encoding="unicode")
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + xml + "\n"
    sys.stdout.write(xml)


def cmd_verify(args):
    tree = ET.parse(args.file)
    cfg = tree.getroot().find("config")
    if cfg is None:
        sys.exit("not a WORM config record")
    name = cfg.get("name")
    tags = cfg.get("tags", "")
    nonce = base64.b64decode(cfg.get("nonce"))
    verify_key = base64.b64decode(cfg.get("verify"))
    sig = base64.b64decode(cfg.get("sig"))
    payload = (cfg.text or "").strip()

    vk = nacl.signing.VerifyKey(verify_key)
    try:
        vk.verify(canonical(name, payload, nonce, tags), sig)
    except Exception:
        print("INVALID — signature does not verify"); sys.exit(1)
    print("VALID")
    print(f"  name   : {name}")
    print(f"  tags   : {tags}")
    print(f"  verify : {cfg.get('verify')}")
    print(f"  nvsKey : worm:ns74:{name}")


def cmd_nvskey(args):
    print(f"worm:ns74:{args.name}")


def emc_call(rpc, user, pw, method, params):
    body = json.dumps({"jsonrpc": "1.0", "id": "ns74-worm",
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc, data=body,
                                 headers={"Content-Type": "application/json"})
    if user:
        tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
        req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def cmd_publish(args):
    # build the signed record, then write it to NVS via the node's own emercoind.
    import io
    buf = io.StringIO()
    _stdout = sys.stdout
    sys.stdout = buf
    cmd_sign(args)
    sys.stdout = _stdout
    xml = buf.getvalue()

    key = f"worm:ns74:{args.name}"
    days = args.days
    # name_new <name> <value> <days> — anchors the WORM record on-chain
    try:
        txid = emc_call(args.emc_rpc, args.emc_user, args.emc_pass,
                        "name_new", [key, xml, days])
        print(f"published {key}")
        print(f"  txid: {txid}")
        print(f"  ttl : {days} days")
    except Exception as e:
        print("NVS publish failed:", e, file=sys.stderr)
        print("\nThe signed record (publish manually via NVS exchange nvs.ness.cx):\n")
        print(xml)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="ns74 WORM config publisher")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sign", help="emit a signed WORM record")
    s.add_argument("seed"); s.add_argument("name")
    s.add_argument("--tags"); s.add_argument("--file"); s.add_argument("--stdin", action="store_true")
    s.set_defaults(func=cmd_sign)

    v = sub.add_parser("verify", help="verify a WORM record")
    v.add_argument("file"); v.set_defaults(func=cmd_verify)

    k = sub.add_parser("nvskey", help="print the NVS key for a name")
    k.add_argument("name"); k.set_defaults(func=cmd_nvskey)

    p = sub.add_parser("publish", help="sign and write to NVS via emercoind")
    p.add_argument("seed"); p.add_argument("name")
    p.add_argument("--tags"); p.add_argument("--file"); p.add_argument("--stdin", action="store_true")
    p.add_argument("--days", type=int, default=365)
    p.add_argument("--emc-rpc", default="http://127.0.0.1:6662")
    p.add_argument("--emc-user", default=os.getenv("NS74_EMC_USER", ""))
    p.add_argument("--emc-pass", default=os.getenv("NS74_EMC_PASS", ""))
    p.set_defaults(func=cmd_publish)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
