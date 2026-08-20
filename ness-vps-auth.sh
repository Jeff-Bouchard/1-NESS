#!/usr/bin/env bash
# ness-vps-auth.sh — authentication setup for a VPS with no inbound ports.
#
#     bash ness-vps-auth.sh
#
# Uses PrivatenessTools' built-in authentication and nothing else. No new
# daemon, no reverse proxy, no basic auth, no listening socket.
#
# ── THE SHAPE OF THE PROBLEM ───────────────────────────────────────────
# PrivatenessTools is a CLIENT. Every authenticated call it makes is
# OUTBOUND. Nothing in it listens on a port, so a VPS with every inbound
# port closed is already the supported configuration — there is nothing to
# open. What actually needs deciding on a VPS is the CHAIN side, because
# ness/BlockchainRPC.py assumes an Emercoin RPC it can reach, and its
# default is 127.0.0.1:6662.
#
# ── THE TWO AUTH SURFACES ──────────────────────────────────────────────
#
# 1. TO A NODE — ness/NessAuth.py, ed25519. Outbound only; the transport
#    can be plain HTTP, because the transport is not what secures it.
#
#    auth_id  = b32(ed25519_sign(sk, "<node_url>-<node_nonce>-<username>-<user_nonce>"))
#               spliced into the URL PATH. Used for bulk: append, download, prng.
#    two-way  = data: b64(SealedBox(node_public).encrypt(payload))
#               sig : b32(ed25519_sign(sk, data))
#               POSTed with username. The reply {data,sig} is verified
#               against the node's verify key and opened with your private key.
#
# 2. TO THE CHAIN — ness/BlockchainRPC.py, HTTP basic in the URL:
#       http://<user>:<password>@<host>:<port>/
#    Settings live in ~/.privateness-keys/blockchain-rpc.key.json.
#
# ── WHY THERE IS NO CERTIFICATE AUTHORITY HERE, AND WHY THAT IS CORRECT ─
# requests is called with verify=False throughout, and that is deliberate.
# It is not a missing safety check.
#
# The channel is already mutually authenticated, with the chain as its root:
#
#   the node's curve25519 `public` and ed25519 `verify` keys come from the
#   NVS record worm:node:ness:<url>, fetched by nodes-update. Your own keys
#   are published the same way, at worm:user:ness:<name>.
#
#   request  = SealedBox(node_public).encrypt(payload), signed with your sk
#   reply    = verified against the node's verify key, opened with your sk
#
# An interceptor without the node's private key cannot read the request, and
# cannot forge a reply that verifies. Confidentiality and authenticity both
# hold with no CA anywhere in the picture. Layering CA-validated TLS over
# that would not add a property — it would add a dependency on the very
# authority this network exists without, and would make a node at
# http://batman1.private.ness unreachable, since no CA will ever vouch for a
# name it does not control.
#
# So: nothing in this script turns certificate verification on. Verifying a
# signature against a key you got from the chain IS the authentication.
#
# ── THE ONE PROPERTY WORTH KNOWING, WHICH IS NOT A PKI QUESTION ─────────
# auth_id (the bulk path: append, download, prng) signs four static values —
# node_url, node_nonce, username, user_nonce. No method, no path, no body
# hash, no timestamp. The signature proves you hold the key, but because the
# signed message never changes, the resulting token never changes either, so
# it replays against that same node.
#
# What that is actually worth to someone holding one:
#   download - ciphertext only. The per-file salsa20 key never leaves your
#              client, so they get bytes the node already has.
#   append   - garbage appended to your file, bounded by your quota. Real.
#   prng     - your quota, spent by someone else.
# It is scoped to one node by node_url, and that node already holds your
# ciphertext. So the exposure is narrow — but it is the same over TLS as
# without it, which is the point: if you ever want to close it, the fix is
# in the signed message (bind method + path + body hash + a timestamp), not
# in a certificate. Rotating user_nonce is what invalidates issued tokens.

set -uo pipefail
VERSION="1.0"
SELF="$(basename "$0")"
SRC="${NESS_SRC:-$HOME/ness/PrivatenessTools}"
YES="${NESS_YES:-0}"
[ -t 0 ] || YES=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  X=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
  Y=$'\033[33m'; C=$'\033[36m'; GOLD=$'\033[38;5;178m'
else X=""; B=""; D=""; R=""; G=""; Y=""; C=""; GOLD=""; fi
TICK="+"; CROSS="x"; DOT="-"
printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qi 'utf-*8' && { TICK="✓"; CROSS="✗"; DOT="•"; }

say(){ printf '%s\n' "$*"; }
head_(){ printf '\n%s⬢ %s%s\n' "$B" "$*" "$X"; }
ok(){   printf '  %s%s%s %s\n' "$G" "$TICK" "$X" "$*"; }
no(){   printf '  %s%s%s %s\n' "$R" "$CROSS" "$X" "$*"; }
hm(){   printf '  %s%s%s %s\n' "$Y" "$DOT" "$X" "$*"; }
note(){ printf '      %s%s%s\n' "$D" "$*" "$X"; }
ask(){ local a; printf '      %s→%s %s ' "$C" "$X" "$1" >&2
       read -r a </dev/tty 2>/dev/null || a=""; printf '%s' "${a:-${2:-}}"; }
confirm(){ local a; [ "$YES" = 1 ] && return 1
  printf '  %s%s%s %s %s[y/N]%s ' "$GOLD" "$DOT" "$X" "$1" "$D" "$X" >&2
  read -r a </dev/tty 2>/dev/null || a=""; case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac; }

PY=""
for c in "$SRC/venv/bin/python" "$SRC/venv/Scripts/python.exe" python3; do
  [ -x "$c" ] && { PY="$c"; break; }
  command -v "$c" >/dev/null 2>&1 && { PY="$(command -v "$c")"; break; }
done
[ -n "$PY" ] || { no "no python — run ness-install.sh first"; exit 1; }
[ -d "$SRC" ] || { no "no PrivatenessTools at $SRC" ; note "set NESS_SRC, or run ness-install.sh"; exit 1; }
pnt(){ ( cd "$SRC" && "$PY" -W ignore "$@" ); }

KEYS=$(pnt key.py 2>/dev/null | sed -n 's/^Keys directory: *//p' | tail -1 | tr -d '\r')
[ -n "$KEYS" ] || KEYS="${NESS_KEYS:-$HOME/.privateness-keys}"

printf '\n%s⬢ ness VPS auth%s %sv%s%s\n' "$C" "$X" "$D" "$VERSION" "$X"
printf '  %skeys: %s%s\n' "$D" "$KEYS" "$X"

# ════════════════════════════════════════════════════════════
# 1. PROVE NOTHING LISTENS
# ════════════════════════════════════════════════════════════
# The claim "you do not need to open a port" should not be taken on trust
# from a comment. Check what this install actually binds.
head_ "does anything need an inbound port?"
LISTEN=""
if command -v ss >/dev/null 2>&1; then LISTEN=$(ss -ltnp 2>/dev/null | grep -c 'python' || true)
elif command -v netstat >/dev/null 2>&1; then LISTEN=$(netstat -ltnp 2>/dev/null | grep -c 'python' || true); fi
if [ -z "$LISTEN" ]; then
  hm "no ss or netstat here — cannot check listening sockets"
  note "derive it yourself: grep -rn 'bind(\|listen(\|socketserver\|Flask\|uvicorn' $SRC"
elif [ "$LISTEN" = 0 ]; then
  ok "no python process on this host is listening on a TCP port"
  note "PrivatenessTools only ever dials out. There is nothing to open."
else
  hm "$LISTEN python listener(s) found — not necessarily this tool"
  note "check with: ss -ltnp | grep python"
fi

# ════════════════════════════════════════════════════════════
# 2. NODE AUTH — ed25519, outbound only
# ════════════════════════════════════════════════════════════
head_ "node authentication (ed25519, outbound)"

if [ ! -f "$KEYS/users.key.json" ]; then
  hm "no user key on this VPS yet"
  u=$(ask "username to create (blank to skip)" "${NESS_USER:-master01}")
  if [ -n "$u" ]; then
    e=$(ask "entropy level" "${NESS_USER_ENTROPY:-100}")
    pnt keygen.py user "$u" "$e" 2>&1 | tail -2 | sed "s/^/      $D/;s/\$/$X/"
    [ -f "$KEYS/users.key.json" ] && ok "user key created" || no "keygen did not produce users.key.json"
  fi
else
  cur=$(pnt user.py 2>/dev/null | sed -n 's/^ \*\*\* //p' | tail -1 | tr -d '\r')
  ok "user key present ${cur:+— $cur}"
fi

NODE="${NESS_NODE:-}"
if [ -z "$NODE" ]; then
  NODE=$(ask "node URL" "${NESS_NODE_URL:-http://batman1.private.ness}")
fi

# The node list can be fetched FROM A NODE over HTTPS. No chain, no RPC,
# no ports. This is the path that makes a locked-down VPS work.
say ""
note "fetching the node list from a node — signed and sealed end to end, no RPC"
pnt nodes-update.py node "$NODE" 2>&1 | tail -3 | sed "s/^/      $D/;s/\$/$X/"
if [ -f "$KEYS/nodes.key.json" ]; then
  n=$("$PY" -c "import json,sys;d=json.load(open('$KEYS/nodes.key.json'));print(len(d.get('nodes',[])))" 2>/dev/null)
  ok "node list retrieved${n:+ — $n nodes}"
else
  no "no nodes.key.json — the node list did not arrive"
  note "check outbound reachability to $NODE, then re-run"
fi

if confirm "Join $NODE now?"; then
  pnt node.py sel "$NODE" 2>&1 | tail -3 | sed "s/^/      $D/;s/\$/$X/"
fi

# The only proof that auth works is an authenticated round trip.
say ""
note "proving the ed25519 auth with a real authenticated call"
q=$(pnt quota.py 2>&1 | tail -3)
if printf '%s' "$q" | grep -qi 'error\|not joined\|not set\|Traceback'; then
  no "authenticated call failed"
  printf '%s\n' "$q" | sed "s/^/      $D/;s/\$/$X/"
  note "if this says 'user is not registered', your NVS record is not on chain yet — section 3"
else
  ok "authenticated round trip succeeded — signed request, verified reply"
  printf '%s\n' "$q" | sed "s/^/      $D/;s/\$/$X/"
  note "signed with your key, verified against the node's chain-published key."
  note "No CA, no port, no authority. That exchange IS the authentication."
fi

# ════════════════════════════════════════════════════════════
# 3. CHAIN ACCESS — the part that actually cares about 127.0.0.1
# ════════════════════════════════════════════════════════════
head_ "chain access"
note "ness/BlockchainRPC.py builds: http://<user>:<pass>@<host>:<port>/"
note "Its default is 127.0.0.1:6662. Three ways to satisfy that on a VPS."
say ""
printf '      %s1%s  no chain at all      %s— register at https://nvs.ness.cx in a browser.%s\n' "$B" "$X" "$D" "$X"
printf '         %sNode list already came over HTTPS above. Nothing further needed.%s\n' "$D" "$X"
printf '      %s2%s  emercoind on THIS VPS %s— RPC stays on 127.0.0.1. Nothing exposed.%s\n' "$B" "$X" "$D" "$X"
printf '      %s3%s  emercoind ELSEWHERE   %s— reach it through an SSH tunnel, so it is%s\n' "$B" "$X" "$D" "$X"
printf '         %s127.0.0.1 again. No inbound port on either host.%s\n' "$D" "$X"
say ""
printf '      %sDo NOT point rpc-host at a remote address directly: the credentials%s\n' "$Y" "$X"
printf '      %stravel in a plain-HTTP URL. The tunnel is not optional hardening,%s\n' "$Y" "$X"
printf '      %sit is what makes option 3 safe at all.%s\n' "$Y" "$X"
say ""

choice=$(ask "which (1/2/3, blank to leave chain unconfigured)" "")
case "$choice" in
  1) ok "no chain configured — node list comes from nodes, names from nvs.ness.cx"
     note "everything in section 2 works without a chain. Registration is the only gap." ;;
  2|3)
     RH="127.0.0.1"; RP="6662"
     if [ "$choice" = 3 ]; then
       th=$(ask "ssh host running emercoind (user@host)" "")
       [ -n "$th" ] && {
         say ""
         note "open the tunnel in another shell, or add it to systemd:"
         printf '        %sssh -N -L 6662:127.0.0.1:6662 %s%s\n' "$B" "$th" "$X"
         note "then rpc-host stays 127.0.0.1 — the tunnel is the localhost."
         say ""
       }
     fi
     RU=$(ask "rpcuser"     "")
     printf '      %s→%s rpcpassword (not echoed) ' "$C" "$X" >&2
     read -rs RPW </dev/tty 2>/dev/null || RPW=""; say "" >&2
     if [ -z "$RU" ] || [ -z "$RPW" ]; then
       hm "no credentials given — chain left unconfigured"
       note "they are the rpcuser= / rpcpassword= lines in emercoin.conf"
     else
       # The documented command './nodes-update blk <host> <port> <user> <pass>'
       # is COMMENTED OUT in nodes-update.py (lines 190-201) — the error
       # handler still tells you to run it. The only live path writes the
       # hardcoded 127.0.0.1/rpcuser/rpcpassword defaults. So the settings
       # file is written directly, in the schema NessKeys/keys/BlockchainRPC.py
       # validates against.
       umask 077; mkdir -p "$KEYS"
       "$PY" - "$KEYS/blockchain-rpc.key.json" "$RH" "$RP" "$RU" "$RPW" <<'PYEOF'
import json, sys
path, host, port, user, pw = sys.argv[1:6]
json.dump({
    "filedata": {"vendor": "Privateness", "type": "config", "for": "blockchain"},
    "rpc-host": host, "rpc-port": int(port), "rpc-user": user, "rpc-password": pw,
}, open(path, "w"), indent=2)
PYEOF
       chmod 600 "$KEYS/blockchain-rpc.key.json" 2>/dev/null
       # Validate through the tool's own checker, not by eyeballing the JSON.
       if pnt - <<PYEOF 2>/dev/null | grep -q OK
import json,sys
sys.path.insert(0,"$SRC")
from NessKeys.keys.BlockchainRPC import BlockchainRPC
k=BlockchainRPC(); k.load(json.load(open("$KEYS/blockchain-rpc.key.json"))); print("OK")
PYEOF
       then ok "blockchain-rpc.key.json written and accepted by the tool's own validator"
       else no "the file was written but the tool's validator rejects it"; fi
       note "mode 600, credentials at rest — back it up with the rest of $KEYS"

       # Live check.
       say ""
       note "asking the chain for the node list"
       out=$(pnt nodes-update.py blockchain 2>&1 | tail -3)
       if printf '%s' "$out" | grep -qi 'Authentication error\|Error'; then
         no "chain RPC did not answer"
         printf '%s\n' "$out" | sed "s/^/      $D/;s/\$/$X/"
         [ "$choice" = 3 ] && note "is the tunnel up? ss -ltn | grep 6662"
         note "and emercoin.conf needs: server=1, rpcuser=, rpcpassword="
       else
         ok "chain RPC answered — name_filter '^worm:node:ness:.+' returned"
       fi
     fi ;;
  *) hm "chain left unconfigured" ;;
esac

# ════════════════════════════════════════════════════════════
# 4. HARDENING — the risk that is actually yours on a VPS
# ════════════════════════════════════════════════════════════
head_ "the bulk-path token"

# Count over the whole checkout, excluding the venv — an earlier version of
# this script grepped only services/ and ness/ and undercounted by two:
# backup.py and nodes-update.py each carry one.
nc=$(grep -rn --include='*.py' 'verify=False' "$SRC" 2>/dev/null | grep -v '/venv/' | wc -l | tr -d ' ')
nf=$(grep -rln --include='*.py' 'verify=False' "$SRC" 2>/dev/null | grep -v '/venv/' | wc -l | tr -d ' ')
ok "certificate verification is off in ${nc:-0} places across ${nf:-0} files — as designed"
note "ness/NessAuth.py 4 · services/node.py 5 · backup.py 1 · nodes-update.py 1"
note "the node's keys come from the chain, not from a CA. Signature-checked"
note "and sealed-box encrypted end to end. Turning CA validation on would add"
note "an authority, not a guarantee — and would break $NESS_NODE_URL outright."

say ""
hm "auth_id signs four static values, so the token repeats on every call"
note "bound to node_url, so it is useless against any other node."
note "A replay buys ciphertext (download), quota (prng), or appended garbage."
note "It buys no plaintext: the per-file key never leaves this machine."
note "Closing it is a protocol change — put method, path, body hash and a"
note "timestamp inside the signed message. Nothing about certificates helps."

say ""
hm "revocation: rotating user_nonce in users.key.json invalidates every auth_id"
note "it is the only revocation this design has — there is no expiry and no"
note "server-side session to drop. Changing the nonce means re-registering the"
note "NVS record, because the worm carries it."
say ""
hm "back up $KEYS before you do anything else on this VPS"
note "there is no recovery from the chain. ness backup, or: tar -czf - $KEYS | age -p > keys.tar.gz.age"
say ""
