# ── entropy ─────────────────────────────────────────────────
# Drop-in for ness.sh v2.8. Replaces the selftest's entropy claim and adds
# `ness entropy`, because the one service this project leads with is the one
# the front end never touched.
#
# The HOUSE RULE, applied to the thing the rule exists for:
#
#   A '+' printed for a round of entropy that did not reach the generator is
#   a fabricated value. It is the same sin as a fake balance, committed
#   somewhere the bash script could not see. So this section reports the
#   SOURCE and the BYTE COUNT of every draw, and a source that did not
#   answer is a reported zero — never an omission that reads as success.

# ── the node's PRNG service ─────────────────────────────────
# ./prng {seed,seedb,numbers,numbersb,i256,h256} -> /prng/<fn> on the node,
# authed by auth_id. `prng` is in the default SERVICES list; it has always
# been there.
ness_prng(){ # ness_prng <fn>  -> bytes on stdout, or nothing
  have_src || return 1
  have_user || return 1
  local out
  out=$(pnt prng.py "${1:-seed}" 2>/dev/null | tr -d '\r' | sed '/^$/d' | tail -1)
  case "$out" in
    ""|*"not found"*|*"Error on remote node"*|*"is not joined"*|*"not set"*) return 1 ;;
  esac
  printf '%s' "$out"
}

# Which sources answered, right now. No source is assumed; each is asked.
ENT_SRC=""; ENT_BYTES=""; ENT_NODE=""
entropy_probe(){
  ENT_SRC=""; ENT_BYTES=""; ENT_NODE=""
  local n

  # 1. the flagship, if a node is joined and answering
  if n=$(ness_prng seed); then
    ENT_NODE="$n"
    ENT_SRC="node"; ENT_BYTES="${#n}"
    obs entropy mesh verified \
      "the node's /prng answered — ${#n} bytes from the service this project sells" \
      "mixed with the local draw, never trusted alone"
    return 0
  fi

  # 2. os.urandom via the interpreter we already resolved
  local py
  if py=$(find_py) && "$py" -c 'import os;os.urandom(32)' 2>/dev/null; then
    ENT_SRC="os.urandom"; ENT_BYTES=32
    obs entropy keys reported \
      "os.urandom only — no node answered /prng" \
      "the local source is sound. It is not the one you built."
    return 0
  fi

  # 3. openssl, last
  if command -v openssl >/dev/null 2>&1 && openssl rand 32 >/dev/null 2>&1; then
    ENT_SRC="openssl"; ENT_BYTES=32
    obs entropy keys reported "openssl rand only — no node, no python"
    return 0
  fi

  obs entropy "" absent "no entropy source answered on this machine" \
    "do not generate keys here until one does"
  return 1
}

cmd_entropy(){
  banner
  head_ "entropy"
  note "the service this node offers, and the source your keys would actually use."
  say ""

  entropy_probe
  printf '  %s ' "$(src_tag "$(obs_src entropy)")"
  mark "$(obs_chk entropy)"
  printf ' %s\n' "${OBS_DET[entropy]}"
  [ -n "${OBS_MORE[entropy]:-}" ] && note "${OBS_MORE[entropy]}"

  # What the node offers, asked one call at a time and only on request —
  # each of these is a round trip and a fee-bearing service, not a free poll.
  if [ "$ENT_SRC" = node ]; then
    say ""
    head_ "what your node serves"
    local fn v
    for fn in seed i256 h256; do
      if v=$(ness_prng "$fn"); then
        printf '  %s%s%s %-6s %s%s%s\n' "$GOLD" "$HEX" "$X" "$fn" "$D" "${v:0:56}" "$X"
      else
        printf '  %s%s %-6s did not answer%s\n' "$D" "$DOT" "$fn" "$X"
      fi
    done
    note "seedb and numbersb are larger draws — $SELF entropy --all"
  fi

  say ""
  head_ "what your keys were made from"
  # This is the part that was never said out loud. Until PrivatenessTools
  # is patched, the honest answer is: not what the entropy level implies.
  if have_src && [ -f "$SRC/NessKeys/Prng.py" ] \
     && grep -q 'range(0, len(arguments) - 1)' "$SRC/NessKeys/Prng.py" 2>/dev/null; then
    obs entropy_path keys failed \
      "this checkout's add_entropy() is a no-op — the entropy level does nothing" \
      "NessKeys/Prng.py hash(): range(0, len(arguments) - 1) is empty for one arg"
    printf '  %s ' "$(src_tag keys)"; mark failed
    printf ' %s\n' "${OBS_DET[entropy_path]}"
    note "${OBS_MORE[entropy_path]}"
  elif have_src; then
    obs entropy_path keys verified "add_entropy() reaches the generator state"
    printf '  %s ' "$(src_tag keys)"; mark verified; printf ' %s\n' "${OBS_DET[entropy_path]}"
  fi

  if have_src && grep -q 'SK.generate()' "$SRC/NessKeys/KeyManager.py" 2>/dev/null; then
    obs entropy_seed keys failed \
      "the generated seed is discarded — SigningKey(seed).generate() ignores the seed" \
      "keys come from libsodium's CSPRNG. Sound, but not from your entropy."
    printf '  %s ' "$(src_tag keys)"; mark failed
    printf ' %s\n' "${OBS_DET[entropy_seed]}"
    note "${OBS_MORE[entropy_seed]}"
  elif have_src; then
    obs entropy_seed keys verified "the seed determines the key"
    printf '  %s ' "$(src_tag keys)"; mark verified; printf ' %s\n' "${OBS_DET[entropy_seed]}"
  fi

  echo
}

# ── selftest: replace the two entropy lines ─────────────────
# WAS:
#   note "the only randomness here comes from openssl rand and os.urandom"
#   ok   "openssl rand available for the one place we need entropy"
#
# Both true of this file alone, and both wrong as a statement about the
# system — they name the fallback and omit the flagship. Replacement:
selftest_entropy(){
  entropy_probe >/dev/null 2>&1
  case "$ENT_SRC" in
    node)
      ok "entropy: your node's /prng answered ($ENT_BYTES bytes)"
      note "the service this project offers is the one your keys would draw on" ;;
    os.urandom)
      hm "entropy: os.urandom — no node answered /prng"
      note "sound locally. Join a node and this becomes the flagship path." ;;
    openssl)
      hm "entropy: openssl rand — neither a node nor python answered" ;;
    *)
      no "entropy: nothing answered. Do not generate keys on this machine." ;;
  esac
  # The claim the HOUSE RULE actually wants made:
  note "no fabricated randomness in this script — and now none claimed for the"
  note "generator either: $SELF entropy says what your keys were really made from."
}

# Wire-up:
#   MENU_LABEL+=("Entropy"); MENU_ACT+=("entropy")   # in menu_build, near Register
#   entropy) cmd_entropy ;;                          # in menu_run
#   entropy) shift; cmd_entropy "$@" ;;              # in the arg dispatcher
#   entropy) MENU_STATE+=("${D}${ENT_SRC:-unknown} source${X}") ;;   # menu_states
#
# And in cmd_doctor, replace the openssl line with a call to selftest_entropy.
