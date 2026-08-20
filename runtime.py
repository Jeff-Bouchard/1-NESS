import base64, json, os, subprocess, sys, tempfile
sys.path.insert(0,"/tmp/audit/pnt"); os.chdir("/tmp/audit/pnt")
n=ok=bad=0; fails=[]
def chk(c,cond,ev=""):
    global n,ok,bad
    n+=1
    if cond: ok+=1; print(f"  PASS  {c:<52} {ev}")
    else: bad+=1; fails.append(c); print(f"  FAIL  {c:<52} {ev}")

print("── executed, not grepped ──────────────────────────────────────")

# 1. block-independent decryption
from NessKeys.cryptors.Salsa20 import Salsa20
BLOCK=1024**2; RBC=BLOCK-8
key=os.urandom(32); nbytes=RBC*3+12345
pt=bytes((i*7+(i>>16))&0xFF for i in range(nbytes))
ct=b"".join(Salsa20().encrypt(pt[i*RBC:(i+1)*RBC],key) for i in range(4))
good=all(Salsa20().decrypt(ct[i*BLOCK:(i+1)*BLOCK],key)==pt[i*RBC:(i+1)*RBC] for i in (2,0,3,1))
chk("block i decrypts alone, out of order", good, f"ct={len(ct)}B pt={nbytes}B")
chk("plaintext block 1048568 / ciphertext 1048576", RBC==1048568 and len(ct[:BLOCK])==1048576)

# 2. add_entropy is a no-op
import NessKeys.Prng as P
g=P.UhePrng(); before=list(g.s)
for _ in range(100): g.add_entropy(os.urandom(1024).hex(), "x")
chk("100 rounds of add_entropy change nothing", list(g.s)==before)

# 3. entropy level is decorative
import random
def gen(e):
    G=P.UhePrng()
    for _ in range(e): G.add_entropy(os.urandom(1024).hex(),"x")
    return G.string(32)
random.seed(7); a=gen(100)
random.seed(7); b=gen(1)
chk("entropy=100 and entropy=1 are identical", a==b)

# 4. shared class state
x,y=P.UhePrng(),P.UhePrng()
chk("two instances share one state array", x.s is y.s)

# 5. SK.generate() discards the seed
from nacl.signing import SigningKey
from nacl.encoding import Base64Encoder
s=b"\x01"*32
k1=SigningKey(s).generate().encode(Base64Encoder); k2=SigningKey(s).generate().encode(Base64Encoder)
chk("SigningKey(seed).generate() ignores the seed", k1!=k2)
chk("SigningKey(seed) alone DOES honour it",
    SigningKey(s).encode(Base64Encoder)==SigningKey(s).encode(Base64Encoder))

# 6. first-run blocker
env=dict(os.environ); env["HOME"]=tempfile.mkdtemp()
r=subprocess.run(["./venv/bin/python","-W","ignore","keygen.py","user","probe","3"],
                 capture_output=True,text=True,env=env)
chk("fresh machine cannot create first user key",
    "argument of type 'bool' is not iterable" in r.stderr,
    "TypeError in Users.findUser")

# 7. node key lands in cwd, not the keys dir
h=tempfile.mkdtemp(); env["HOME"]=h
os.makedirs(os.path.join(h,".privateness-keys"),exist_ok=True)
json.dump({"filedata":{"vendor":"Privateness","type":"key","for":"user"},"current":"u",
 "users":{"u":{"username":"u","private":base64.b64encode(os.urandom(32)).decode(),
 "public":base64.b64encode(os.urandom(32)).decode(),"verify":base64.b64encode(os.urandom(32)).decode(),
 "nonce":"AA==","signatures":{}}}}, open(os.path.join(h,".privateness-keys","users.key.json"),"w"))
if os.path.exists("node.key.json"): os.unlink("node.key.json")
subprocess.run(["./venv/bin/python","-W","ignore","keygen.py","node","http://x.test","1000","u","prng,files","inet","2"],
               capture_output=True,text=True,env=env)
in_cwd=os.path.exists("node.key.json")
in_keys=os.path.exists(os.path.join(h,".privateness-keys","node.key.json"))
chk("node key lands in CWD, not the keys dir", in_cwd and not in_keys,
    f"cwd={in_cwd} keysdir={in_keys}")
if in_cwd: os.unlink("node.key.json")

print()
print(f"  {ok}/{n} verified · {bad} contradicted")
for f in fails: print(f"    - {f}")
