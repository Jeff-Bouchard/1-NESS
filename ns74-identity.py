#!/usr/bin/env python3
"""
ns74-identity.py — decentralized identity for the ns74 core-node fleet.

NO SHARED SECRET. Each of the ~21 core-nodes holds only its OWN key, generated
locally, secret never leaving the box. The fleet is bound together not by shared
key material but by a verifiable chain of Emercoin NVS records:

    dpo:ness:ns74            org ownership assertion (EmerDPO)
        |                    owner = PrivateNess org EMC address
    worm:user:ness:<master>  the org master-user identity (existing PrivateNess key)
        |                    each node names this master-user
    worm:node:ness:<url>     per-node record: own verify key, own owner address,
                             master-user="<master>"

A client proves a core-node belongs to ns74 by walking UP the chain:
  node record -> its master-user -> is that master-user owned by the trusted
  org EMC address? If yes, the node is legitimate. Revoke by updating one NVS
  record; add node 22 by publishing one more. Compromising one node's key
  compromises only that node.

Reuses the existing PrivateNess PKI (PrivatenessTools keygen, ed25519, the
worm:node/worm:user format from NESS-Network/NessNode). Does NOT regenerate a
parallel identity system.

Commands:
  gen-node <url> [--tariff N] [--services s] [--master m] [--builtin]
  node-worm <url> --master <name>
  verify-node <worm.xml> --master <name> [--org-addr <emc> --emc-rpc URL]
  discover [--emc-rpc URL]
  nvskey node <url> | nvskey user <master> | nvskey dpo <name>

Requires: pynacl
"""
import argparse, base64, json, os, sys, urllib.request
import xml.etree.ElementTree as ET

try:
    import nacl.signing
except ImportError:
    sys.exit("need pynacl:  pip install pynacl")

DEFAULT_KEYDIR = os.environ.get("NS74_KEYDIR", os.path.expanduser("~/.privateness-keys"))


def emc_call(rpc, user, pw, method, params):
    body = json.dumps({"jsonrpc": "1.0", "id": "ns74-id",
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc, data=body, headers={"Content-Type": "application/json"})
    if user:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def real_keygen_path():
    for cand in ("./keygen", os.path.expanduser("~/PrivatenessTools/keygen"),
                 "/opt/PrivatenessTools/keygen"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _safe(url):
    return url.replace("://", "%3A%2F%2F").replace("/", "%2F")


def gen_node(args):
    keydir = args.keydir or DEFAULT_KEYDIR
    os.makedirs(keydir, exist_ok=True)
    try: os.chmod(keydir, 0o700)
    except Exception: pass
    keyfile = os.path.join(keydir, f"node-{_safe(args.url)}.key.json")

    if os.path.exists(keyfile):
        print(f"node key already exists: {keyfile}", file=sys.stderr)
        print("  refusing to overwrite — this is THIS node's only identity", file=sys.stderr)
        return

    kg = real_keygen_path()
    if kg and not args.builtin:
        import subprocess
        print(f"using PrivatenessTools keygen: {kg}")
        svcs = args.services or "prng,files,dns,vrf"
        cmd = [kg, "node", args.url, str(args.tariff), args.master or "master01",
               svcs, "inet", str(args.entropy)]
        print("  $ " + " ".join(cmd))
        if subprocess.run(cmd).returncode != 0:
            sys.exit("keygen failed")
        print("  key written by keygen into its out/keys/node/ — move it into", keydir)
        return

    print("using built-in ed25519 keygen (PrivatenessTools not found)")
    sign = nacl.signing.SigningKey(os.urandom(32))
    enc = nacl.signing.SigningKey(os.urandom(32))
    key = {
        "type": "ness", "url": args.url, "tariff": args.tariff,
        "services": (args.services or "prng,files,dns,vrf").split(","),
        "master_user": args.master or "",
        "nonce": base64.b64encode(os.urandom(16)).decode(),
        "verify": base64.b64encode(bytes(sign.verify_key)).decode(),
        "public": base64.b64encode(bytes(enc.verify_key)).decode(),
        "_sign_secret": base64.b64encode(bytes(sign)).decode(),
        "_enc_secret": base64.b64encode(bytes(enc)).decode(),
    }
    with open(keyfile, "w") as f:
        json.dump(key, f, indent=2)
    try: os.chmod(keyfile, 0o600)
    except Exception: pass
    print(f"wrote {keyfile}  (0600)")
    print(f"  verify (public) : {key['verify']}")
    print("  THIS node's secret stays here — NOT shared with other nodes.")


def load_node_key(url, keydir):
    keyfile = os.path.join(keydir or DEFAULT_KEYDIR, f"node-{_safe(url)}.key.json")
    if not os.path.exists(keyfile):
        sys.exit(f"no node key at {keyfile} — run gen-node first")
    return json.load(open(keyfile))


def node_worm(args):
    key = load_node_key(args.url, args.keydir)
    master = args.master or key.get("master_user") or ""
    if not master:
        sys.exit("need --master (the org master-user this node chains to)")
    if "_sign_secret" not in key:
        sys.exit("this key was made by real keygen; publish its worm via ./key worm")

    sign = nacl.signing.SigningKey(base64.b64decode(key["_sign_secret"]))
    nonce = base64.b64decode(key["nonce"])
    tags = args.tags or "ns74,core-node"
    content = "|".join(["ns74-node-v1", args.url, master, tags,
                        key["verify"], key["public"]]).encode()
    sig = sign.sign(content + nonce).signature

    root = ET.Element("worm")
    ET.SubElement(root, "node", {
        "type": "ness", "url": args.url, "nonce": key["nonce"],
        "verify": key["verify"], "public": key["public"],
        "master-user": master, "tariff": str(key.get("tariff", 10)),
        "tags": tags, "sig": base64.b64encode(sig).decode(),
    }).text = " "
    sys.stdout.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                     + ET.tostring(root, encoding="unicode") + "\n")
    sys.stderr.write(f"\nNVS key: worm:node:ness:{args.url}\n")


def verify_node(args):
    node = ET.parse(args.file).getroot().find("node")
    if node is None:
        sys.exit("not a worm:node record")
    url = node.get("url"); master = node.get("master-user")
    verify_b64 = node.get("verify"); public_b64 = node.get("public")
    tags = node.get("tags", ""); nonce = base64.b64decode(node.get("nonce"))
    sig = base64.b64decode(node.get("sig"))

    content = "|".join(["ns74-node-v1", url, master, tags, verify_b64, public_b64]).encode()
    try:
        nacl.signing.VerifyKey(base64.b64decode(verify_b64)).verify(content + nonce, sig)
    except Exception:
        print("INVALID — node self-signature does not verify"); sys.exit(1)

    if args.master and master != args.master:
        print(f"INVALID — node chains to '{master}', not trusted '{args.master}'"); sys.exit(1)

    chain_note = "master-user name match (offline)"
    if args.org_addr and args.emc_rpc:
        try:
            rec = emc_call(args.emc_rpc, args.emc_user, args.emc_pass,
                           "name_show", [f"worm:user:ness:{master}"])
            owner = rec.get("address")
            if owner != args.org_addr:
                print(f"INVALID — master-user owned by {owner}, not org {args.org_addr}"); sys.exit(1)
            chain_note = f"full chain verified on-chain (owner {owner})"
        except Exception as e:
            chain_note = f"master-user name matches; on-chain check skipped ({e})"

    print("VALID")
    print(f"  node        : {url}")
    print(f"  master-user : {master}")
    print(f"  verify key  : {verify_b64}")
    print(f"  chain       : {chain_note}")
    print(f"  nvsKey      : worm:node:ness:{url}")


def discover(args):
    rpc = args.emc_rpc
    print(f"querying emercoind at {rpc} for existing ness org records\n")
    found = False; addrs = set()

    def show(name):
        nonlocal found
        try:
            rec = emc_call(rpc, args.emc_user, args.emc_pass, "name_show", [name])
            found = True
            print(f"  FOUND {name}")
            print(f"    owner address : {rec.get('address')}")
            print(f"    value (head)  : {rec.get('value','')[:80]}")
            print()
            return rec.get("address")
        except Exception:
            return None

    print("master-user candidates (worm:user:ness:*):")
    for c in ("privateness", "ness", "master", "master01", "ns74", "privateness01"):
        a = show(f"worm:user:ness:{c}");  addrs.add(a) if a else None
    print("EmerDPO org candidates (dpo:ness:*):")
    for c in ("ness", "ns74", "privateness"):
        a = show(f"dpo:ness:{c}");  addrs.add(a) if a else None

    print("=" * 60)
    if not found:
        print("No existing org records found under the common names.")
        print("=> CREATE the org identity fresh (once):")
        print("   1. keygen user ns74 100   (or reuse a PrivateNess master-user)")
        print("   2. publish worm:user:ness:ns74 to NVS from your org EMC address")
        print("   3. that address = NS74_ORG_ADDRESS ; 'ns74' = NS74_MASTER_USER")
    else:
        print("Org address(es) owning existing ness records:")
        for a in addrs:
            if a: print(f"   {a}")
        print("\n=> Set the PrivateNess-controlled one as NS74_ORG_ADDRESS (trust root),")
        print("   and the matching name as NS74_MASTER_USER. Nodes chain to these.")


def nvskey(args):
    print({"node": f"worm:node:ness:{args.ident}",
           "user": f"worm:user:ness:{args.ident}",
           "dpo":  f"dpo:ness:{args.ident}"}.get(args.kind) or sys.exit("kind=node|user|dpo"))


def main():
    ap = argparse.ArgumentParser(description="ns74 decentralized node identity")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen-node"); g.add_argument("url")
    g.add_argument("--tariff", type=int, default=10); g.add_argument("--services", default="")
    g.add_argument("--master", default=""); g.add_argument("--entropy", type=int, default=100)
    g.add_argument("--keydir", default=""); g.add_argument("--builtin", action="store_true")
    g.set_defaults(func=gen_node)

    w = sub.add_parser("node-worm"); w.add_argument("url")
    w.add_argument("--master", default=""); w.add_argument("--tags", default="")
    w.add_argument("--keydir", default=""); w.set_defaults(func=node_worm)

    v = sub.add_parser("verify-node"); v.add_argument("file")
    v.add_argument("--master", default=""); v.add_argument("--org-addr", default="")
    v.add_argument("--emc-rpc", default="http://127.0.0.1:6662")
    v.add_argument("--emc-user", default=os.getenv("NS74_EMC_USER", ""))
    v.add_argument("--emc-pass", default=os.getenv("NS74_EMC_PASS", ""))
    v.set_defaults(func=verify_node)

    d = sub.add_parser("discover")
    d.add_argument("--emc-rpc", default="http://127.0.0.1:6662")
    d.add_argument("--emc-user", default=os.getenv("NS74_EMC_USER", ""))
    d.add_argument("--emc-pass", default=os.getenv("NS74_EMC_PASS", ""))
    d.set_defaults(func=discover)

    k = sub.add_parser("nvskey"); k.add_argument("kind"); k.add_argument("ident")
    k.set_defaults(func=nvskey)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
