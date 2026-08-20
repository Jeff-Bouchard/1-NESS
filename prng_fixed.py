"""
Fixes for NessKeys/Prng.py and KeyManager.__keypair_seed.

Four defects, all provable in a few lines. Three are a systematic JS->Python
port artifact: `for (i = 0; i < arguments.length; i++)` became
`range(0, len(arguments) - 1)`, which silently drops the last element — and
when the list has exactly one element, drops everything.

Nothing here changes the algorithm. It makes the algorithm actually run.
"""

import hashlib
import math
import os
import re
import time


class UhePrng:
    """GRC UHEPRNG (public domain), corrected port.

    Changes against the shipped version, each marked FIX:
      1. per-instance state (was a shared mutable class attribute)
      2. all 48 slots seeded (was 47; s[47] stayed 0 and was read every cycle)
      3. seeded from os.urandom, not random.random() (Mersenne Twister)
      4. hash()/mash()/add_entropy() loop over every element, not len-1
    """

    o = 48
    n_init = 0xefc8249d

    def __init__(self):
        # FIX 1: instance state. `s = [0]*48` at class level was shared by
        #        every UhePrng ever constructed in the process.
        # FIX 2: range(self.o), not range(self.o - 1).
        # FIX 3: os.urandom, not random.random(). MT19937 is not a CSPRNG and
        #        has no business anywhere near key material.
        self.c = 1
        self.p = 0
        self.n = self.n_init
        self.s = [0.0] * self.o
        self.seed = ''
        for i in range(self.o):
            self.s[i] = self.mash(int.from_bytes(os.urandom(8), 'big'))

    def raw_prng(self):
        if self.p >= self.o:
            self.p = 0
        t = 1768863 * self.s[self.p] + self.c * 2.3283064365386963e-10
        self.c = int(t)
        self.s[self.p] = t - self.c
        result = self.s[self.p]
        self.p += 1
        return result

    def random(self, rng: int):
        r = self.raw_prng() + (self.raw_prng() * 0x200000) * 1.1102230246251565e-16
        return r if rng == 0 else math.floor(rng * r)

    def string(self, count: int):
        s = ''.join(chr(33 + self.random(94)) for _ in range(count))
        self.seed = s
        return s

    def numbers(self, ln: int, count: int):
        return [self.random(ln) for _ in range(count)]

    def hash(self, *arguments):
        # FIX 4: was range(0, len(arguments) - 1). Called with one argument
        #        that is range(0, 0) — an empty loop. add_entropy() was a
        #        no-op for every caller in the tree.
        for i in range(len(arguments)):
            for j in range(self.o):
                self.s[j] -= self.mash(arguments[i])
                if self.s[j] < 0:
                    self.s[j] += 1

    def init_state(self):
        self.mash(0)
        for i in range(self.o):
            self.s[i] = self.mash(ord(' '))
        self.c = 1
        self.p = self.o

    def clean_string(self, instr: str):
        instr = instr.strip()
        instr = re.sub(r'[\x00-\x1F]', '', instr)
        return instr

    def hash_string(self, instr: str):
        instr = self.clean_string(instr)
        self.mash(instr)
        for i in range(len(instr)):          # FIX 4
            k = ord(instr[i])
            for j in range(self.o):          # FIX 2
                self.s[j] -= self.mash(k)
                if self.s[j] < 0:
                    self.s[j] += 1

    def add_entropy(self, *arguments):
        # FIX 4: args used to be built with range(0, len(arguments) - 1), so
        #        add_entropy(rand, uuid) silently discarded the uuid, and
        #        add_entropy(rand) discarded everything.
        args = [str(a) for a in arguments]
        self.hash(str(time.time()) + ' ' + ''.join(args) +
                  os.urandom(16).hex())      # FIX 3: not random.random()

    def mash(self, data):
        if data == 0:
            self.n = self.n_init
        else:
            data = str(data)
            for i in range(len(data)):       # FIX 4: dropped the last char
                self.n += ord(data[i])
                h = 0.02519603282416938 * self.n
                self.n = int(h)
                h -= self.n
                h *= self.n
                self.n = int(h)
                h -= self.n
                self.n += h * 0x100000000
        return int(self.n) * 2.3283064365386963e-10


# ── the key path ────────────────────────────────────────────────────────
#
# FIX 5, and the one that matters most:
#
#   KeyManager.__keypair_seed does
#       SK = SigningKey(seed)
#       signing_key = SK.generate()          <-- classmethod. Ignores `seed`.
#                                                Returns a NEW key from
#                                                nacl.utils.random.
#
# So every seed the entropy machinery produces is built, then thrown away.
# Keys have been coming from libsodium's CSPRNG all along — which is why
# nobody's key is weak. But it means the entropy level, the '+' marks, and
# the UHEPRNG have had no effect on a single key ever issued.
#
# Correct form: construct from the seed, do not call generate().

def keypair_seed(seed: bytes):
    """Drop-in replacement for KeyManager.__keypair_seed."""
    from base64 import b64decode
    from nacl.encoding import Base64Encoder
    from nacl.public import PrivateKey
    from nacl.signing import SigningKey

    if len(seed) != 32:
        raise ValueError(f"ed25519 seed must be 32 bytes, got {len(seed)}")

    signing_key = SigningKey(seed)                      # FIX 5: no .generate()
    signing__key = signing_key.encode(encoder=Base64Encoder).decode('utf-8')
    private_key = PrivateKey(b64decode(signing__key))
    verify__key = signing_key.verify_key.encode(encoder=Base64Encoder).decode('utf-8')
    public__key = private_key.public_key.encode(encoder=Base64Encoder).decode('utf-8')
    return [signing__key, verify__key, public__key]


def generate_seed(entropy: int, length: int = 32, node_prng=None):
    """Drop-in replacement for KeyManager.__generate_seed.

    Two changes of substance:

    1. Every entropy round is folded into a SHA3-512 accumulator as well as
       into the UHEPRNG. The UHEPRNG stays — it is the project's generator and
       it is a fine expander — but it is no longer the only thing standing
       between a node operator and their key. A defect in it can no longer
       cost anyone their entropy, because the accumulator is unconditional.

    2. `node_prng` is an optional callable returning bytes from the node's
       /prng service. When a node is joined, the flagship supplies entropy to
       its own keygen. It is MIXED, never trusted alone — a node that answers
       /prng is not a node you hand sole authorship of your private key.

    Returns (seed_bytes, sources) so the caller can state what actually
    contributed instead of printing a '+' for work that may not have happened.
    """
    acc = hashlib.sha3_512()
    gen = UhePrng()
    sources = {"os.urandom": 0, "node_prng": 0, "uheprng": 1}

    for _ in range(max(1, entropy)):
        r = os.urandom(1024)
        acc.update(r)
        gen.add_entropy(r.hex())
        sources["os.urandom"] += len(r)

        if node_prng is not None:
            try:
                nr = node_prng()
                if nr:
                    nr = nr if isinstance(nr, bytes) else str(nr).encode()
                    acc.update(nr)
                    gen.add_entropy(nr.hex())
                    sources["node_prng"] += len(nr)
            except Exception:
                pass          # a node that will not answer is not fatal; it is
                              # reported. It never silently becomes a zero.

    # Fold the UHEPRNG output into the accumulator rather than returning it
    # raw. Whichever of the two is stronger, the result is at least that.
    acc.update(gen.string(length).encode('utf-8'))
    return acc.digest()[:length], sources
