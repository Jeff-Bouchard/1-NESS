import os, re, subprocess, sys
P="/tmp/audit/pnt"; S="/tmp/sw"
n=ok=bad=0; fails=[]
def rd(f):
    try: return open(os.path.join(P,f) if not f.startswith("/") else f, encoding="utf-8", errors="replace").read()
    except Exception: return ""
def chk(claim, cond, ev=""):
    global n,ok,bad
    n+=1
    if cond: ok+=1; print(f"  PASS  {claim:<56} {ev}")
    else:    bad+=1; fails.append(claim); print(f"  FAIL  {claim:<56} {ev}")
def cnt(f,pat,flags=0): return len(re.findall(pat, rd(f), flags))

fp=rd("services/files.py"); prng=rd("NessKeys/Prng.py"); km=rd("NessKeys/KeyManager.py")
fm=rd("NessKeys/FileManager.py"); auth=rd("ness/NessAuth.py")

print("── FILES service ──────────────────────────────────────────────────")
chk("block_size = 1 MiB", "block_size = 1024**2" in fp)
chk("9 endpoints under /files/", all(f"/files/{e}" in fp for e in
    ["list","touch","append","fileinfo","download","remove","quota","rewrite","pub"]))
chk("download sends Range: bytes=<pos>-", "'Range': 'bytes=' + str(pos)" in fp)
chk("salsa20 prepends a fresh nonce per block", "cipher.nonce + cipher.encrypt(data)" in rd("NessKeys/cryptors/Salsa20.py"))
chk("getBlockAddition() == 8", re.search(r"def getBlockAddition.*?return 8", rd("NessKeys/cryptors/Salsa20.py"), re.S) is not None)
v=len(re.findall(r"verify=False", "".join(rd(os.path.join(dp,f)) for dp,_,fs in os.walk(P) if "venv" not in dp and "site-packages" not in dp for f in fs if f.endswith(".py"))))
chk("verify=False appears 11 times tree-wide", v==11, f"count={v}")
chk("sync.py is a stub", "Not implemented jet" in rd("sync.py"))
chk("Files per-file schema has NO 'key'", "'key'" not in re.search(r"map = \{\s*'filename'.*?\}", rd("NessKeys/keys/Files.py"), re.S).group(0))
chk("MyNodes per-node schema HAS key+fskey", '"key": str' in rd("NessKeys/keys/MyNodes.py") and '"fskey": str' in rd("NessKeys/keys/MyNodes.py"))
chk("encrypt/decrypt use the NODE key", fp.count("self.node['key']")==2, f"count={fp.count(chr(39).join(['self.node[','key',']']))}")
chk("fileinfo() dict has no cipher/key row",
    "cipher" not in re.search(r"fileinfo = \{.*?\}", fp, re.S).group(0))

print("── entropy ────────────────────────────────────────────────────────")
chk("SK.generate() called on a seeded SigningKey", "signing_key = SK.generate()" in km)
c=prng.count("for i in range(0, len(arguments) - 1)")
chk("empty-loop bug present (hash + add_entropy)", c==2, f"count={c} — appears in BOTH")
chk("UhePrng.s is a CLASS attribute", re.search(r"^\ts = \[0\] \* 48", prng, re.M) is not None)
c2=prng.count("range(0, self.o - 1)")
chk("off-by-one loop appears 4x, not 2", c2==4, f"count={c2} — __init__, hash, init_state, hash_string")
chk("state seeded from random.random() (MT19937)", "self.mash(random.random())" in prng)
allpy="".join(rd(os.path.join(dp,f)) for dp,_,fs in os.walk(P) if "venv" not in dp and "site-packages" not in dp for f in fs if f.endswith(".py"))
chk("__keypairs has zero callers", len(re.findall(r"(?<!def )__keypairs\(", allpy))==0, "def only, no call site")
chk("KeyIndexException never raised/caught", "raise KeyIndexException" not in allpy and "except KeyIndexException" not in allpy)
chk("fskey never read back", not re.search(r"\['fskey'\]|getFskey|getFsKey", allpy))
chk("nonces come from pycryptodome", "get_random_bytes(16)" in km and "from Crypto.Random import get_random_bytes" in km)
chk("FileManager reads /dev/random (not os.urandom)", fm.count("open('/dev/random', 'rb')")==2)
chk("file key = UhePrng.string(32)", "key = generator.string(32)" in fm)
chk("fskey = UhePrng.string(16)", "fskey = generator.string(16)" in fm)

print("── first-run + node key path ──────────────────────────────────────")
u=rd("NessKeys/keys/Users.py")
chk("Users.__users defaults to False", "self.__users = False" in u)
chk("findUser does 'username in self.__users'", "if username in self.__users" in u)
chk("createNodeKey passes a BARE filename", re.search(r'^\s+filename = "node\.key\.json"', km, re.M) is not None)
c3=km.count("filename = self.fileName(")
chk("every other create* uses self.fileName()", c3==11, f"count={c3}")

print("── NVS ────────────────────────────────────────────────────────────")
chk("worm:user:ness:<name>", 'return "worm:user:ness:"' in rd("NessKeys/keys/User.py"))
chk("worm:node:ness:<url>",  'return "worm:node:ness:"' in rd("NessKeys/keys/Node.py"))
chk("name_filter '^worm:node:ness:.+'", "'^worm:node:ness:.+'" in rd("ness/BlockchainRPC.py"))
chk("name_show uses base64", "'base64'" in rd("ness/BlockchainRPC.py"))
chk("'nodes-update blk <args>' is commented out", re.search(r"^\s*# if len\(sys\.argv\) == 6", rd("nodes-update.py"), re.M) is not None)
chk("auth_id signs 4 static values, no time/counter",
    'message = node_url + "-" + node_nonce + "-" + username' in auth and "time" not in auth.split("def auth_id")[1].split("def ")[0])
chk("two-way = SealedBox + ed25519 sig", "SealedBox" in auth and "signature = self.sign(user_private_key, encrypted_data)" in auth)

print("── skywire ────────────────────────────────────────────────────────")
chk("treestore TreeNode/TreeEntry schema", "type TreeEntry struct" in rd(f"{S}/pkg/cxo/treestore/schema.go"))
chk("ptyfs = sftp over dmsgpty + go-fuse", "github.com/pkg/sftp" in rd(f"{S}/cmd/skywire-cli/commands/ptyfs/mount_linux.go"))
chk("serve exposes localhost ports w/ PK allowlist", "Expose localhost ports" in rd(f"{S}/cmd/skywire-cli/commands/serve/serve.go"))
chk("SKYDEPLOY env override", 'os.Getenv("SKYDEPLOY")' in rd(f"{S}/deployment/config_native.go"))
chk("PubKey.DNSLabel is base32, 53 chars", "base32 label (53 chars" in rd(f"{S}/cmd/smb/README.md"))
import base64
raw=bytes.fromhex("03d1d78e7323e1dc63a6cbbf79e52974791e3cd7b5aaab77f045d72a21b066ee8c")
chk("33-byte PK: b64=44 no pad, b32=53, hex=66",
    len(base64.b64encode(raw))==44 and "=" not in base64.b64encode(raw).decode()
    and len(base64.b32encode(raw).decode().lower().rstrip("="))==53 and len(raw.hex())==66)

print()
print(f"  {ok}/{n} verified · {bad} contradicted")
if fails:
    print("\n  CONTRADICTED:")
    for f in fails: print(f"    - {f}")
