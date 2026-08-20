#!/usr/bin/env bash
# ness.sh — set up, manage and use a PrivateNess node.   ness.cx
# Linux, macOS, and Windows under Git Bash. Save with LF line endings.
#
# Just run it:  ./ness.sh
# It works out where you are and does the next thing.
#
# Nothing here signs, broadcasts, or writes to the chain without you
# typing the word out in full.
#
# HOUSE RULE — no fabricated values.
#   Nothing in this script invents a number to make a screen look alive.
#   Every figure printed is read from disk, from the chain, or from a real
#   entropy source. There is no $RANDOM in here and there never will be.
#   `ness selftest` checks that rule against this very file.

set -uo pipefail
VERSION="2.9"

SELF="$(basename "$0")"
KEYS="${NESS_KEYS:-$HOME/.privateness-keys}"
CONF="$KEYS/ness.conf"
WL="$KEYS/watchlist.json"
LOG="$KEYS/ness.log"
TROPHIES="$KEYS/trophies"
FEES="$KEYS/fees"
SRC="${NESS_SRC:-$HOME/ness/PrivatenessTools}"
# Canonical GOPATH layout. Both trees live where the import path says they
# live — nothing here guesses at a checkout somewhere else.
GOPATH="${GOPATH:-$HOME/go}"
NESS_GO="${NESS_GO_SRC:-$GOPATH/src/github.com/ness-network/ness}"
SKY_GO="${SKY_GO_SRC:-$GOPATH/src/github.com/skycoin/skywire}"
NESS_REPO="https://github.com/ness-network/ness"
SKY_REPO="https://github.com/skycoin/skywire"
REPO="https://github.com/NESS-Network/PrivatenessTools"
YES="${NESS_YES:-0}"
DRY="${NESS_DRY_RUN:-0}"
RAW=0
# The ceiling this script assumes for an NVS value. Not asserted as the
# protocol limit — it is the number we refuse above. Override if your node
# says otherwise: NESS_NVS_MAX=... ness register
NVS_MAX="${NESS_NVS_MAX:-20480}"
NO_PROBE="${NESS_NO_PROBE:-0}"
# Ten is plenty to glance at. --all when you actually want the wall of text.
NAME_LIMIT="${NESS_NAME_LIMIT:-10}"
# Nine years old, and on his arm before any of this had a name.
TAGLINE="${NESS_TAGLINE:-127.0.0.1 is alive}"

# ── platform ────────────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) WIN=1; VBIN="Scripts" ;;
  *)                    WIN=0; VBIN="bin" ;;
esac
SUDO=""
[ "$WIN" = 0 ] && [ "$(id -u 2>/dev/null)" != 0 ] && command -v sudo >/dev/null && SUDO="sudo"
[ -t 0 ] && TTY=1 || TTY=0

# ── paint ───────────────────────────────────────────────────
NCOL=$(tput colors 2>/dev/null || echo 8)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  X=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; REV=$'\033[7m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'
  if [ "${NCOL:-8}" -ge 256 ]; then
    b1=$'\033[38;5;33m';  b2=$'\033[38;5;39m';  b3=$'\033[38;5;45m'
    b4=$'\033[38;5;51m';  b5=$'\033[38;5;44m';  GOLD=$'\033[38;5;178m'
    C=$'\033[38;5;39m';   G=$'\033[38;5;79m';   D=$'\033[38;5;244m'
  else b1=$C; b2=$C; b3=$C; b4=$C; b5=$C; GOLD=$Y; fi
else
  X=""; B=""; D=""; R=""; G=""; Y=""; C=""; REV=""
  b1=""; b2=""; b3=""; b4=""; b5=""; GOLD=""
fi
# Unicode is lovely until it is mojibake. Opt out with NESS_ASCII=1.
if [ -n "${NESS_ASCII:-}" ]; then UNI=0
elif printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qi 'utf-*8'; then UNI=1
elif [ "$WIN" = 1 ]; then UNI=1
else UNI=0; fi
if [ "$UNI" = 1 ]; then
  HEX="⬢"; HOLLOW="⬡"; TICK="✓"; CROSS="✗"; DOT="•"; RULE="─"; STAR="★"; DARK="☆"
else
  HEX="*"; HOLLOW="o"; TICK="+"; CROSS="x"; DOT="-"; RULE="-"; STAR="*"; DARK="."
fi

say(){ printf '%s\n' "$*"; }
rule(){ local i n=${1:-46} s=""; for ((i=0;i<n;i++)); do s="$s$RULE"; done; printf '%s%s%s\n' "$D" "$s" "$X"; }
head_(){ printf '\n%s%s %s%s\n' "$B" "$HEX" "$*" "$X"; }
ok(){   printf '  %s%s%s %s\n' "$G" "$TICK" "$X" "$*"; }
no(){   printf '  %s%s%s %s\n' "$R" "$CROSS" "$X" "$*"; }
hm(){   printf '  %s%s%s %s\n' "$Y" "$DOT" "$X" "$*"; }
note(){ printf '    %s%s%s\n' "$D" "$*" "$X"; }

# die <message> [next command to run]
die(){
  printf '\n  %s%s%s %s\n' "$R" "$CROSS" "$X" "$1" >&2
  [ $# -ge 2 ] && [ -n "${2:-}" ] && printf '    %snext:%s %s%s%s\n' "$D" "$X" "$B" "$2" "$X" >&2
  printf '\n' >&2
  logline "die" "$1"
  exit 1
}

# ── the log ─────────────────────────────────────────────────
# Every decision and every txid, so that an hour of setup leaves a trace.
logline(){
  [ -d "$KEYS" ] || return 0
  { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$LOG"; } 2>/dev/null
  chmod 600 "$LOG" 2>/dev/null
  return 0
}

step(){ printf '\n%s%s %s/%s %s%s%s\n' "$C" "$HEX" "$1" "$2" "$B" "$3" "$X"; rule 46; }

# ── prompts ─────────────────────────────────────────────────
ask(){ # ask <prompt> <default>
  local a
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then echo "$2"; return; fi
  printf '  %s%s%s %s %s[%s]%s ' "$C" "$DOT" "$X" "$1" "$D" "$2" "$X" >&2
  read -r a </dev/tty 2>/dev/null || a=""
  [ -n "$a" ] && echo "$a" || echo "$2"
}
confirm(){ # confirm <question>  -> 0 yes
  local a
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then return 0; fi
  printf '  %s%s%s %s %s[Y/n]%s ' "$GOLD" "$DOT" "$X" "$1" "$D" "$X" >&2
  read -r a </dev/tty 2>/dev/null || a=""
  case "$a" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# ── python ──────────────────────────────────────────────────
find_py(){
  [ -x "$SRC/venv/$VBIN/python" ]     && { echo "$SRC/venv/$VBIN/python"; return 0; }
  [ -x "$SRC/venv/$VBIN/python.exe" ] && { echo "$SRC/venv/$VBIN/python.exe"; return 0; }
  local p
  for p in python3 python py; do
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>/dev/null \
      && { command -v "$p"; return 0; }
  done
  return 1
}
# The repo's ./keygen is #!/usr/bin/bash calling python3 — neither exists on
# Windows. Call the scripts with our resolved interpreter instead.
pnt(){
  local script="$1"; shift
  [ -d "$SRC" ] || die "PrivatenessTools not found." "$SELF setup"
  local py; py=$(find_py) || die "No Python 3 found." "$SELF doctor"
  ( cd "$SRC" && "$py" -W ignore "$script" "$@" )
}

# PrivatenessTools decides its own keys directory. On Windows its idea of $HOME
# and Git Bash's are written differently (C:\Users\x vs /c/Users/x), so ask it
# rather than guess. Falls back to ours if the tool isn't installed yet.
sync_keys_dir(){
  [ -f "$KEYS/users.key.json" ] && return 0
  have_src || return 0
  local d
  d=$(pnt key.py 2>/dev/null | sed -n 's/^Keys directory: *//p' | tail -1 | tr -d '\r')
  [ -z "$d" ] && return 0
  case "$d" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then d=$(cygpath -u "$d" 2>/dev/null)
      else d="/$(printf '%s' "$d" | tr '\\' '/' | sed 's|^\(.\):|\1|')"; fi ;;
  esac
  [ -d "$d" ] || return 0
  KEYS="$d"; CONF="$KEYS/ness.conf"; WL="$KEYS/watchlist.json"
  LOG="$KEYS/ness.log"; TROPHIES="$KEYS/trophies"; FEES="$KEYS/fees"
}

conf_get(){ [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -1; }
conf_set(){
  mkdir -p "$KEYS"; chmod 700 "$KEYS" 2>/dev/null
  touch "$CONF"; chmod 600 "$CONF" 2>/dev/null
  local t
  if grep -q "^$1=" "$CONF" 2>/dev/null; then
    t=$(mktemp); grep -v "^$1=" "$CONF" > "$t"; printf '%s=%s\n' "$1" "$2" >> "$t"
    mv "$t" "$CONF"; chmod 600 "$CONF" 2>/dev/null
  else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}
cdef(){ local v; v=$(conf_get "$1"); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
ent(){ cdef ENTROPY 5; }

have_src(){ [ -x "$SRC/venv/$VBIN/python" ] || [ -x "$SRC/venv/$VBIN/python.exe" ]; }
have_user(){ [ -f "$KEYS/users.key.json" ]; }
have_node(){ [ -f "$KEYS/node.key.json" ]; }
emc_cli(){ command -v emercoin-cli >/dev/null 2>&1; }
emc_up(){ emc_cli && emercoin-cli getblockcount >/dev/null 2>&1; }

# ── observation ─────────────────────────────────────────────
# Everything below reports what is on this disk or on that chain.
# Nothing here estimates, simulates, or fills a gap with a plausible number.

backup_newest(){ ls -t "$HOME"/privateness-keys-*.tar.gz* 2>/dev/null | head -1; }
backup_age_days(){
  local f; f=$(backup_newest) || return 1
  [ -n "$f" ] || return 1
  local m now
  m=$(date -r "$f" +%s 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || return 1
  now=$(date -u +%s)
  echo $(( (now - m) / 86400 ))
}
backup_encrypted(){ case "$(backup_newest)" in *.age|*.gpg|*.enc) return 0 ;; *) return 1 ;; esac; }

# name_list is ONE call and it already carries expires_in. The old code asked
# the node again for every single name — 40 names meant 40 round trips, and a
# wallet with thousands meant minutes of staring at nothing. Load once, cache
# for the run, and never ask per row again.
NTMP="${TMPDIR:-/tmp}/ness.$$"
names_load(){
  [ -f "$NTMP/names.tsv" ] && return 0
  mkdir -p "$NTMP" 2>/dev/null; chmod 700 "$NTMP" 2>/dev/null
  if ! emc_up; then : > "$NTMP/names.tsv"; return 1; fi
  local py; py=$(find_py) || { : > "$NTMP/names.tsv"; return 1; }
  emercoin-cli name_list 2>/dev/null | "$py" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for e in (d if isinstance(d,list) else []):
    n=e.get("name","")
    if not n: continue
    x=e.get("expires_in", e.get("expires",""))
    sys.stdout.write("%s\t%s\n"%(n,x))
' > "$NTMP/names.tsv" 2>/dev/null
  return 0
}
wallet_names(){  # names in this wallet, one per line. Chain truth or nothing.
  names_load || return 1
  [ -s "$NTMP/names.tsv" ] || return 1
  cut -f1 "$NTMP/names.tsv"
}
names_count(){ names_load; grep -c . "$NTMP/names.tsv" 2>/dev/null || echo 0; }
has_name_prefix(){ # has_name_prefix <prefix>
  names_load || return 1
  cut -f1 "$NTMP/names.tsv" 2>/dev/null | grep -q "^$1"
}
emc_balance(){ emc_up || return 1; emercoin-cli getbalance 2>/dev/null | tr -d '\r'; }

nvs_state(){ # nvs_state <name> -> free | mine | theirs | unknown
  local n="$1" out
  out=$(emercoin-cli name_show "$n" 2>&1)
  if printf '%s' "$out" | grep -qi 'not found\|no data\|expired'; then echo free; return; fi
  if printf '%s' "$out" | grep -q '"value"\|"txid"\|"address"'; then
    if emercoin-cli name_list 2>/dev/null | grep -q "\"$n\""; then echo mine; else echo theirs; fi
    return
  fi
  echo unknown
}
# The value of a name, read back EXACTLY. A greedy sed here would hand a
# mangled string to name_update and write the damage to the chain, so this
# parses the JSON properly and refuses rather than guesses.
nvs_value(){ # current on-chain value of a name, or nothing
  emc_up || return 1
  local py; py=$(find_py) || return 1
  emercoin-cli name_show "$1" 2>/dev/null | "$py" -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
v=d.get("value")
if v is None: sys.exit(1)
sys.stdout.write(v)
'
}
# From the cached table. No extra round trip, ever.
nvs_expires(){
  names_load || return 1
  awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$NTMP/names.tsv" 2>/dev/null
}

# ── trophies ────────────────────────────────────────────────
# Earned by observation, every run, from the same facts `status` reads.
# The file records only WHEN a thing was first observed — a fact, not a score.
TROPHY_IDS="firstlight homesteader notary cartographer seeder archivist paranoid watchman doomguy nineyears"
trophy_name(){
  case "$1" in
    firstlight)   echo "First Light|keys exist on this machine" ;;
    homesteader)  echo "Homesteader|a name of yours is on the chain" ;;
    notary)       echo "Notary|an EmerSSL certificate, and no more passwords" ;;
    cartographer) echo "Cartographer|a dns: record points somewhere" ;;
    seeder)       echo "Seeder|a magnet: record with a torrent and a CID" ;;
    archivist)    echo "Archivist|content pinned to IPFS" ;;
    paranoid)     echo "Paranoid|an encrypted backup exists" ;;
    watchman)     echo "Watchman|you are watching something" ;;
    doomguy)      echo "Doomguy|you held an arena open" ;;
    nineyears)    echo "Nine Years|you found the tagline" ;;
  esac
}
trophy_held(){ # trophy_held <id> -> 0 if OBSERVED right now
  case "$1" in
    firstlight)   have_user ;;
    homesteader)  has_name_prefix "ness:" || has_name_prefix "dpo:" || has_name_prefix "id:" ;;
    notary)       [ -n "$(conf_get SSL_NAME)" ] && ls "$KEYS"/ssl/*.crt >/dev/null 2>&1 ;;
    cartographer) has_name_prefix "dns:" ;;
    seeder)       ls "$KEYS"/magnet-*.nvs >/dev/null 2>&1 ;;
    archivist)    [ -n "$(conf_get IPFS_CID)" ] ;;
    paranoid)     backup_encrypted ;;
    watchman)     [ -f "$WL" ] && grep -q '"name"\|"address"' "$WL" 2>/dev/null ;;
    doomguy)      [ -n "$(conf_get DOOM_HOSTED)" ] ;;
    nineyears)    [ -n "$(conf_get SAW_TAGLINE)" ] ;;
    *) return 1 ;;
  esac
}
# Which observation grants the trophy. A trophy is never stronger than the
# thing that grants it, so it wears that observation's mark and no other.
trophy_obs(){
  case "$1" in
    firstlight)   echo userkey ;;
    homesteader)  echo identity ;;
    notary)       echo ssl ;;
    cartographer) echo dns ;;
    seeder)       echo magnet ;;
    archivist)    echo ipfs ;;
    paranoid)     echo backup ;;
    watchman)     echo watch ;;
    doomguy)      echo "" ;;   # a flag this script set itself. Nothing checked it.
    nineyears)    echo "" ;;
  esac
}
trophy_seen(){ [ -f "$TROPHIES" ] && grep -q "^$1	" "$TROPHIES"; }
trophy_when(){ [ -f "$TROPHIES" ] && sed -n "s/^$1	//p" "$TROPHIES" | head -1; }
trophy_scan(){ # unlock anything newly true; prints the new ones
  local id
  mkdir -p "$KEYS" 2>/dev/null
  for id in $TROPHY_IDS; do
    if trophy_held "$id" && ! trophy_seen "$id"; then
      printf '%s\t%s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TROPHIES"
      chmod 600 "$TROPHIES" 2>/dev/null
      local t; t=$(trophy_name "$id")
      printf '\n  %s%s  %s%s%s  %s%s%s\n' "$GOLD" "$STAR" "$B" "${t%%|*}" "$X" "$D" "${t#*|}" "$X"
      logline "trophy" "$id"
    fi
  done
}
cmd_trophies(){
  banner
  observe_all
  head_ "trophies"
  note "each one wears the mark of the observation that grants it."
  note "gold star means something was recomputed here. A dot means it was only claimed."
  say ""
  local id t o chk n=0 total=0 gold=0 bad=0
  for id in $TROPHY_IDS; do
    total=$((total+1)); t=$(trophy_name "$id")
    if trophy_held "$id"; then
      o=$(trophy_obs "$id")
      if [ -n "$o" ]; then chk=$(obs_chk "$o"); else chk="claimed"; fi
      # EmerEyes' rule, kept: a check that ran and failed never renders as a
      # pass. A contradicted trophy is not a held trophy — it is a mismatch
      # wearing a trophy's name, and it is counted as one.
      if [ "$chk" = failed ]; then bad=$((bad+1)); printf '  %s%s%s ' "$R" "$CROSS" "$X"
      elif [ "$chk" = verified ]; then n=$((n+1)); gold=$((gold+1)); printf '  %s%s%s ' "$GOLD" "$STAR" "$X"
      else n=$((n+1)); printf '  %s%s%s ' "$D" "$DOT" "$X"; fi
      printf '%s%-14s%s ' "$B" "${t%%|*}" "$X"
      mark "$chk"
      printf ' %s%s%s\n' "$D" "$(trophy_when "$id")" "$X"
      note "${t#*|}"
      [ -n "$o" ] && [ -n "${OBS_DET[$o]:-}" ] && note "  ${OBS_DET[$o]}"
      [ -z "$o" ] && note "  granted by a flag this script wrote itself — nothing checked it"
    else
      printf '  %s%s %-14s%s %s\n' "$D" "$DARK" "${t%%|*}" "$X" "$D${t#*|}$X"
    fi
  done
  say ""
  printf '  %s%s of %s held%s' "$B" "$n" "$total" "$X"
  printf '  %s· %s recomputed here%s\n' "$D" "$gold" "$X"
  [ "$n" -gt "$gold" ] && note "the rest are held on someone's word, including your own. $SELF verify says whose."
  if [ "$bad" -gt 0 ]; then
    say ""
    printf '  %s%s contradicted — the thing that would grant it says otherwise. Not counted.%s\n' "$R" "$bad" "$X"
  fi
  echo
}

# ── the hexagon, which is the progress bar ──────────────────
# Six cells, each lit only by something observed.
hexbar(){
  local out="" lit=0 i
  local cells="src user node backup chain served"
  for i in $cells; do
    local on=1
    case "$i" in
      src)    have_src || on=0 ;;
      user)   have_user || on=0 ;;
      node)   have_node || on=0 ;;
      backup) backup_newest >/dev/null 2>&1 && [ -n "$(backup_newest)" ] || on=0 ;;
      chain)  trophy_held homesteader || on=0 ;;
      served) trophy_held cartographer || trophy_held notary || trophy_held seeder || on=0 ;;
    esac
    if [ "$on" = 1 ]; then out="$out$C$HEX$X "; lit=$((lit+1))
    else out="$out$D$HOLLOW$X "; fi
  done
  printf '%s' "$out"
  return "$lit"
}

banner(){
  [ -n "${NESS_QUIET:-}" ] && return 0
  echo
  if [ "$UNI" = 1 ]; then
    printf '%s      ███╗   ██╗ ███████╗ ███████╗ ███████╗%s\n' "$b1" "$X"
    printf '%s      ████╗  ██║ ██╔════╝ ██╔════╝ ██╔════╝%s\n' "$b2" "$X"
    printf '%s      ██╔██╗ ██║ █████╗   ███████╗ ███████╗%s\n' "$b3" "$X"
    printf '%s      ██║╚██╗██║ ██╔══╝   ╚════██║ ╚════██║%s\n' "$b4" "$X"
    printf '%s      ██║ ╚████║ ███████╗ ███████║ ███████║%s\n' "$b5" "$X"
    printf '%s      ╚═╝  ╚═══╝ ╚══════╝ ╚══════╝ ╚══════╝%s\n' "$b5" "$X"
  else
    printf '%s       _   _  _____  ____   ____ %s\n' "$b1" "$X"
    printf '%s      | \ | || ____|/ ___| / ___|%s\n' "$b2" "$X"
    printf '%s      |  \| ||  _|  \___ \ \___ \%s\n' "$b3" "$X"
    printf '%s      | |\  || |___  ___) | ___) |%s\n' "$b4" "$X"
    printf '%s      |_| \_||_____||____/ |____/%s\n' "$b5" "$X"
  fi
  printf '\n      '; hexbar; local lit=$?
  printf '  %sness.cx%s  %s%s%s\n' "$GOLD" "$X" "$D" "$TAGLINE" "$X"
  printf '      %sprivateness.network%s   %s%s of 6 observed%s\n\n' "$D" "$X" "$D" "$lit" "$X"
  # Earned by setting NESS_TAGLINE yourself — you had to go find it.
  [ -n "${NESS_TAGLINE:-}" ] && [ -z "$(conf_get SAW_TAGLINE)" ] \
    && conf_set SAW_TAGLINE "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null
  return 0
}

# ── status: the home screen this script never had ───────────
cmd_status(){
  banner
  observe_all

  # The census first, the way EmerEyes leads with its banner. You should know
  # how much of this screen was checked before you read any of it.
  local id n=0 ok=0 bad=0
  for id in $OBS_ORDER; do
    [ "$(obs_chk "$id")" = absent ] && continue
    n=$((n+1))
    case "$(obs_chk "$id")" in verified) ok=$((ok+1)) ;; failed) bad=$((bad+1)) ;; esac
  done
  if [ "$bad" -gt 0 ]; then
    printf '  %s%s of %s observations FAILED their check. %s fix explains each one.%s\n\n' \
      "$R" "$bad" "$n" "$SELF" "$X"
  elif [ "$n" -gt 0 ]; then
    printf '  %s%s of %s observations below were recomputed here. The rest are reported or claimed.%s\n\n' \
      "$D" "$ok" "$n" "$X"
  fi

  head_ "where you stand"
  local row
  for row in tools userkey nodekey identity noderec backup chain; do
    [ "$(obs_chk "$row")" = absent ] && continue
    printf '  %s %s%-9s%s ' "$(src_tag "$(obs_src "$row")")" "$D" "$row" "$X"
    mark "$(obs_chk "$row")"; printf '\n'
    if [ "$(obs_chk "$row")" = failed ]; then
      printf '    %s%s%s\n' "$D" "${OBS_DET[$row]}" "$X"
      [ -n "${OBS_MORE[$row]:-}" ] && printf '%s\n' "${OBS_MORE[$row]}" | sed "s/^/    $D/;s/\$/$X/"
    fi
  done
  for row in tools userkey nodekey; do
    if [ "$(obs_chk "$row")" = absent ]; then
      printf '  %s %s%-9s%s %s  not observed%s  %s%s%s\n' "$(src_tag "")" "$D" "$row" "$X" "$D" "$X" "$D" "${OBS_DET[$row]}" "$X"
    fi
  done

  head_ "what you told this script"
  note "none of this was checked by anything. It is configuration, not observation."
  for row in whoami nodeurl; do
    [ "$(obs_chk "$row")" = absent ] && continue
    printf '  %s %s\n' "$(src_tag conf)" "${OBS_DET[$row]}"
  done

  head_ "your names"
  local names e shown=0 total
  if names=$(wallet_names) && [ -n "$names" ]; then
    total=$(names_count)
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      shown=$((shown+1))
      [ "$shown" -gt "$NAME_LIMIT" ] && break
      e=$(nvs_expires "$row")
      printf '  %s%s%s %-34s' "$GOLD" "$HEX" "$X" "$row"
      [ -n "$e" ] && printf ' %s~%s blocks left%s' "$D" "$e" "$X"
      printf '\n'
    done <<EOF
$names
EOF
    if [ "$total" -gt "$NAME_LIMIT" ]; then
      printf '  %s… and %s more · %s names --all%s\n' "$D" "$((total-NAME_LIMIT))" "$SELF" "$X"
    fi
    note "your node listed these in one call. Whether they hold what your keys"
    note "produce is a different question, and $SELF verify answers it."
  elif emc_up; then hm "no names in this wallet yet"; note "$SELF register  ·  $SELF ssl  ·  $SELF dns"
  else note "can't read the chain from here, so this list stays empty rather than guessed"; fi

  local held=0
  for row in $TROPHY_IDS; do trophy_held "$row" && held=$((held+1)); done
  head_ "trophies"
  printf '  %s%s of 10%s   %s%s trophies%s\n' "$B" "$held" "$X" "$D" "$SELF" "$X"

  trophy_scan
  echo
}

cmd_names(){
  banner
  head_ "your names"
  local names total shown=0 row e
  names=$(wallet_names) || { hm "can't read the chain from here"; echo; return 1; }
  [ -n "$names" ] || { hm "no names in this wallet yet"; echo; return 0; }
  total=$(names_count)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    shown=$((shown+1))
    [ "$shown" -gt "$NAME_LIMIT" ] && break
    e=$(nvs_expires "$row")
    printf '  %s%s%s %-38s' "$GOLD" "$HEX" "$X" "$row"
    [ -n "$e" ] && printf ' %s~%s blocks%s' "$D" "$e" "$X"
    printf '\n'
  done <<EOF
$names
EOF
  say ""
  if [ "$total" -gt "$NAME_LIMIT" ]; then
    printf '  %s%s of %s shown · %s names --all for the rest%s\n' "$D" "$NAME_LIMIT" "$total" "$SELF" "$X"
  else
    printf '  %s%s total%s\n' "$D" "$total" "$X"
  fi
  note "one call to your node, not one per name"
  echo
}

# ── the smart bit ───────────────────────────────────────────
first_run(){ ! have_src || ! have_user || ! have_node; }

cmd_go(){
  if ! first_run; then cmd_door; return $?; fi

  banner
  local total=4 n=0

  # 0. on Windows, prove the machine first — it is where things break.
  if [ "$WIN" = 1 ] && [ -z "$(conf_get SELFTEST_OK)" ]; then
    head_ "Windows — let's prove this machine first"
    if cmd_selftest_quiet; then
      ok "this machine can run it"; conf_set SELFTEST_OK "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      no "something needs fixing before we start"
      note "the full list: $SELF selftest"
      exit 1
    fi
  fi

  # 1. tools + source
  if ! have_src; then
    n=$((n+1)); step $n $total "Getting the tools"
    cmd_setup || exit 1
  else
    n=$((n+1)); printf '\n%s%s %s/%s%s tools ready %s(%s)%s\n' "$G" "$TICK" "$n" "$total" "$X" "$D" "$SRC" "$X"
  fi

  # 2. you
  if ! have_user; then
    n=$((n+1)); step $n $total "Who are you?"
    note "A name for you, not for the machine. It goes on chain."
    note "It is baked into the key: changing it later means new keys."
    review_step "what I have so far" ENTROPY
    local nm; nm=$(ask "your name" "$(cdef NESS_USER "${USER:-${USERNAME:-master01}}")")
    cmd_user "$nm" || exit 1
  else
    n=$((n+1)); printf '\n%s%s %s/%s%s you are %s%s%s\n' "$G" "$TICK" "$n" "$total" "$X" "$B" "$(conf_get NESS_USER)" "$X"
  fi

  # 3. the node
  if ! have_node; then
    n=$((n+1)); step $n $total "What are you running?"
    review_step "the node, as it stands" NODE_URL TARIFF SERVICES NETWORK ORG
    cmd_node || exit 1
  else
    n=$((n+1)); printf '\n%s%s %s/%s%s node %s%s%s\n' "$G" "$TICK" "$n" "$total" "$X" "$B" "$(conf_get NODE_URL)" "$X"
  fi

  # 4. what you have now
  n=$((n+1)); step $n $total "Your records"
  cmd_records

  head_ "worth doing now"
  if [ -z "$(backup_newest)" ]; then
    if confirm "Back the keys up? There is no recovery from the chain."; then
      cmd_backup_quiet
    else hm "skipped — do it before you register anything"; fi
  fi
  trophy_scan
  say ""
  cmd_door
}

# ── the menu (run 2 and onward) ─────────────────────────────
# ── THE DOOR ────────────────────────────────────────────────
# What you see when you type `ness`.
#
# Not a menu. A menu is what you build when you have not decided what the user
# should do next — and this script already knows, because the gate computed it.
# So it decides, and offers ONE action. Everything else is behind one key.
#
# The verb is chosen by observation, in this order, and the order is an
# argument: a contradiction outranks convenience, and being unable to work
# outranks being unprotected.
#
#   1  something checked and FAILED     ->  Look at it
#   2  no keys yet                      ->  Set up
#   3  not connected                    ->  Connect          (the usual answer)
#   4  connected                        ->  Disconnect
#   5  keys with no backup              ->  Back up

# `verify` leaves its result here so the door can show the last real check
# without re-running every recomputation on every keystroke. The age is always
# shown: a cached observation is still an observation, but it is not a fresh
# one and it never claims to be.
verify_stamp(){ # verify_stamp <n> <ok> <failed> <detail>
  mkdir -p "$KEYS" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$1" "$2" "$3" "$4" > "$KEYS/verify.last"
  chmod 600 "$KEYS/verify.last" 2>/dev/null
}
verify_age(){ # minutes since the last full verify, or nothing
  [ -f "$KEYS/verify.last" ] || return 1
  local t; t=$(cut -f1 "$KEYS/verify.last" 2>/dev/null)
  [ -n "$t" ] || return 1
  echo $(( ( $(date -u +%s) - t ) / 60 ))
}
verify_field(){ [ -f "$KEYS/verify.last" ] && cut -f"$1" "$KEYS/verify.last" 2>/dev/null; }
ago(){ # minutes -> english
  local m="$1"
  if   [ "$m" -lt 1 ]    ; then printf 'just now'
  elif [ "$m" -lt 60 ]   ; then printf '%s min ago' "$m"
  elif [ "$m" -lt 1440 ] ; then printf '%s h ago' "$((m/60))"
  else                          printf '%s days ago' "$((m/1440))"
  fi
}

# The one decision this whole screen exists to make.
door_verb(){   # prints: <verb>|<action>|<why>
  local f; f=$(verify_field 4)
  if [ -n "$f" ] && [ "$f" -gt 0 ] 2>/dev/null; then
    printf 'FIX IT|verify|%s' "$(verify_field 5)"; return
  fi
  if ! have_user; then
    printf 'SET UP|setup|no keys on this machine yet'; return
  fi
  if sky && sky_is_up "$(sky_status)"; then
    printf 'DISCONNECT|disconnect|your traffic is going through the mesh'; return
  fi
  if sky; then
    printf 'CONNECT|connect|your traffic is going out the ordinary way'; return
  fi
  if [ -z "$(backup_newest)" ]; then
    printf 'BACK UP|backup|there is no copy of your keys anywhere'; return
  fi
  printf 'CONNECT|connect|no visor on this machine — nothing to connect with'
}

# One line of context under the button. Cheap reads only.
door_line(){
  local bits="" n a
  if emc_up; then n=$(names_count); [ "$n" -gt 0 ] && bits="$n names"; fi
  if a=$(backup_age_days); then
    [ -n "$bits" ] && bits="$bits · "
    bits="${bits}backed up $(ago $((a*1440)))"
  else
    [ -n "$bits" ] && bits="$bits · "
    bits="${bits}${Y}no backup${X}"
  fi
  local m
  if m=$(verify_age); then
    [ -n "$bits" ] && bits="$bits · "
    local ok fl
    ok=$(verify_field 3); fl=$(verify_field 4)
    if [ "${fl:-0}" -gt 0 ] 2>/dev/null; then bits="${bits}${R}$fl failed${X} $(ago "$m")"
    else bits="${bits}${ok:-0} verified $(ago "$m")"; fi
  else
    [ -n "$bits" ] && bits="$bits · "
    bits="${bits}${D}never verified${X}"
  fi
  printf '%s' "$bits"
}

# Same discipline as the menu: the door computes its facts ONCE, then only
# redraws. door_verb used to run twice per keystroke and each run forked
# skywire-cli.
DOOR_VERB=""; DOOR_ACT=""; DOOR_WHY=""; DOOR_LINE=""
door_refresh(){
  IFS='|' read -r DOOR_VERB DOOR_ACT DOOR_WHY <<EOF
$(door_verb)
EOF
  DOOR_LINE=$(door_line)
}

door_draw(){
  local pad i w=25 col="$G"
  case "$DOOR_VERB" in "LOOK AT IT") col="$R" ;; "DISCONNECT"|"BACK UP") col="$Y" ;; esac
  pad=$(( (w - ${#DOOR_VERB}) / 2 ))
  scr_home
  printf '\n\n  %s%s%s  %sness%s%*s%s%s%s\n\n\n' "$C" "$HEX" "$X" "$B" "$X" 28 "" "$D" "$(cdef NESS_USER '')" "$X"
  if [ "$UNI" = 1 ]; then
    printf '        %s┌' "$col"; for ((i=0;i<w;i++)); do printf '─'; done; printf '┐%s\n' "$X"
    printf '        %s│%*s%s%-*s%s%s│%s\n' "$col" "$pad" "" "$B$col" "$((w-pad))" "$DOOR_VERB" "$X" "$col" "$X"
    printf '        %s└' "$col"; for ((i=0;i<w;i++)); do printf '─'; done; printf '┘%s\n' "$X"
  else
    printf '        %s+' "$col"; for ((i=0;i<w;i++)); do printf '-'; done; printf '+%s\n' "$X"
    printf '        %s|%*s%s%-*s%s%s|%s\n' "$col" "$pad" "" "$B$col" "$((w-pad))" "$DOOR_VERB" "$X" "$col" "$X"
    printf '        %s+' "$col"; for ((i=0;i<w;i++)); do printf '-'; done; printf '+%s\n' "$X"
  fi
  printf '\n        %s%s%s\n' "$D" "$DOOR_WHY" "$X"
  printf '\n        %s%s%s\n' "$D" "$DOOR_LINE" "$X"
  printf '\n\n  %s enter %s do it     %s space %s everything else     %s q %s quit%s\n' \
    "$B" "$D" "$X$B" "$D" "$X$B" "$D" "$X"
  scr_clear_below
}

cmd_door(){
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then cmd_status; return 0; fi
  door_refresh
  trap 'scr_leave' RETURN INT TERM
  scr_enter
  while :; do
    door_draw
    menu_key
    case "$KEY" in
      ENTER)
        scr_leave; printf '\n'
        case "$DOOR_ACT" in
          verify)     cmd_fix ;;
          setup)      cmd_go ;;
          connect)    cmd_connect ;;
          disconnect) cmd_disconnect ;;
          backup)     cmd_backup ;;
        esac
        drain_input
        printf '\n  %spress any key%s ' "$D" "$X"; menu_key
        door_refresh; scr_enter ;;
      SPACE|RIGHT|DOWN)
        scr_leave; cmd_menu; door_refresh; scr_enter ;;
      QUIT|ESC|FAIL)
        scr_leave; printf '\n'; return 0 ;;
      *) : ;;
    esac
  done
}

# ── the menu ────────────────────────────────────────────────
# One ordered list, top to bottom, in the order a hand reaches for things.
# Arrows move, enter chooses. No letters to hunt for.
#
# Every row carries the state that answers "should I press this", so you never
# press one to find out — and the states come from the same observations the
# rest of the script uses, so nothing here is decorative.

# One item per line: label, action, and whether it is a separator.
MENU_LABEL=(); MENU_ACT=()
menu_build(){
  MENU_LABEL=(); MENU_ACT=()
  local cl="Connect"
  if sky && sky_is_up "$(sky_status)"; then cl="Disconnect"; fi
  MENU_LABEL+=("$cl");            MENU_ACT+=("connect")
  MENU_LABEL+=("Status");         MENU_ACT+=("status")
  MENU_LABEL+=("Verify");         MENU_ACT+=("verify")
  MENU_LABEL+=("Names");          MENU_ACT+=("names")
  MENU_LABEL+=("Backup");         MENU_ACT+=("backup")
  MENU_LABEL+=("Trophies");       MENU_ACT+=("trophies")
  MENU_LABEL+=("");               MENU_ACT+=("")
  MENU_LABEL+=("Register");       MENU_ACT+=("register")
  MENU_LABEL+=("Manage names");   MENU_ACT+=("manage")
  MENU_LABEL+=("Domain");         MENU_ACT+=("dns")
  MENU_LABEL+=("Certificate");    MENU_ACT+=("ssl")
  MENU_LABEL+=("Share a file");   MENU_ACT+=("magnet")
  MENU_LABEL+=("IPFS");           MENU_ACT+=("ipfs")
  MENU_LABEL+=("Watchlist");      MENU_ACT+=("watch")
  MENU_LABEL+=("Records");        MENU_ACT+=("records")
  MENU_LABEL+=("Rebuild keys");   MENU_ACT+=("rekey")
  MENU_LABEL+=("Build the trees");MENU_ACT+=("build")
  MENU_LABEL+=("");               MENU_ACT+=("")
  MENU_LABEL+=("Get EMC");        MENU_ACT+=("emc")
  MENU_LABEL+=("Doom");           MENU_ACT+=("doom")
  MENU_LABEL+=("Why any of this");MENU_ACT+=("why")
  MENU_LABEL+=("The button");     MENU_ACT+=("button")
  MENU_LABEL+=("");               MENU_ACT+=("")
  MENU_LABEL+=("Doctor");         MENU_ACT+=("doctor")
  MENU_LABEL+=("Self test");      MENU_ACT+=("selftest")
  MENU_LABEL+=("Quit");           MENU_ACT+=("quit")
}

# The right-hand column, computed ONCE when the menu opens and again only
# after an action returns. It used to be recomputed for every row on every
# redraw — a skywire-cli fork, a name count and ten trophy checks per frame.
# On Git Bash a fork is ~50-100ms, so a frame took seconds, keystrokes queued
# in the tty buffer, and one arrow press arrived as twenty. Navigation must
# not cost a single process.
MENU_STATE=()
menu_states(){
  local i act cache_names="" cache_sky="" cache_troph="" cache_backup=""
  # each expensive fact fetched at most once for the whole table
  if sky; then sky_is_up "$(sky_status)" && cache_sky="up" || cache_sky="down"; fi
  emc_up && cache_names=$(names_count)
  local h=0 t; for t in $TROPHY_IDS; do trophy_held "$t" && h=$((h+1)); done
  cache_troph="$h"
  cache_backup=$(backup_age_days) || cache_backup=""
  MENU_STATE=()
  for ((i=0;i<${#MENU_ACT[@]};i++)); do
    act="${MENU_ACT[$i]}"
    case "$act" in
      connect)
        case "$cache_sky" in
          up)   MENU_STATE+=("${G}connected${X}") ;;
          down) MENU_STATE+=("${D}not connected${X}") ;;
          *)    MENU_STATE+=("${D}no visor here${X}") ;;
        esac ;;
      status)   MENU_STATE+=("${D}where you stand${X}") ;;
      verify)   MENU_STATE+=("${D}what was actually checked${X}") ;;
      names)    if [ -n "$cache_names" ]; then MENU_STATE+=("${D}${cache_names} on chain${X}")
                else MENU_STATE+=("${D}no chain here${X}"); fi ;;
      backup)   if [ -n "$cache_backup" ]; then MENU_STATE+=("${D}${cache_backup} days old${X}")
                else MENU_STATE+=("${Y}none${X}"); fi ;;
      trophies) MENU_STATE+=("${D}${cache_troph} of 10${X}") ;;
      *)        MENU_STATE+=("") ;;
    esac
  done
}

# Anything typed while a slow command was running is stale by the time it
# lands. Throw it away rather than replaying it as navigation.

# Anything typed while a slow command was running is stale by the time it
# lands. Throw it away rather than replaying it as navigation.
drain_input(){ while IFS= read -rsn1 -t 0.001 _ </dev/tty 2>/dev/null; do :; done; }

KEY=""
menu_key(){
  # One byte at a time. Reading an escape sequence with `read -n2` looks
  # tidier and desyncs the stream the moment a partial read races the
  # timeout — which is how an Enter key ends up being seen as a stray ESC.
  local k a b
  KEY=""
  IFS= read -rsn1 k </dev/tty 2>/dev/null || { KEY=FAIL; return; }
  case "$k" in
    $'\e')
      IFS= read -rsn1 -t 0.12 a </dev/tty 2>/dev/null || a=''
      case "$a" in
        '['|'O')
          IFS= read -rsn1 -t 0.12 b </dev/tty 2>/dev/null || b=''
          case "$b" in
            A) KEY=UP ;;    B) KEY=DOWN ;;
            C) KEY=RIGHT ;; D) KEY=LEFT ;;
            H) KEY=HOME ;;  F) KEY=END ;;
            5) IFS= read -rsn1 -t 0.12 </dev/tty 2>/dev/null; KEY=PGUP ;;
            6) IFS= read -rsn1 -t 0.12 </dev/tty 2>/dev/null; KEY=PGDN ;;
            *) KEY=OTHER ;;
          esac ;;
        '') KEY=ESC ;;
        *)  KEY=OTHER ;;
      esac ;;
    $'\xe0')
      # Windows console scan codes, for terminals that do not speak ANSI in.
      # NOTE: the 0x00 prefix variant is deliberately NOT matched here. A bash
      # string cannot hold a NUL, so $'\x00' IS the empty string — and the
      # empty string is what read -n1 returns for Enter. Listing it here ate
      # every Enter keypress and sent it down the scan-code path instead.
      IFS= read -rsn1 -t 0.12 a </dev/tty 2>/dev/null || a=''
      case "$a" in H) KEY=UP ;; P) KEY=DOWN ;; I) KEY=PGUP ;;
                   Q) KEY=PGDN ;; G) KEY=HOME ;; O) KEY=END ;;
                   *) KEY=OTHER ;; esac ;;
    ' ')     KEY=SPACE ;;
    ''|$'\r'|$'\n')
      # A terminal sends CARRIAGE RETURN for Enter. Depending on the tty's
      # icrnl setting, read -n1 hands back either an empty string or a literal
      # \r — so both count. Matching only one makes an Enter key that does
      # nothing, on exactly the platforms that matter.
      KEY=ENTER ;;
    k|K|w|W) KEY=UP ;;
    j|J|s|S) KEY=DOWN ;;
    q|Q)     KEY=QUIT ;;
    *)       KEY=CHAR ;;
  esac
}

# The alternate screen buffer, the way every real full-screen program does it.
# The old version redrew by moving the cursor up N lines, which is exactly
# right until the drawing reaches the bottom of the window — then the terminal
# scrolls, "up N" no longer lands where it started, and the menu walks down
# the screen. Absolute positions on a screen that cannot scroll cannot drift.
scr_enter(){ tput smcup 2>/dev/null || printf '\033[?1049h'; tput civis 2>/dev/null || printf '\033[?25l'; }
scr_leave(){ tput rmcup 2>/dev/null || printf '\033[?1049l'; tput cnorm 2>/dev/null || printf '\033[?25h'; }
scr_home(){  tput cup 0 0 2>/dev/null || printf '\033[H'; }
scr_clear_below(){ tput ed 2>/dev/null || printf '\033[J'; }

menu_draw(){ # menu_draw <cursor> <top> <rows-available>
  local cur="$1" top="$2" avail="$3" i last
  scr_home
  printf '\n  %s%s%s  %sness%s   %s%s%s\n\n' "$C" "$HEX" "$X" "$B" "$X" "$D" "$(cdef NESS_USER '')" "$X"
  last=$((top+avail-1))
  [ "$last" -ge "${#MENU_LABEL[@]}" ] && last=$(( ${#MENU_LABEL[@]} - 1 ))
  if [ "$top" -gt 0 ]; then printf '        %s↑ more%s\n' "$D" "$X"; else printf '\n'; fi
  for ((i=top;i<=last;i++)); do
    if [ -z "${MENU_ACT[$i]}" ]; then
      printf '     %s─────────────────────────────────────%s\n' "$D" "$X"
    elif [ "$i" = "$cur" ]; then
      # A selected row is a highlighted BAR, not a bullet you have to hunt for.
      printf '  %s%s %-18s %-28s%s\n' "$REV" "$HEX" "${MENU_LABEL[$i]}" "$(printf '%s' "${MENU_STATE[$i]}" | sed 's/\x1b\[[0-9;]*m//g')" "$X"
    else
      printf '    %s%-18s%s %s\n' "$D" "${MENU_LABEL[$i]}" "$X" "${MENU_STATE[$i]}"
    fi
  done
  if [ "$last" -lt $(( ${#MENU_LABEL[@]} - 1 )) ]; then printf '        %s↓ more%s\n' "$D" "$X"; else printf '\n'; fi
  printf '\n  %s↑↓ move · enter choose · q quit%s\n' "$D" "$X"
  scr_clear_below
}

cmd_menu(){
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then
    note "not interactive — $SELF help lists everything"
    return 0
  fi
  local cur=0 top=0 avail rows act i
  menu_build; menu_states
  trap 'scr_leave' RETURN INT TERM
  scr_enter
  while :; do
    rows=$(tput lines 2>/dev/null || echo 24)
    avail=$((rows-8)); [ "$avail" -lt 6 ] && avail=6
    [ "$avail" -gt "${#MENU_LABEL[@]}" ] && avail=${#MENU_LABEL[@]}
    [ "$cur" -lt "$top" ] && top=$cur
    [ "$cur" -ge $((top+avail)) ] && top=$((cur-avail+1))
    [ "$top" -lt 0 ] && top=0

    menu_draw "$cur" "$top" "$avail"
    menu_key
    case "$KEY" in
      FAIL) scr_leave; menu_plain; return 0 ;;
      UP)   i=$cur
            while :; do i=$((i-1)); [ "$i" -lt 0 ] && i=$((${#MENU_LABEL[@]}-1))
              [ -n "${MENU_ACT[$i]}" ] && break; done
            cur=$i ;;
      DOWN) i=$cur
            while :; do i=$((i+1)); [ "$i" -ge "${#MENU_LABEL[@]}" ] && i=0
              [ -n "${MENU_ACT[$i]}" ] && break; done
            cur=$i ;;
      HOME|PGUP) cur=0 ;;
      END|PGDN)  cur=$(( ${#MENU_LABEL[@]} - 1 )) ;;
      QUIT|ESC|LEFT) scr_leave; return 0 ;;
      SPACE|ENTER)
        act="${MENU_ACT[$cur]}"
        [ "$act" = quit ] && { scr_leave; return 0; }
        scr_leave
        printf '\n'
        menu_run "$act"
        drain_input
        printf '\n  %spress any key%s ' "$D" "$X"; menu_key
        menu_build; menu_states
        scr_enter ;;
      *) : ;;
    esac
  done
}

menu_run(){
  case "$1" in
    connect)   if sky && sky_is_up "$(sky_status)"; then cmd_disconnect; else cmd_connect; fi ;;
    status)    cmd_status ;;
    verify)    cmd_verify ;;
    names)     cmd_names ;;
    backup)    cmd_backup ;;
    trophies)  cmd_trophies ;;
    register)  cmd_register ;;
    manage)    cmd_manage ;;
    dns)       cmd_dns ;;
    ssl)       cmd_ssl ;;
    magnet)    local p; p=$(ask "path to share" ""); [ -n "$p" ] && cmd_magnet "$p" ;;
    ipfs)      cmd_ipfs ;;
    watch)     cmd_watch ls ;;
    records)   banner; head_ "your records"; cmd_records; echo ;;
    rekey)     cmd_rekey ;;
    build)     cmd_build ;;
    emc)       cmd_emc ;;
    doom)      cmd_doom solo ;;
    why)       cmd_why ;;
    button)    cmd_button ;;
    doctor)    cmd_doctor ;;
    selftest)  cmd_selftest ;;
  esac
}

# For terminals that mangle escape sequences, or a shell where raw reads are
# refused. Same order, typed instead of pointed at.
menu_plain(){
  local a i n
  while :; do
    menu_build
    printf '\n'
    n=0
    for ((i=0;i<${#MENU_LABEL[@]};i++)); do
      [ -z "${MENU_ACT[$i]}" ] && { printf '\n'; continue; }
      n=$((n+1))
      printf '  %s%2s%s  %-18s %s\n' "$B" "$n" "$X" "${MENU_LABEL[$i]}" "$(menu_state "${MENU_ACT[$i]}")"
    done
    printf '\n  %snumber, then enter%s ' "$D" "$X"
    read -r a </dev/tty 2>/dev/null || return 0
    case "$a" in ''|q|Q) say ""; return 0 ;; esac
    n=0
    for ((i=0;i<${#MENU_LABEL[@]};i++)); do
      [ -z "${MENU_ACT[$i]}" ] && continue
      n=$((n+1))
      if [ "$n" = "$a" ]; then
        [ "${MENU_ACT[$i]}" = quit ] && { say ""; return 0; }
        menu_run "${MENU_ACT[$i]}"; break
      fi
    done
  done
}

# ── doctor ──────────────────────────────────────────────────
cmd_doctor(){
  banner
  head_ "here"
  [ "$WIN" = 1 ] && ok "Windows, Git Bash" || ok "$(uname -s) $(uname -m)"
  [ "$UNI" = 1 ] && note "unicode on" || note "ascii mode"
  [ "$DRY" = 1 ] && hm "dry run — nothing would be written"

  head_ "tools"
  local py g
  if py=$(find_py); then ok "python  $("$py" -V 2>&1 | tr -d '\r')"; else no "python 3 — install it"; fi
  local t; for t in git curl tar; do
    command -v $t >/dev/null && ok "$t" || no "$t — install it"; done
  if command -v dig >/dev/null; then ok "dig"
  elif command -v nslookup >/dev/null; then hm "no dig; nslookup will do"
  else hm "no DNS tool — mesh lookups fall back to defaults"; fi
  command -v emercoin-cli >/dev/null && ok "emercoin-cli" || hm "no emercoin-cli — register elsewhere"
  local enc; enc=$(crypt_tool) && ok "backup encryption: $enc" || hm "no age/gpg/openssl — backups stay plaintext"
  if g=$(doom_game 2>/dev/null); then
    doom_iwad >/dev/null 2>&1 && ok "doom  $g" || hm "doom, but no IWAD — run: $SELF doom setup"
  else hm "no doom — run: $SELF doom setup"; fi

  head_ "the trees"
  printf '    %s%-9s%s %s\n' "$D" "GOPATH" "$X" "$GOPATH"
  if [ -d "$SKY_GO" ]; then ok "skywire  $SKY_GO $(git_head "$SKY_GO" 2>/dev/null | sed 's/^/@ /')"
  else no "skywire  $SKY_GO — missing ($SELF build skywire)"; fi
  if [ -d "$NESS_GO" ]; then ok "ness     $NESS_GO $(git_head "$NESS_GO" 2>/dev/null | sed 's/^/@ /')"
  else no "ness     $NESS_GO — missing ($SELF build ness)"; fi
  local sb
  if sb=$(find_sky skywire-cli);   then ok "skywire-cli    $sb";   else hm "skywire-cli not built"; fi
  if sb=$(find_sky skywire-visor); then ok "skywire-visor  $sb"; else hm "skywire-visor not built"; fi

  head_ "source"
  if have_src; then ok "PrivatenessTools + venv"; note "$SRC"
    local p; p=$(conf_get PATCHES); [ -n "$p" ] && note "local patches applied: $p"
  elif [ -d "$SRC" ]; then hm "cloned, no venv — run: $SELF setup"
  else no "missing — run: $SELF setup"; fi

  head_ "keys"
  have_user && ok "users.key.json" || no "users.key.json — run: $SELF"
  have_node && ok "node.key.json"  || no "node.key.json — run: $SELF"
  [ -f "$WL" ] && ok "watchlist.json" || hm "no watchlist (optional)"
  [ -f "$KEYS/chaoskey.seed" ]  && ok "chaoskey.seed"  || hm "no chaos key (optional)"
  if [ "$WIN" = 0 ] && [ -d "$KEYS" ]; then
    local perm; perm=$(ls -ld "$KEYS" | cut -c1-10)
    [ "$perm" = "drwx------" ] && ok "$KEYS is yours alone" || hm "$KEYS is $perm — chmod 700 it"
  fi
  local bf; bf=$(backup_newest)
  if [ -n "$bf" ]; then
    ok "backup: $(basename "$bf")"
    backup_encrypted && note "encrypted" || hm "not encrypted — $SELF backup offers it"
  else hm "no backup — run: $SELF backup"; fi

  head_ "config"
  if [ -f "$CONF" ]; then
    local k v; for k in NESS_USER NODE_URL TARIFF SERVICES NETWORK ORG ENTROPY LEASE; do
      v=$(conf_get "$k"); [ -n "$v" ] && printf '    %s%-9s%s %s\n' "$D" "$k" "$X" "$v"
    done
  else hm "nothing set yet — just run: $SELF"; fi
  [ -f "$LOG" ] && note "log: $LOG ($(wc -l < "$LOG" | tr -d ' ') lines)"
  echo
}

# ── setup ───────────────────────────────────────────────────
# Patches live here as data, are applied idempotently, and are recorded in
# the config so `doctor` can say what was touched. Before a pull we put the
# tree back the way upstream left it, pull, then re-apply.
apply_patches(){
  local py; py=$(find_py) || return 1
  local applied
  applied=$("$py" - "$SRC" <<'PYEOF'
import sys, os
src = sys.argv[1]; done = []
# 1. findUser crashes on a first run: no keyfile means __users is still False,
#    and `username in False` raises TypeError. addNewUser already guards this.
p = os.path.join(src, "NessKeys/keys/Users.py")
try:
    t = open(p).read()
    old = "    def findUser(self, username: str):\n        if username in self.__users:"
    new = "    def findUser(self, username: str):\n        if self.__users == False:\n            return False\n        if username in self.__users:"
    if old in t:
        open(p, "w").write(t.replace(old, new)); done.append("users-finduser-firstrun")
    elif new in t:
        done.append("users-finduser-firstrun")
except OSError:
    pass
# 2. createNodeKey saves a bare "node.key.json" with no self.fileName(), so the
#    node key lands in the working directory instead of the keys directory.
p = os.path.join(src, "NessKeys/KeyManager.py")
try:
    t = open(p).read()
    old = '        filename = "node.key.json"'
    new = '        filename = self.fileName("node.key.json")'
    if old in t:
        open(p, "w").write(t.replace(old, new)); done.append("keymanager-nodekey-path")
    elif new in t:
        done.append("keymanager-nodekey-path")
except OSError:
    pass
print(",".join(done))
PYEOF
)
  [ -n "$applied" ] && conf_set PATCHES "$applied"
  printf '%s' "$applied"
}

src_update(){
  # Our patches make the tree dirty, which makes --ff-only fail forever.
  # Put it back, pull, re-apply. And say so out loud when it fails.
  ( cd "$SRC" && git checkout -- . >/dev/null 2>&1 )
  local out
  if out=$( cd "$SRC" && git pull --ff-only 2>&1 ); then
    printf '%s' "$out" | grep -q 'Already up to date' && note "already up to date" || ok "updated from upstream"
  else
    hm "couldn't pull from upstream — carrying on with what is here"
    note "$(printf '%s' "$out" | head -2)"
  fi
  local p; p=$(apply_patches)
  [ -n "$p" ] && note "local patches: $p"
  return 0
}

# Real progress, read from pip's own output. No spinner pretending to know.
pip_watch(){ # pip_watch <logfile> <pid>
  local lf="$1" pid="$2" last="" cur
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(grep -aoE '^(Collecting|Downloading|Installing collected packages|Building wheel for) ?[A-Za-z0-9_.-]*' "$lf" 2>/dev/null | tail -1)
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
      last="$cur"
      printf '\r    %s%-60s%s' "$D" "$(printf '%s' "$cur" | cut -c1-60)" "$X"
    fi
    sleep 1
  done
  printf '\r%-70s\r' " "
}

cmd_setup(){
  local py
  py=$(find_py) || {
    no "No Python 3."
    if   [ "$WIN" = 1 ]                ; then note "winget install Python.Python.3.12"
    elif command -v apt-get >/dev/null ; then note "$SUDO apt-get install -y python3 python3-venv python3-pip git"
    elif command -v dnf >/dev/null     ; then note "$SUDO dnf install -y python3 python3-pip git"
    elif command -v brew >/dev/null    ; then note "brew install python git"; fi
    return 1; }
  command -v git >/dev/null || { no "git is missing."; return 1; }

  mkdir -p "$(dirname "$SRC")"
  if [ -d "$SRC/.git" ]; then
    ok "already cloned"; src_update
  else
    printf '  %s%s%s cloning PrivatenessTools…\n' "$C" "$DOT" "$X"
    git clone --depth 1 "$REPO" "$SRC" >/dev/null 2>&1 || { no "clone failed"; return 1; }
    ok "cloned"
  fi

  printf '  %s%s%s building the venv…\n' "$C" "$DOT" "$X"
  ( cd "$SRC" && "$py" -m venv venv ) >/dev/null 2>&1 || {
    no "venv failed"; note "on Debian: $SUDO apt-get install python3-venv"; return 1; }
  local vpy; vpy=$(find_py) || { no "venv python not found"; return 1; }

  mkdir -p "$KEYS"; chmod 700 "$KEYS" 2>/dev/null
  local lf="$KEYS/setup.log"; : > "$lf"; chmod 600 "$lf" 2>/dev/null

  printf '  %s%s%s installing dependencies…\n' "$C" "$DOT" "$X"
  (
    "$vpy" -m pip install --upgrade pip wheel
    if [ -f "$SRC/requirements.txt" ]; then
      "$vpy" -m pip install -r "$SRC/requirements.txt"
    else
      "$vpy" -m pip install requests prettytable validators lxml pycryptodome pynacl \
        random_word humanize charset-normalizer idna urllib3 certifi wcwidth cffi \
        pyyaml packaging pluggy pycparser
    fi
  ) >> "$lf" 2>&1 &
  local pid=$!

  # A minute of dead air is where people ^C. Offer the obvious alternative.
  local played=0
  if [ "$TTY" = 1 ] && [ "$YES" = 0 ] && doom_game >/dev/null 2>&1 && doom_iwad >/dev/null 2>&1; then
    if confirm "This takes a minute. Shoot something while it runs?"; then
      played=1
      doom_play solo
      printf '\n  %swelcome back.%s\n' "$D" "$X"
    fi
  fi
  [ "$played" = 0 ] && pip_watch "$lf" "$pid"
  wait "$pid"; local rc=$?
  if [ "$rc" != 0 ]; then
    no "dependencies failed"
    note "the last of it:"
    tail -5 "$lf" | sed "s/^/      $D/;s/\$/$X/"
    note "full output: $lf"
    return 1
  fi
  local installed
  installed=$(grep -ac '^Successfully installed' "$lf" 2>/dev/null || echo 0)
  [ "$installed" -gt 0 ] && note "$(grep -a '^Successfully installed' "$lf" | tail -1 | wc -w | tr -d ' ') packages installed"

  local p; p=$(apply_patches); [ -n "$p" ] && note "local patches: $p"
  ok "ready"
  logline "setup" "$SRC"
  trophy_scan
}

# ── the two trees ───────────────────────────────────────────
# Clone and build both where the import path says they belong. Every command
# is printed before it runs, and a failure prints the last of the real output
# instead of "build failed".
tree_get(){ # tree_get <dir> <repo> <label>
  local dir="$1" repo="$2" lbl="$3"
  if [ -d "$dir/.git" ]; then
    ok "$lbl already cloned"
    note "$dir @ $(git_head "$dir")"
    if confirm "Pull the latest $lbl?"; then
      local out
      if out=$( cd "$dir" && git pull --ff-only 2>&1 ); then
        note "$(printf '%s' "$out" | head -1)"
      else
        hm "pull refused — leaving the tree as it is"
        printf '%s\n' "$out" | head -4 | sed "s/^/      $D/;s/\$/$X/"
      fi
    fi
    return 0
  fi
  command -v git >/dev/null || { no "git is missing"; return 1; }
  mkdir -p "$(dirname "$dir")" || { no "cannot create $(dirname "$dir")"; return 1; }
  printf '  %sgit clone %s %s%s\n' "$B" "$repo" "$dir" "$X"
  local out
  if out=$(git clone "$repo" "$dir" 2>&1); then ok "$lbl cloned"; return 0; fi
  no "clone failed"
  printf '%s\n' "$out" | tail -5 | sed "s/^/      $D/;s/\$/$X/"
  return 1
}

tree_build(){ # tree_build <dir> <label>
  local dir="$1" lbl="$2" log out
  command -v go >/dev/null 2>&1 || {
    no "no Go toolchain on this machine"
    note "https://go.dev/dl/  — then: export PATH=\$PATH:/usr/local/go/bin"
    return 1; }
  note "go $(go version 2>/dev/null | awk '{print $3}')"
  log="$KEYS/build-$lbl.log"; mkdir -p "$KEYS" 2>/dev/null
  if [ -f "$dir/Makefile" ] && grep -q '^build:' "$dir/Makefile" 2>/dev/null; then
    printf '  %smake build%s   %s(in %s)%s\n' "$B" "$X" "$D" "$dir" "$X"
    ( cd "$dir" && make build ) > "$log" 2>&1 && { ok "$lbl built"; return 0; }
    hm "make build failed — trying go build"
  fi
  printf '  %sgo install ./cmd/...%s   %s(in %s)%s\n' "$B" "$X" "$D" "$dir" "$X"
  if ( cd "$dir" && GOPATH="$GOPATH" go install ./cmd/... ) >> "$log" 2>&1; then
    ok "$lbl built into $GOPATH/bin"
    return 0
  fi
  no "$lbl would not build"
  note "the last of it:"
  tail -12 "$log" | sed "s/^/      $D/;s/\$/$X/"
  note "whole log: $log"
  return 1
}

cmd_build(){
  banner
  head_ "where these live"
  printf '  %sness%s     %s\n' "$D" "$X" "$NESS_GO"
  printf '  %sskywire%s  %s\n' "$D" "$X" "$SKY_GO"
  note "GOPATH=$GOPATH — set GOPATH, NESS_GO_SRC or SKY_GO_SRC to move them"

  local which="${1:-all}"
  case "$which" in
    sky|skywire)
      head_ "skywire"; tree_get "$SKY_GO" "$SKY_REPO" skywire && tree_build "$SKY_GO" skywire ;;
    ness)
      head_ "ness"; tree_get "$NESS_GO" "$NESS_REPO" ness && tree_build "$NESS_GO" ness ;;
    all)
      head_ "skywire"; tree_get "$SKY_GO" "$SKY_REPO" skywire && tree_build "$SKY_GO" skywire
      head_ "ness";    tree_get "$NESS_GO" "$NESS_REPO" ness    && tree_build "$NESS_GO" ness ;;
    *) die "Don't know that one." "$SELF build [ness|skywire]" ;;
  esac

  head_ "what came out"
  local b
  if b=$(find_sky skywire-cli); then ok "skywire-cli  $b"
  else hm "no skywire-cli yet"; note "looked in: PATH, $GOPATH/bin, $SKY_GO, $SKY_GO/build"; fi
  if b=$(find_sky skywire-visor); then ok "skywire-visor  $b"
  else hm "no skywire-visor yet"; fi
  say ""
  note "then: $SELF connect"
  echo
}

# ── keys ────────────────────────────────────────────────────
cmd_user(){
  local name="${1:-}"
  [ -n "$name" ] || name=$(ask "your name" "${USER:-master01}")
  [ -n "$name" ] || die "Need a name." "$SELF user <name>"
  have_user && { hm "users.key.json already exists — leaving it alone"; note "to start over: $SELF rekey"; return 0; }
  note "entropy setting: $(ent) — passed straight to PrivatenessTools' keygen"
  note "what it does with it is upstream's business, not this script's claim"
  pnt keygen.py user "$name" "$(ent)" || die "keygen failed" "$SELF doctor"
  have_user || die "keygen reported no error but users.key.json is missing." "$SELF doctor"
  conf_set NESS_USER "$name"
  logline "user" "$name"
  ok "you are ${B}$name${X}"
  trophy_scan
}

cmd_node(){
  local user; user=$(conf_get NESS_USER)
  [ -n "$user" ] || die "No master user yet." "$SELF"
  have_user || die "users.key.json missing." "$SELF"
  have_node && { hm "node.key.json already exists — leaving it alone"; note "to start over: $SELF rekey"; return 0; }

  local url tariff svc net
  if [ $# -ge 4 ]; then url="$1"; tariff="$2"; svc="$3"; net="$4"
  else
    url=$(ask    "URL"          "$(cdef NODE_URL http://node1.private.ness)")
    tariff=$(ask "NCH per hour" "$(cdef TARIFF   1000)")
    svc=$(ask    "services"     "$(cdef SERVICES prng,files)")
    net=$(ask    "networks"     "$(cdef NETWORK  inet)")
  fi
  [ -n "$url" ]  || die "The node needs a URL." "$SELF node"
  [ -n "$svc" ]  || die "The node needs at least one service." "$SELF node"
  [ -n "$net" ]  || die "The node needs at least one network." "$SELF node"
  case "$tariff" in ''|*[!0-9]*) die "Tariff must be a whole number of NCH, got: '$tariff'" "$SELF node" ;; esac
  conf_set NODE_URL "$url"; conf_set TARIFF "$tariff"
  conf_set SERVICES "$svc"; conf_set NETWORK "$net"
  note "keygen node <url> <tariff> <master-user> \"<services>\" \"<network>\" <entropy>"
  pnt keygen.py node "$url" "$tariff" "$user" "$svc" "$net" "$(ent)" || die "keygen failed" "$SELF doctor"
  have_node || die "keygen reported no error but node.key.json is missing." "$SELF doctor"
  logline "node" "$url"
  ok "node key written for ${B}$url${X}"
  trophy_scan
}

cmd_rekey(){
  banner
  local want="${1:-}"
  head_ "starting over"
  if [ -n "$want" ]; then
    printf '  %sRebuilding your keys so they say:%s %s%s%s\n' "$D" "$X" "$GOLD" "$want" "$X"
    note "that is the name already registered on the chain"
    note "it fixes the NAME. The record on chain was signed by your old key, so"
    note "you will still need to publish the new record afterwards — $SELF fix"
  fi
  have_user || die "There are no keys to replace." "$SELF"
  say ""
  printf '  %sYour name and node URL are baked into these keys. New keys mean a\n' "$Y"
  printf '  new identity: anything already on chain under the old one stays there,\n'
  printf '  under the old key, and does not follow you.%s\n\n' "$X"
  local names; names=$(wallet_names)
  if [ -n "$names" ]; then
    hm "these names are already registered from this wallet:"
    printf '%s\n' "$names" | sed "s/^/      $D/;s/\$/$X/"
    note "they will keep pointing at the old key until you update them"
  fi
  say ""
  local t; t=$(ask "type REKEY to archive the current keys" "")
  [ "$t" = "REKEY" ] || { hm "nothing moved"; echo; return 0; }
  local dest; dest="$KEYS.old-$(date -u +%Y%m%d-%H%M%S)"
  cmd_backup_quiet
  mv "$KEYS" "$dest" || die "couldn't move $KEYS"
  mkdir -p "$KEYS"; chmod 700 "$KEYS" 2>/dev/null
  ok "old keys archived to $dest"
  logline "rekey" "$dest"
  if [ -n "$want" ]; then
    # strip any namespace prefix — keygen wants the bare user name
    local bare="${want##*:}"
    say ""
    if confirm "Build new keys now, as \"$bare\"?"; then
      cmd_setup >/dev/null 2>&1 || true
      cmd_user "$bare" || return 1
      say ""
      ok "your keys now say $bare"
      say ""
      hm "the name matches now. The RECORD does not, and cannot:"
      note "the one on chain was made by the keys you just archived."
      note "publish the new one over it:   $SELF fix     (or $SELF register)"
      echo; return 0
    fi
  fi
  note "nothing was deleted. Run $SELF when you're ready to build the new ones."
  echo
}

# ── records ─────────────────────────────────────────────────
cmd_records(){
  have_user || die "No keys yet." "$SELF"
  local f n v bytes state
  for f in users node; do
    [ -f "$KEYS/$f.key.json" ] || continue
    n=$(pnt key.py nvs "$KEYS/$f.key.json" 2>/dev/null | tr -d '\r')
    v=$(pnt key.py worm "$KEYS/$f.key.json" 2>/dev/null)
    bytes=$(printf '%s' "$v" | wc -c | tr -d ' ')
    printf '\n  %s%s%s %s%s%s\n' "$GOLD" "$HEX" "$X" "$B" "$n" "$X"
    if emc_up; then state=$(nvs_state "$n"); else state="not checked (no node here)"; fi
    printf '    %s%s bytes of WORM XML · %s%s\n' "$D" "$bytes" "$state" "$X"
    if [ "$RAW" = 1 ]; then
      printf '%s' "$v" | sed "s/^/      $D/;s/\$/$X/"
    else
      printf '%s' "$v" | head -3 | sed "s/^/      $D/;s/\$/$X/"
      note "  … $SELF records --raw for the whole document"
    fi
  done
  say ""
  note "nvs is the name. worm is the value — an XML document, not a one-liner."
}

# ── fees, observed rather than asserted ─────────────────────
# This script does not know Emercoin's fee schedule and will not pretend to.
# It records what each operation actually cost this wallet and reports that.
fee_record(){ # fee_record <op> <name> <bytes> <lease> <delta>
  mkdir -p "$KEYS" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" >> "$FEES"
  chmod 600 "$FEES" 2>/dev/null
}
fee_forecast(){ # fee_forecast <bytes> <lease>
  local bal; bal=$(emc_balance)
  [ -n "$bal" ] && printf '  %swallet%s %s EMC\n' "$D" "$X" "$bal"
  if [ ! -s "$FEES" ]; then
    printf '  %scost%s   %sunknown — this wallet has no observed operation yet.%s\n' "$D" "$X" "$Y" "$X"
    note "after this one lands, the next forecast comes from what this actually cost"
    return 0
  fi
  local n lo hi
  n=$(wc -l < "$FEES" | tr -d ' ')
  lo=$(cut -f6 "$FEES" | sort -g | head -1)
  hi=$(cut -f6 "$FEES" | sort -g | tail -1)
  if [ "$lo" = "$hi" ]; then
    printf '  %scost%s   %s EMC %s(observed once, on this wallet)%s\n' "$D" "$X" "$lo" "$D" "$X"
  else
    printf '  %scost%s   %s to %s EMC %s(observed across %s operations on this wallet)%s\n' \
      "$D" "$X" "$lo" "$hi" "$D" "$n" "$X"
  fi
  note "wallet delta, so it includes anything locked in the name output — not a fee schedule"
}

# ── the one place that writes ───────────────────────────────
# Every record goes through here: read the chain, size it, price it, then ask.
nvs_write(){ # nvs_write <name> <value> <lease> [valuefile]
  local name="$1" value="$2" lease="$3" vf="${4:-}" state cmd out bytes before after
  bytes=$(printf '%s' "$value" | wc -c | tr -d ' ')

  if [ "$bytes" -gt "$NVS_MAX" ]; then
    no "value is $bytes bytes; this script refuses above $NVS_MAX"
    note "raise it deliberately with NESS_NVS_MAX=<n> if your node accepts more"
    return 1
  fi

  if ! emc_cli || [ "$DRY" = 1 ]; then
    head_ "$([ "$DRY" = 1 ] && echo "dry run — nothing sent" || echo "no emercoin-cli here")"
    say ""
    printf '  emercoin-cli name_show "%s"\n' "$name"
    if [ -n "$vf" ]; then printf '  emercoin-cli name_new "%s" "$(cat %s)" %s\n' "$name" "$vf" "$lease"
    else printf '  emercoin-cli name_new "%s" "%s" %s\n' "$name" "$value" "$lease"; fi
    note "run those where your node is"
    return 0
  fi

  head_ "checking the chain"
  state=$(nvs_state "$name")
  case "$state" in
    theirs)  no "taken, and not by this wallet"; note "pick another name"; return 1 ;;
    unknown) no "couldn't read the chain — node running and synced?"; note "emercoin-cli name_show \"$name\""; return 1 ;;
    free)    ok "free";          cmd="name_new" ;;
    mine)    ok "yours already"; cmd="name_update" ;;
  esac

  # What an update would overwrite. Never replace a value blind.
  if [ "$cmd" = "name_update" ]; then
    local cur cf nf
    cur=$(nvs_value "$name")
    if [ -n "$cur" ]; then
      cf=$(mktemp); nf=$(mktemp)
      printf '%s\n' "$cur" > "$cf"; printf '%s\n' "$value" > "$nf"
      head_ "what changes"
      if command -v diff >/dev/null 2>&1; then
        if diff -u "$cf" "$nf" > /dev/null; then hm "the value is identical — this only renews the lease"
        else diff -u --label "on chain" --label "proposed" "$cf" "$nf" | tail -n +3 | sed "s/^/    /"; fi
      else
        note "on chain: $(printf '%s' "$cur" | head -c 120)"
        note "proposed: $(printf '%s' "$value" | head -c 120)"
      fi
      rm -f "$cf" "$nf"
    fi
  fi

  head_ "what it costs"
  fee_forecast "$bytes" "$lease"
  printf '  %ssize%s   %s bytes\n' "$D" "$X" "$bytes"

  printf '\n  %s%s "%s" "%s" %s%s\n' "$B" "emercoin-cli $cmd" "$name" "$([ -n "$vf" ] && echo "<$(basename "$vf")>" || printf '%s' "$value")" "$lease" "$X"
  printf '  %s%s. This cannot be undone.%s\n' "$D" "$(lease_human "$lease")" "$X"

  if confirm_write "$cmd $name"; then
    before=$(emc_balance)
    out=$(emercoin-cli "$cmd" "$name" "$value" "$lease" 2>&1)
    if printf '%s' "$out" | grep -qiE '^[0-9a-f]{64}$|"txid"'; then
      local txid; txid=$(printf '%s' "$out" | tr -d '"' | grep -oE '[0-9a-f]{64}' | head -1)
      ok "broadcast"
      printf '    %stxid%s %s\n' "$D" "$X" "$txid"
      logline "$cmd" "$name $txid"
      after=$(emc_balance)
      if [ -n "$before" ] && [ -n "$after" ]; then
        local delta; delta=$(awk -v a="$before" -v b="$after" 'BEGIN{printf "%.8f", a-b}')
        fee_record "$cmd" "$name" "$bytes" "$lease" "$delta"
        note "wallet delta $delta EMC — recorded, so the next forecast is real"
      fi
      await_block "$txid" "$name"
    else
      no "the node refused it"; note "$out"
      logline "refused" "$name: $(printf '%s' "$out" | head -c 120)"
      return 1
    fi
  else hm "skipped"; fi
  return 0
}

# The moment worth celebrating is the block, not the broadcast.
# A txid is a thing you said. A confirmation is a thing that happened.
await_block(){ # await_block <txid> <name>
  local txid="$1" name="$2" i conf
  [ -n "$txid" ] || return 0
  emc_up || return 0
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then note "it lands when the block does"; return 0; fi
  if ! confirm "Wait here until it's in a block?"; then
    note "it lands when the block does — $SELF status will show it"
    return 0
  fi
  printf '  %swaiting'"$X" "$D"
  for ((i=0;i<120;i++)); do
    conf=$(emercoin-cli gettransaction "$txid" 2>/dev/null | grep -o '"confirmations" *: *-\?[0-9]*' | grep -oE '\-?[0-9]+$' | head -1)
    if [ -n "$conf" ] && [ "$conf" -ge 1 ] 2>/dev/null; then
      printf '\r%-40s\r' " "
      rule 46
      printf '  %s%s  %sIT LANDED%s  %s%s\n' "$GOLD" "$HEX" "$B" "$X" "$GOLD" "$X"
      printf '  %s%s%s is on the chain at %s confirmation(s).\n' "$B" "$name" "$X" "$conf"
      printf '  %sBlock %s. Nobody granted you that. You took it.%s\n' "$D" "$(emercoin-cli getblockcount 2>/dev/null)" "$X"
      rule 46
      [ -z "${NO_BELL:-}" ] && printf '\a'
      logline "confirmed" "$name $txid"
      trophy_scan
      return 0
    fi
    printf '.'
    sleep 5
  done
  printf '\r%-40s\r' " "
  hm "still unconfirmed after ten minutes — that is normal, not a failure"
  note "check later: $SELF status"
}

# ── register ────────────────────────────────────────────────
cmd_register(){
  banner
  have_user || die "No keys yet." "$SELF"
  local lease; lease=$(cdef LEASE 1826)
  conf_set LEASE "$lease"
  printf '\n  %sregistering as%s %s%s%s   %snode%s %s\n' \
    "$D" "$X" "$B" "$(cdef NESS_USER '?')" "$X" "$D" "$X" "$(cdef NODE_URL '?')"
  note "those two are baked into the keys; remaking them means new keys ($SELF rekey)"
  review_step "you can still change" ORG LEASE
  lease=$(cdef LEASE 1826)

  local f n wf v
  for f in users node; do
    [ -f "$KEYS/$f.key.json" ] || continue
    n=$(pnt key.py nvs "$KEYS/$f.key.json" 2>/dev/null | tr -d '\r')
    wf="$KEYS/$f.worm.xml"
    pnt key.py worm "$KEYS/$f.key.json" 2>/dev/null > "$wf"
    chmod 600 "$wf" 2>/dev/null
    v=$(cat "$wf")
    head_ "$n"
    printf '  %sfrom %s%s\n' "$D" "$wf" "$X"
    head -6 "$wf" | sed 's/^/    /'
    [ "$(wc -l < "$wf")" -gt 6 ] && note "…"
    nvs_write "$n" "$v" "$lease" "$wf"
  done

  say ""
  [ -n "$(conf_get NODE_URL)" ] && note "still to do: a dns: record for $(conf_get NODE_URL) — $SELF dns"
  trophy_scan
  echo
}

# ── backup ──────────────────────────────────────────────────
crypt_tool(){
  command -v age     >/dev/null 2>&1 && { echo age;     return 0; }
  command -v gpg     >/dev/null 2>&1 && { echo gpg;     return 0; }
  command -v openssl >/dev/null 2>&1 && { echo openssl; return 0; }
  return 1
}
# The tarball PATH goes to stdout so a caller can capture it.
# Everything a human reads goes to stderr, so capturing doesn't swallow it.
backup_make(){
  [ -d "$KEYS" ] || return 1
  local out; out="$HOME/privateness-keys-$(date -u +%Y%m%d-%H%M%S).tar.gz"
  # -C the PARENT of the keys directory, wherever it actually is. On Windows
  # PrivatenessTools picks that directory, and it is not always under $HOME.
  if tar czf "$out" -C "$(dirname "$KEYS")" "$(basename "$KEYS")" 2>/dev/null; then
    chmod 600 "$out" 2>/dev/null
    ok "$out" >&2
    note "put that somewhere the machine isn't" >&2
    logline "backup" "$out"
    printf '%s' "$out"
    return 0
  fi
  hm "tar failed" >&2; return 1
}
cmd_backup_quiet(){ backup_make >/dev/null; }
cmd_backup(){
  banner; head_ "backup"
  [ -d "$KEYS" ] || die "Nothing to back up yet." "$SELF"
  if confirm "Print a seed phrase? Not while anyone is watching your screen."; then
    pnt keygen.py backup "$(ent)" || hm "seed generation failed"
  fi
  local tarball; tarball=$(backup_make)
  [ -n "$tarball" ] && [ -f "$tarball" ] || { echo; return 1; }

  local tool; if tool=$(crypt_tool); then
    say ""
    if confirm "Encrypt it? A plaintext tarball of your keys is a key."; then
      case "$tool" in
        age)
          if age -p -o "$tarball.age" "$tarball" 2>/dev/null; then
            chmod 600 "$tarball.age"; rm -f "$tarball"; ok "$tarball.age"
            logline "backup-encrypted" "$tarball.age"
          else hm "age declined — the plaintext tarball is still there"; fi ;;
        gpg)
          if gpg --symmetric --cipher-algo AES256 -o "$tarball.gpg" "$tarball" 2>/dev/null; then
            chmod 600 "$tarball.gpg"; rm -f "$tarball"; ok "$tarball.gpg"
            logline "backup-encrypted" "$tarball.gpg"
          else hm "gpg declined — the plaintext tarball is still there"; fi ;;
        openssl)
          if openssl enc -aes-256-cbc -pbkdf2 -salt -in "$tarball" -out "$tarball.enc"; then
            chmod 600 "$tarball.enc"; rm -f "$tarball"; ok "$tarball.enc"
            note "restore: openssl enc -d -aes-256-cbc -pbkdf2 -in <file> -out keys.tar.gz"
            logline "backup-encrypted" "$tarball.enc"
          else hm "openssl declined — the plaintext tarball is still there"; fi ;;
      esac
    fi
  else
    hm "no age, gpg or openssl here — the tarball is plaintext at mode 600"
  fi
  trophy_scan
  echo
}

# ── watchlist ───────────────────────────────────────────────
wl_init(){
  [ -f "$WL" ] && return 0
  mkdir -p "$KEYS"; chmod 700 "$KEYS" 2>/dev/null
  cat > "$WL" <<'EOF'
{
  "schema": "ness:worm:watchlist:1",
  "note": "Names this operator watches. Advisory only — nothing here can sign, admit or revoke. Delete freely.",
  "authorities": [
    {"name": "dpo:PrivateNESS.Network", "label": "home", "trust": "observe"},
    {"name": "val:privatenessnetwork", "label": "genesis", "trust": "observe"}
  ],
  "wallets": []
}
EOF
  chmod 600 "$WL" 2>/dev/null
}
wl_py(){
  local py; py=$(find_py) || die "No Python 3 found." "$SELF doctor"
  "$py" - "$WL" "$@" <<'PYEOF'
import json, sys
path, mode = sys.argv[1], sys.argv[2]; args = sys.argv[3:]
try: d = json.load(open(path))
except Exception as e:
    print("watchlist unreadable: %s" % e, file=sys.stderr); sys.exit(1)
d.setdefault("authorities", []); d.setdefault("wallets", [])
def save():
    json.dump(d, open(path, "w"), indent=2); open(path, "a").write("\n")
if mode == "names":
    for a in d["authorities"]: print(a.get("name", ""))
elif mode == "addrs":
    for w in d["wallets"]: print(w.get("address", ""))
elif mode == "ls":
    for a in d["authorities"]:
        print("  %-34s %s" % (a.get("name", ""), a.get("label") or ""))
    for w in d["wallets"]:
        print("  %-34s %s" % (w.get("address", ""), w.get("label") or ""))
    if not d["authorities"] and not d["wallets"]:
        print("  nothing watched. Perfectly fine.")
elif mode == "add":
    val, label = args[0], (args[1] if len(args) > 1 else "")
    if ":" in val:
        if any(a.get("name") == val for a in d["authorities"]):
            print("already watching %s" % val); sys.exit(3)
        d["authorities"].append({"name": val, "label": label, "trust": "observe"})
    else:
        if any(w.get("address") == val for w in d["wallets"]):
            print("already watching %s" % val); sys.exit(3)
        d["wallets"].append({"address": val, "label": label, "mode": "watch-only"})
    save()
elif mode == "rm":
    val = args[0]
    before = len(d["authorities"]) + len(d["wallets"])
    d["authorities"] = [a for a in d["authorities"] if a.get("name") != val]
    d["wallets"] = [w for w in d["wallets"] if w.get("address") != val]
    if before == len(d["authorities"]) + len(d["wallets"]):
        print("not on the list: %s" % val); sys.exit(3)
    save()
PYEOF
}
cmd_watch(){
  wl_init
  case "${1:-ls}" in
    ls) banner; head_ "watching"; wl_py ls || die "couldn't read $WL"
        say ""; note "$WL — plain JSON, edit it by hand whenever you like"; echo ;;
    add) [ -n "${2:-}" ] || die "Nothing given." "$SELF watch add <dpo:Name|EMC-address> [label]"
        wl_py add "$2" "${3:-}" || exit 1; chmod 600 "$WL" 2>/dev/null
        ok "watching $2"; note "it watches; it cannot sign for you or throw you out"
        logline "watch-add" "$2"; trophy_scan ;;
    rm|remove) [ -n "${2:-}" ] || die "Nothing given." "$SELF watch rm <name|address>"
        wl_py rm "$2" || exit 1; chmod 600 "$WL" 2>/dev/null; ok "stopped watching $2"
        logline "watch-rm" "$2" ;;
    check)
        emc_cli || die "No emercoin-cli here." "$SELF doctor"
        banner; head_ "looking things up — changing nothing"
        local x
        for x in $(wl_py names); do printf '\n  %s%s%s\n' "$C" "$x" "$X"
          emercoin-cli name_show "$x" || say "    no answer"; done
        for x in $(wl_py addrs); do printf '\n  %s%s%s\n' "$C" "$x" "$X"
          emercoin-cli getreceivedbyaddress "$x" 0 2>/dev/null || say "    not in this wallet"; done
        say ""; note "advisory only; none of this can act for you"; echo ;;
    *) die "Don't know that one." "$SELF watch [ls|add|rm|check]" ;;
  esac
}

# ── doom ───────────────────────────────────────────────────
# Debian and Ubuntu put games in /usr/games, which is not on PATH for root or
# for non-login shells. A successful apt install therefore looks like a failed
# one. That is why this never worked.
GAMEDIRS="/usr/games:/usr/local/games:/opt/homebrew/bin"
doom_game(){
  local g p
  for g in "${GAME:-}" chocolate-doom chocolate-doom.exe crispy-doom crispy-doom.exe \
           dsda-doom dsda-doom.exe prboom-plus prboom-plus.exe; do
    [ -n "$g" ] || continue
    command -v "$g" >/dev/null 2>&1 && { command -v "$g"; return 0; }
    local hit
    hit=$( IFS=:; for d in $GAMEDIRS; do [ -x "$d/$g" ] && { echo "$d/$g"; break; }; done )
    [ -n "$hit" ] && { echo "$hit"; return 0; }
  done
  for p in "$HOME/ness-doom"/chocolate-doom.exe "$HOME/ness-doom"/*/chocolate-doom.exe \
           "/c/Program Files/Chocolate Doom/chocolate-doom.exe" \
           "/c/Program Files (x86)/Chocolate Doom/chocolate-doom.exe" \
           "$HOME/scoop/apps/chocolate-doom/current/chocolate-doom.exe"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
doom_iwad(){
  local p
  for p in "${IWAD:-}" ./freedoom2.wad ./doom2.wad \
           "$HOME/ness-doom"/*.wad "$HOME/ness-doom"/*/*.wad \
           "$HOME/.local/share/games/doom"/*.wad "$HOME/.config/chocolate-doom"/*.wad \
           /usr/share/games/doom/*.wad /usr/local/share/games/doom/*.wad /usr/share/doom/*.wad \
           "/c/Program Files/Chocolate Doom"/*.wad; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
gh_asset(){
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -i "$2" | head -1
}
doom_setup(){
  head_ "getting doom"
  local ND="$HOME/ness-doom"; mkdir -p "$ND"
  if [ "$WIN" = 1 ]; then
    if   command -v winget >/dev/null; then winget install --id=ChocolateDoom.ChocolateDoom -e >/dev/null 2>&1
    elif command -v scoop  >/dev/null; then scoop install chocolate-doom >/dev/null 2>&1
    elif command -v choco  >/dev/null; then choco install -y chocolate-doom >/dev/null 2>&1; fi
    if ! doom_game >/dev/null; then
      local u; u=$(gh_asset chocolate-doom/chocolate-doom 'win64.*\.zip$')
      [ -z "$u" ] && u=$(gh_asset chocolate-doom/chocolate-doom 'win.*\.zip$')
      if [ -n "$u" ]; then
        printf '  %s%s%s downloading the game…\n' "$C" "$DOT" "$X"
        curl -fL# -o "$ND/game.zip" "$u" \
          && { command -v unzip >/dev/null && unzip -qo "$ND/game.zip" -d "$ND" || tar -xf "$ND/game.zip" -C "$ND"; } \
          && rm -f "$ND/game.zip"
      else
        no "couldn't find a Windows build"
        note "https://www.chocolate-doom.org/wiki/index.php/Downloads — unzip it into $ND"
      fi
    fi
  else
    printf '  %s%s%s installing chocolate-doom…\n' "$C" "$DOT" "$X"
    if   command -v apt-get >/dev/null; then $SUDO apt-get install -y chocolate-doom freedoom >/dev/null 2>&1
    elif command -v dnf     >/dev/null; then $SUDO dnf install -y chocolate-doom freedoom >/dev/null 2>&1
    elif command -v pacman  >/dev/null; then $SUDO pacman -S --needed --noconfirm chocolate-doom freedoom2 >/dev/null 2>&1
    elif command -v apk     >/dev/null; then $SUDO apk add chocolate-doom freedoom >/dev/null 2>&1
    elif command -v zypper  >/dev/null; then $SUDO zypper install -y chocolate-doom freedoom >/dev/null 2>&1
    elif command -v brew    >/dev/null; then brew install chocolate-doom >/dev/null 2>&1
    else no "no package manager I recognise"; fi
  fi
  # Freedoom, because it is BSD and yours to hand around. Not doom2.wad.
  if ! doom_iwad >/dev/null; then
    printf '  %s%s%s fetching Freedoom…\n' "$C" "$DOT" "$X"
    local u; u=$(gh_asset freedoom/freedoom 'freedoom-.*\.zip$')
    if [ -n "$u" ]; then
      curl -fL# -o "$ND/fd.zip" "$u" \
        && { command -v unzip >/dev/null && unzip -qjo "$ND/fd.zip" '*.wad' -d "$ND" || tar -xf "$ND/fd.zip" -C "$ND"; }
      find "$ND" -name '*.wad' -exec cp -n {} "$ND"/ \; 2>/dev/null
      rm -f "$ND/fd.zip"
    else no "couldn't reach the Freedoom release"; note "https://freedoom.github.io"; fi
  fi
  local g i
  g=$(doom_game) && ok "$g" || { no "still no game binary"; return 1; }
  i=$(doom_iwad) && ok "$i" || { no "still no IWAD"; return 1; }
  ok "ready — try: $SELF doom solo"
}
doom_srv(){ # doom_srv <name> -> "port target"
  local out port target
  if command -v dig >/dev/null; then
    out=$(dig +short SRV "$1" 2>/dev/null | head -1)
    [ -n "$out" ] && { echo "$out" | awk '{print $3" "$4}'; return 0; }
  fi
  if command -v nslookup >/dev/null; then
    out=$(nslookup -type=SRV "$1" 2>/dev/null)
    port=$(echo "$out"   | grep -i 'port'         | head -1 | tr -d ' \r' | cut -d= -f2)
    target=$(echo "$out" | grep -i 'svr hostname' | head -1 | tr -d ' \r' | cut -d= -f2)
    [ -z "$target" ] && target=$(echo "$out" | grep -i 'hostname' | head -1 | tr -d ' \r' | cut -d= -f2)
    [ -n "$port" ] && { echo "$port $target"; return 0; }
  fi
  return 1
}
# Runs the game and comes back. The old version exec'd, which meant the wizard
# never got to say anything afterwards.
doom_play(){
  local mode="${1:-solo}"; shift 2>/dev/null || true
  local game iwad skill warp
  game=$(doom_game) || return 1
  iwad=$(doom_iwad) || return 1
  skill="${SKILL:-3}"; warp="${WARP:-1}"
  "$game" -iwad "$iwad" -skill "$skill" -warp "$warp"
  return 0
}
cmd_doom(){
  banner
  local mode="${1:-solo}" publish=0 a
  for a in "$@"; do [ "$a" = "--publish" ] && publish=1; done
  if [ "$mode" = "setup" ]; then doom_setup; local rc=$?; echo; return $rc; fi

  local game iwad
  if ! game=$(doom_game); then
    head_ "doom"; no "no Doom port found"
    note "$SELF doom setup   — fetches it, and a free IWAD"
    if [ "$WIN" = 0 ] && [ -d /usr/games ]; then
      note "if you already installed it, /usr/games may not be on your PATH:"
      note "  export PATH=\$PATH:/usr/games"
    fi
    echo; return 1
  fi
  if ! iwad=$(doom_iwad); then
    head_ "doom"; no "game's here, but no IWAD"
    note "$SELF doom setup   — grabs Freedoom, which is free and plays fine"
    note "or:  IWAD=/path/to/doom2.wad $SELF doom $mode"
    echo; return 1
  fi

  local arena host seats skill warp
  arena="${2:-$(cdef DOOM_ARENA hellfire)}"
  case "$arena" in --*) arena=$(cdef DOOM_ARENA hellfire) ;; esac
  host="${3:-$(cdef NODE_URL http://node1.private.ness)}"
  case "$host" in --*) host=$(cdef NODE_URL http://node1.private.ness) ;; esac
  host="${host#http://}"; host="${host#https://}"; host="${host%%/*}"
  seats="${SEATS:-4}"; skill="${SKILL:-3}"; warp="${WARP:-1}"
  [ "$mode" != solo ] && conf_set DOOM_ARENA "$arena"

  head_ "doom"
  note "$game"
  note "$iwad"

  case "$mode" in
    solo)
      say ""
      printf '  %sJust you and the monsters. Skill %s, map %s.%s\n' "$D" "$skill" "$warp" "$X"
      printf '  %sCheats work here — nobody else to desync.%s\n\n' "$D" "$X"
      doom_play solo
      printf '\n  %swelcome back.%s\n\n' "$D" "$X" ;;
    host)
      local srv port rules
      srv=$(doom_srv "_doom._skywire.$arena.$host") || srv=$(doom_srv "_doom._tcp.$arena.$host") || srv=""
      port=$(echo "$srv" | awk '{print $1}'); port="${port:-666}"
      [ "$publish" = 1 ] && doom_publish "$arena" "$host" "$port"
      rules=""
      [ "${DM:-1}" = 1 ] && rules="-deathmatch -nomonsters"
      say ""
      printf '  %sHolding %s%s%s open on :%s for %s.%s\n\n' "$D" "$B" "$arena" "$D" "$port" "$seats" "$X"
      conf_set DOOM_HOSTED "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # shellcheck disable=SC2086
      "$game" -iwad "$iwad" -server -privateserver -port "$port" \
              -nodes "$seats" -skill "$skill" -warp "$warp" $rules
      printf '\n  %sarena closed.%s\n' "$D" "$X"
      trophy_scan; echo ;;
    join)
      local srv port target
      srv=$(doom_srv "_doom._skywire.$arena.$host") || srv=$(doom_srv "_doom._tcp.$arena.$host") || srv=""
      port=$(echo "$srv" | awk '{print $1}'); port="${port:-666}"
      target=$(echo "$srv" | awk '{print $2}'); target="${target%.}"; target="${target:-$host}"
      say ""
      printf '  %sWalking into %s%s%s at %s:%s%s\n\n' "$D" "$B" "$arena" "$D" "$target" "$port" "$X"
      "$game" -iwad "$iwad" -connect "$target:$port"
      printf '\n  %sout again.%s\n\n' "$D" "$X" ;;
    *) die "Don't know that one." "$SELF doom [setup|solo|host|join] [arena] [host]" ;;
  esac
}

# Put the arena in EmerDNS so people can find it by name instead of by IP.
# The SRV encoding below is a CANDIDATE, not an assertion: check what key form
# your emercoind accepts before you commit it. review_step lets you edit it.
doom_publish(){ # doom_publish <arena> <host> <port>
  local arena="$1" host="$2" port="$3"
  head_ "publishing the arena"
  local ip; ip=$(cdef DNS_A "")
  [ -n "$ip" ] || ip=$(ask "IP the arena answers on" "")
  [ -n "$ip" ] || { hm "no address — not publishing"; return 1; }
  local name="dns:_doom._tcp.$arena.$host"
  local value="SRV=0|0|$port|$host"
  note "the SRV target $host must itself resolve to $ip — that is what $SELF dns writes"
  say ""
  printf '  %sname %s%s%s\n' "$D" "$GOLD" "$name" "$X"
  printf '  %svalue%s %s\n' "$D" "$X" "$value"
  say ""
  printf '  %sThe SRV key form above is a candidate. This script does not know\n' "$Y"
  printf '  your node'"'"'s EmerDNS encoding and will not pretend to — check it,\n'
  printf '  edit it if it is wrong, then confirm.%s\n' "$X"
  local v; v=$(ask "value" "$value")
  nvs_write "$name" "$v" "$(cdef LEASE 1826)"
}

# ── emc ─────────────────────────────────────────────────────
cmd_emc(){
  banner; head_ "getting EMC"
  say "  Name operations cost EMC. Two ways in:"
  say ""
  printf '  %s%s%s %sfaucet%s  https://faucet.ness.cx     %sfree, slow, enough to start%s\n' "$C" "$DOT" "$X" "$B" "$X" "$D" "$X"
  printf '  %s%s%s %sswap%s    https://swap.emercoin.com  %sUSDT (TRC20) in, EMC out%s\n' "$C" "$DOT" "$X" "$B" "$X" "$D" "$X"
  say ""
  note "swap is fixed at 1 USDT = 10 EMC, in 5 or 10 USDT lots, one-way, no refunds."
  note "It is custodial, and a convenience — not part of the sovereignty story."
  note "Agents can use it keylessly over MCP:"
  note "  claude mcp add --transport http swap https://swap.emercoin.com/mcp"
  say ""
  local bal; bal=$(emc_balance) && [ -n "$bal" ] && printf '  %sthis wallet holds%s %s EMC\n\n' "$D" "$X" "$bal"
  printf '  %sThis script will not move money for you. Do that yourself, eyes open.%s\n\n' "$GOLD" "$X"
}

# ── why ─────────────────────────────────────────────────────
cmd_why(){
  banner
  head_ "what you are actually standing on"
  local n=0
  while IFS='~' read -r layer title body; do
    [ -z "$layer" ] && continue
    n=$((n+1))
    printf '\n  %s%s%s %s%-28s%s %s%s%s\n' "$GOLD" "$HEX" "$X" "$B" "$title" "$X" "$D" "$layer" "$X"
    printf '    %s%s%s\n' "$D" "$body" "$X"
  done <<'EOF'
L0~identity anchor~Emercoin NVS and WORM. A name you hold, a document only you can replace. Everything above stands on this and nothing above can outrank it.
L1~LBRTY radio~Conditional first hop. When it's there it opens the conversation out of band, which is the one thing a hostile network can't sit in the middle of.
L2~SoftEther + WireGuard~NAT traversal without begging anyone for a port.
L2.5~Skywire mesh~In every route. Source-routed MPLS, no consensus, no blockchain, and every hop knows only who handed it the packet and who it hands it to.
L3~EmerDNS~Names that resolve without a registrar. 2,000+ domains, one address, no renewal letter from anybody.
L4~EmerSSL / EmerSSH~The certificate IS the login. TLSA, RFC 6698. No CAA, on purpose.
L5~content and trust~ENUMER, DPO, IPFS, emerMAGNET. A CID you can check yourself, a torrent while people care, and an append-only record of who said what.
L7~sovereign services~Inference, entropy, files. Held NESS accrues NCH; NCH is energy, and you spend energy, not money.
EOF
  say ""
  printf '  %sThe rule underneath all of it: no claim without observation.%s\n' "$D" "$X"
  printf '  %sThat is why this script reads the chain before it offers to write to it.%s\n\n' "$D" "$X"
}

# ── help ────────────────────────────────────────────────────
cmd_help(){
  banner
  printf '  %sJust run %s%s%s%s — it works out the next step and does it.%s\n\n' "$D" "$X$B" "$SELF" "$X" "$D" "$X"
  local c t
  while IFS='~' read -r c t; do
    [ -z "$c" ] && continue
    printf '  %s%s%s %s%-23s%s %s\n' "$C" "$HEX" "$X" "$B" "$c" "$X" "$t"
  done <<EOF
build [ness|skywire]~clone and build both trees into $GOPATH/src
connect [pubkey]~one word. Skywire up, and proven up
disconnect~off again, and proven off
button~the same thing with one big button, on loopback
status~where you stand, in one screen
names [--all]~your names, ten at a time
verify~what this machine actually checked, and what it only heard
fix~for anything that failed: the evidence and the exact command
doctor~what's here, what's missing
selftest~prove this machine can run it
setup~clone PrivatenessTools, build the venv
user <name>~your master user key
node [url tariff ...]~the node key
rekey [name]~rebuild your keys, optionally under a name already on chain
records [--raw]~your NVS names and WORM values
register~check the chain, price it, then register
watch [ls/add/rm/check]~names and wallets you keep an eye on
backup~seed phrase, tarball, and encryption
trophies~what this machine can prove you've done
why~what you are actually standing on
doom [solo/host/join]~something to do while the chain syncs
emc~coins for the name fees
ssl~an EmerSSL certificate, passwords gone
dns~point your domain at the node
manage~list, update, renew or delete your names
magnet <path>~a torrent and a CID, in one record
ipfs~pin the UI, or check a CID yourself
EOF
  say ""
  printf '  %sflags%s  --dry-run  print every command, touch nothing\n' "$D" "$X"
  printf '         --yes      take defaults at prompts (still never writes to the chain)\n'
  printf '         --raw      full documents instead of summaries\n'
  say ""
  note "keys    $KEYS"
  note "source  $SRC"
  [ -f "$LOG" ] && note "log     $LOG"
  say ""
  printf '  %sNothing here signs, broadcasts or writes to the chain without you typing yes.%s\n' "$D" "$X"
  printf '  %sRegistration is yours, on purpose.%s\n\n' "$D" "$X"
}

# ── review ──────────────────────────────────────────────────
# Show what is about to be used, and let it be changed or reset first.
review_step(){
  local label="$1"; shift
  local keys="$*" k v a
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then return 0; fi
  while :; do
    printf '\n  %s%s%s\n' "$D" "$label" "$X"
    for k in $keys; do
      v=$(conf_get "$k")
      printf '    %s%-9s%s %s\n' "$C" "$k" "$X" "${v:-${D}(not set)${X}}"
    done
    printf '  %s[enter]%s keep  %se%s edit  %sr%s reset to default  %sq%s quit  ' \
      "$B" "$X" "$B" "$X" "$B" "$X" "$B" "$X"
    read -r a </dev/tty 2>/dev/null || a=""
    case "$a" in
      ""|k|y) return 0 ;;
      e)  for k in $keys; do
            v=$(ask "$k" "$(conf_get "$k")")
            [ -n "$v" ] || continue
            case "$k" in
              LEASE|TARIFF|ENTROPY)
                case "$v" in ''|*[!0-9]*) no "$k must be a whole number — leaving it"; continue ;; esac ;;
              NODE_URL|DNS_NAME)
                case "$v" in *.*|*:*) : ;; *) hm "'$v' doesn't look like a host — keeping it anyway" ;; esac ;;
            esac
            conf_set "$k" "$v"
          done ;;
      r)  local which ok_key
          which=$(ask "reset which? (name from the list, or 'all')" "")
          if [ "$which" = all ]; then
            for k in $keys; do conf_set "$k" ""; done
            ok "reset — those fall back to their defaults again"
          elif [ -n "$which" ]; then
            ok_key=0
            for k in $keys; do [ "$k" = "$which" ] && ok_key=1; done
            if [ "$ok_key" = 1 ]; then conf_set "$which" ""; ok "$which reset to its default"
            else no "'$which' isn't one of the fields above — nothing changed"; fi
          fi ;;
      q)  say ""; die "stopped. nothing was changed on the chain." ;;
      *)  hm "enter, e, r or q" ;;
    esac
  done
}

# 1461 days per 4 years; round rather than truncate, and don't say
# "0 years" for a short lease.
lease_human(){
  local d="$1" y
  y=$(( (d*4+730)/1461 ))
  if [ "$y" -lt 1 ]; then printf '%s days' "$d"
  elif [ "$y" = 1 ]; then printf '%s days, about a year' "$d"
  else printf '%s days, about %s years' "$d" "$y"; fi
}

# A write to the chain needs the word typed out. Enter is not consent.
# This prompt stays flat on purpose. It is the one screen in here that
# does not get a personality.
confirm_write(){
  local a
  if [ "$DRY" = 1 ]; then hm "dry run — not sending"; return 1; fi
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then
    hm "not asking on a non-interactive run — skipping the write"
    return 1
  fi
  printf '\n  %s%s%s  type %syes%s to send this, anything else to skip: ' \
    "$GOLD" "$1" "$X" "$B" "$X"
  read -r a </dev/tty 2>/dev/null || a=""
  [ "$a" = "yes" ]
}

# ── emerssl ─────────────────────────────────────────────────
# Name is ssl:<serial>, the serial lowercased and left-padded to 16 hex chars,
# and it must not begin with 0. First line of the value is <algo>=<fingerprint>
# of the DER certificate. A site hashes the cert you present and compares.
cmd_ssl(){
  banner
  command -v openssl >/dev/null || die "openssl is missing. It ships with Git Bash and every distro." "$SELF doctor"
  local dir="$KEYS/ssl"; mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null

  local cn email days serial
  cn=$(cdef SSL_CN "$(cdef NESS_USER "${USER:-master01}")")
  email=$(cdef SSL_EMAIL "")
  days=$(cdef SSL_DAYS 1826)
  conf_set SSL_CN "$cn"; conf_set SSL_DAYS "$days"
  review_step "the certificate" SSL_CN SSL_EMAIL SSL_DAYS
  cn=$(cdef SSL_CN "$cn"); email=$(cdef SSL_EMAIL "$email"); days=$(cdef SSL_DAYS 1826)

  # 16 hex digits from openssl's CSPRNG. Not $RANDOM, not a timestamp.
  serial=$(openssl rand -hex 8 | tr 'A-Z' 'a-z')
  case "$serial" in 0*) serial="1${serial#?}" ;; esac

  local key="$dir/$serial.key" crt="$dir/$serial.crt" p12="$dir/$serial.p12"
  local subj="/CN=$cn"
  [ -n "$email" ] && subj="$subj/emailAddress=$email"
  # UID=EMC on the issuer is what the stricter validators look for. Self-signed,
  # so subject and issuer are the same DN.
  subj="$subj/UID=EMC"

  head_ "making a certificate"
  note "$subj"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -days "$days" -set_serial "0x$serial" \
    -keyout "$key" -out "$crt" -subj "$subj" >/dev/null 2>&1 \
    || die "openssl refused. Check the name for odd characters." "$SELF ssl"
  chmod 600 "$key" 2>/dev/null
  ok "$crt"

  local fp
  fp=$(openssl x509 -in "$crt" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | cut -d' ' -f1)
  [ -n "$fp" ] || fp=$(openssl x509 -in "$crt" -outform DER | sha256sum | cut -d' ' -f1)
  [ -n "$fp" ] || die "couldn't fingerprint the certificate" "$SELF ssl"

  local name="ssl:$serial" value="sha256=$fp"
  printf '%s\n' "$value" > "$dir/$serial.nvs"

  head_ "the record"
  printf '  %sname %s%s%s\n' "$D" "$GOLD" "$name" "$X"
  printf '  %svalue%s %s\n' "$D" "$X" "$value"
  note "written to $dir/$serial.nvs"

  head_ "for your browser"
  if confirm "Bundle it as PKCS#12 to import? You'll set a password."; then
    if openssl pkcs12 -export -inkey "$key" -in "$crt" -out "$p12" -name "$cn (EmerSSL)"; then
      chmod 600 "$p12" 2>/dev/null; ok "$p12"
      note "import that into your browser, then log in with no password anywhere"
    else hm "pkcs12 export skipped"; fi
  fi

  conf_set SSL_NAME "$name"
  nvs_write "$name" "$value" "$(cdef LEASE 1826)"
  trophy_scan
  echo
}

# ── dns ─────────────────────────────────────────────────────
# EmerDNS values are pipe-separated: A=1.2.3.4|NS=ns.example.com|SD=www,ftp
cmd_dns(){
  banner
  local host ip val
  # Seed DNS_NAME from the node URL only the FIRST time. After that it is
  # yours to set, and this function stops overwriting it on every run.
  if [ -z "$(conf_get DNS_NAME)" ]; then
    host=$(cdef NODE_URL node1.private.ness)
    host="${host#http://}"; host="${host#https://}"; host="${host%%/*}"
    conf_set DNS_NAME "$host"
  fi
  review_step "the domain" DNS_NAME DNS_A DNS_SD
  host=$(cdef DNS_NAME "")
  [ -n "$host" ] || die "No domain to point anywhere." "$SELF dns"
  ip=$(cdef DNS_A "")
  if [ -z "$ip" ]; then
    ip=$(ask "IP address for $host" "")
    [ -n "$ip" ] && conf_set DNS_A "$ip"
  fi
  [ -n "$ip" ] || die "Nothing to point at yet. Give it an A record." "$SELF dns"
  val="A=$ip"
  local sd; sd=$(cdef DNS_SD "")
  [ -n "$sd" ] && val="$val|SD=$sd"

  head_ "the record"
  printf '  %sname %s%s%s\n' "$D" "$GOLD" "dns:$host" "$X"
  printf '  %svalue%s %s\n' "$D" "$X" "$val"
  note "pipe-separated; add SD=www,ftp for subdomains, NS= to delegate"
  nvs_write "dns:$host" "$val" "$(cdef LEASE 1826)"
  trophy_scan
  echo
}

# ── manage ──────────────────────────────────────────────────
cmd_manage(){
  banner
  emc_up || die "This one needs emercoin-cli and a running, synced node." "$SELF doctor"
  head_ "names in this wallet"
  local names n i a
  names=$(wallet_names)
  [ -n "$names" ] || { hm "none yet"; note "make some: $SELF register  ·  $SELF ssl  ·  $SELF dns"; echo; return 0; }
  i=0
  while IFS= read -r n; do
    i=$((i+1)); printf '  %s%2s%s %s\n' "$GOLD" "$i" "$X" "$n"
  done <<EOF
$names
EOF
  say ""
  local pick; pick=$(ask "which one? (number, or enter to leave)" "")
  [ -n "$pick" ] || { echo; return 0; }
  n=$(printf '%s\n' "$names" | sed -n "${pick}p")
  [ -n "$n" ] || die "no such entry" "$SELF manage"

  head_ "$n"
  emercoin-cli name_show "$n" 2>&1 | sed 's/^/  /'
  say ""
  printf '  %su%s update the value   %sr%s renew the lease   %sd%s delete   %s[enter]%s leave  ' \
    "$B" "$X" "$B" "$X" "$B" "$X" "$B" "$X"
  read -r a </dev/tty 2>/dev/null || a=""
  case "$a" in
    u)  local v; v=$(ask "new value (or a @path to read from a file)" "")
        [ -n "$v" ] || die "nothing given" "$SELF manage"
        case "$v" in @*) v=$(cat "${v#@}") || die "can't read that file" "$SELF manage" ;; esac
        nvs_write "$n" "$v" "$(cdef LEASE 1826)" ;;
    r)  local d cur
        d=$(ask "renew for how many days" "$(cdef LEASE 1826)")
        cur=$(nvs_value "$n")
        [ -n "$cur" ] || die "couldn't read the current value; not going to guess it" "$SELF manage"
        nvs_write "$n" "$cur" "$d" ;;
    d)  say ""
        printf '  %sDeleting frees the name. Anyone can take it, including someone\n' "$R"
        printf '  who wants to be you. There is no undo.%s\n\n' "$X"
        local t; t=$(ask "type the name in full to delete it" "")
        if [ "$t" = "$n" ]; then
          if [ "$DRY" = 1 ]; then hm "dry run — not sending"; note "emercoin-cli name_delete \"$n\""
          else
            local out; out=$(emercoin-cli name_delete "$n" 2>&1)
            if printf '%s' "$out" | grep -qiE '^[0-9a-f]{64}$|"txid"'; then
              ok "deleted"; note "txid $(printf '%s' "$out" | tr -d '"' | grep -oE '[0-9a-f]{64}' | head -1)"
              logline "name_delete" "$n"
            else no "the node refused it"; note "$out"
               note "older nodes may not have name_delete; let the lease lapse instead"; fi
          fi
        else hm "names didn't match — nothing deleted"; fi ;;
    *)  : ;;
  esac
  echo
}

# ── emermagnet ──────────────────────────────────────────────
# magnet: is the NVS prefix for BitTorrent links. We pair each one with an
# IPFS CID: the swarm is fast while people care, the CID still resolves when
# the last seeder goes to bed. One record, two ways to fetch the same bytes,
# both verifiable without asking anyone.
magnet_build(){ # magnet_build <path> <trackers...> -> "infohash plen size pieces sha"
  local py; py=$(find_py) || return 1
  "$py" - "$@" <<'PYEOF'
import hashlib, os, sys, math
def benc(o):
    if isinstance(o, int):   return b"i%de" % o
    if isinstance(o, bytes): return b"%d:%s" % (len(o), o)
    if isinstance(o, str):   return benc(o.encode())
    if isinstance(o, list):  return b"l" + b"".join(benc(i) for i in o) + b"e"
    if isinstance(o, dict):
        return b"d" + b"".join(benc(k) + benc(v) for k, v in sorted(o.items())) + b"e"
    raise TypeError(type(o))
path = sys.argv[1]; trackers = [t for t in sys.argv[2:] if t]
files = []
if os.path.isdir(path):
    base = os.path.basename(path.rstrip("/"))
    for root, _, fs in os.walk(path):
        for f in sorted(fs):
            p = os.path.join(root, f)
            files.append((p, os.path.relpath(p, path).split(os.sep), os.path.getsize(p)))
else:
    base = os.path.basename(path); files = [(path, None, os.path.getsize(path))]
total = sum(f[2] for f in files)
# aim for roughly a thousand pieces, clamped to sane bounds
plen = 1 << max(14, min(22, int(math.log2(max(total, 1) / 1000 or 1)) + 1))
pieces = b""; buf = b""
for p, _, _ in files:
    with open(p, "rb") as fh:
        while True:
            c = fh.read(plen - len(buf))
            if not c: break
            buf += c
            if len(buf) == plen: pieces += hashlib.sha1(buf).digest(); buf = b""
if buf: pieces += hashlib.sha1(buf).digest()
info = {"name": base, "piece length": plen, "pieces": pieces}
if len(files) == 1 and files[0][1] is None: info["length"] = files[0][2]
else: info["files"] = [{"length": sz, "path": rel} for _, rel, sz in files]
ih = hashlib.sha1(benc(info)).hexdigest()
tor = {"info": info, "created by": "ness.sh"}
if trackers:
    tor["announce"] = trackers[0]; tor["announce-list"] = [[t] for t in trackers]
open(path.rstrip("/") + ".torrent", "wb").write(benc(tor))
sha = ""
if len(files) == 1:
    h = hashlib.sha256()
    with open(files[0][0], "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""): h.update(chunk)
    sha = h.hexdigest()
print(ih, plen, total, len(pieces) // 20, sha)
PYEOF
}
cmd_magnet(){
  banner
  local path="${1:-}"
  [ -n "$path" ] || die "Nothing to share." "$SELF magnet <file-or-directory>"
  [ -e "$path" ] || die "No such thing: $path" "$SELF magnet <file-or-directory>"

  local label tr
  label=$(printf '%s' "$(basename "${path%/}")" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9.-' '-' | sed 's/-*$//')
  conf_set MAGNET_LABEL "$label"
  review_step "the share" MAGNET_LABEL MAGNET_TRACKERS
  label=$(cdef MAGNET_LABEL "$label")
  tr=$(cdef MAGNET_TRACKERS "udp://tracker.opentrackr.org:1337/announce,udp://open.demonii.com:1337/announce")
  conf_set MAGNET_TRACKERS "$tr"

  head_ "hashing"
  note "$path"
  local out ih plen size np sha
  # shellcheck disable=SC2046
  out=$(magnet_build "$path" $(printf '%s' "$tr" | tr ',' ' ')) || die "couldn't hash that" "$SELF doctor"
  # shellcheck disable=SC2086
  set -- $out; ih="$1"; plen="$2"; size="$3"; np="$4"; sha="${5:-}"
  ok "infohash $ih"
  note "$np pieces of $((plen/1024)) KiB, $size bytes total"
  ok "${path%/}.torrent"

  head_ "and the same bytes on ipfs"
  local cid=""
  if command -v ipfs >/dev/null 2>&1; then
    cid=$(ipfs add -Qr --cid-version=1 "$path" 2>/dev/null)
    [ -n "$cid" ] && ok "$cid"
  fi
  if [ -z "$cid" ] && [ -f "$path" ]; then
    cid=$(ipfs_cid "$path" 2>/dev/null) && ok "$cid" && note "computed here; pin it somewhere or it only exists on this disk"
  fi
  [ -n "$cid" ] || hm "no CID — install ipfs, or keep single files under 256 KiB"

  # First line is a plain magnet URI so any client can take it as-is.
  local uri="magnet:?xt=urn:btih:$ih&dn=$label"
  local t; for t in $(printf '%s' "$tr" | tr ',' ' '); do uri="$uri&tr=$t"; done
  local value="$uri"
  [ -n "$cid" ] && value="$value
ipfs=$cid"
  [ -n "$sha" ] && value="$value
sha256=$sha"
  value="$value
size=$size"

  local vf="$KEYS/magnet-$label.nvs"
  printf '%s\n' "$value" > "$vf"; chmod 600 "$vf" 2>/dev/null
  # the source path, so `verify` can re-hash the bytes instead of re-reading
  # the note we wrote about them
  printf '%s\n' "$path" > "$KEYS/magnet-$label.src"; chmod 600 "$KEYS/magnet-$label.src" 2>/dev/null

  head_ "the record"
  printf '  %sname %s%s%s\n' "$D" "$GOLD" "magnet:$label" "$X"
  printf '%s\n' "$value" | sed "s/^/    $D/;s/\$/$X/"
  note "saved to $vf"
  say ""
  note "seed it:   transmission-cli ${path%/}.torrent    (or any client)"
  [ -n "$cid" ] && note "or fetch:  ipfs get $cid"

  nvs_write "magnet:$label" "$value" "$(cdef LEASE 1826)"
  trophy_scan
  echo
}

# ── ipfs ────────────────────────────────────────────────────
# The point of a CID is that you can check it yourself. This computes the
# CIDv1 (raw, sha2-256) of a file with no daemon and no trust — which is what
# `ipfs add --cid-version=1 --raw-leaves` produces for anything under 256 KiB.
ipfs_cid(){
  local f="$1" py; py=$(find_py) || return 1
  "$py" - "$f" <<'PYEOF'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
if len(data) > 262144:
    print("CHUNKED", file=sys.stderr); sys.exit(2)   # needs dag-pb, not raw
A = "abcdefghijklmnopqrstuvwxyz234567"
raw = b"\x01\x55\x12\x20" + hashlib.sha256(data).digest()
out = ""; bits = 0; val = 0
for c in raw:
    val = (val << 8) | c; bits += 8
    while bits >= 5:
        out += A[(val >> (bits - 5)) & 31]; bits -= 5
if bits: out += A[(val << (5 - bits)) & 31]
print("b" + out)
PYEOF
}
cmd_ipfs(){
  banner
  local sub="${1:-help}"
  case "$sub" in
    cid)
      [ -n "${2:-}" ] || die "No file given." "$SELF ipfs cid <file>"
      [ -f "$2" ] || die "No such file: $2" "$SELF ipfs cid <file>"
      head_ "cid"
      local c; c=$(ipfs_cid "$2") || die "file is over 256 KiB — that needs a real ipfs add" "ipfs add --cid-version=1 $2"
      printf '  %s%s%s\n' "$GOLD" "$c" "$X"
      note "computed here, no daemon, no network"
      note "same as: ipfs add --cid-version=1 --raw-leaves $(basename "$2")"
      echo ;;
    pin)
      command -v ipfs >/dev/null || {
        head_ "ipfs"; no "no ipfs here"
        note "https://docs.ipfs.tech/install/  — or use: $SELF ipfs cid <file>"; echo; return 1; }
      local dir="${2:-.}"
      head_ "pinning $dir"
      local cid; cid=$(ipfs add -Qr --cid-version=1 "$dir" 2>/dev/null) || die "ipfs add failed" "ipfs daemon"
      ok "$cid"
      conf_set IPFS_CID "$cid"; conf_set IPFS_SRC "$dir"
      logline "ipfs-pin" "$cid"
      say ""
      note "local:    http://127.0.0.1:8080/ipfs/$cid/"
      note "public:   https://dweb.link/ipfs/$cid/"
      say ""
      head_ "give it a name"
      local host; host=$(cdef NODE_URL node1.private.ness)
      host="${host#http://}"; host="${host#https://}"; host="${host%%/*}"
      cat <<EOF
; so the link survives a repin
_dnslink.$host.  IN TXT  "dnslink=/ipfs/$cid"
EOF
      say ""
      nvs_write "ness:dpo:$host" "{\"schema\":\"ness:worm:content:1\",\"cid\":\"$cid\"}" "$(cdef LEASE 1826)"
      trophy_scan
      echo ;;
    get)
      [ -n "${2:-}" ] || die "No CID given." "$SELF ipfs get <cid> [outfile]"
      local out="${3:-./$2.html}" gw
      gw="${IPFS_GATEWAY:-https://dweb.link}"
      head_ "fetching"
      note "$gw/ipfs/$2"
      curl -fL# -o "$out" "$gw/ipfs/$2" || die "fetch failed" "$SELF ipfs get $2"
      ok "$out"
      local got; got=$(ipfs_cid "$out" 2>/dev/null)
      if [ -n "$got" ] && [ "$got" = "$2" ]; then ok "hash checks out — the gateway told the truth"
      elif [ -n "$got" ]; then no "hash MISMATCH"; note "asked for $2"; note "got      $got"
      else hm "over 256 KiB; can't verify that one here"; fi
      echo ;;
    serve)
      command -v ipfs >/dev/null || die "No ipfs here." "$SELF ipfs pin"
      head_ "serving"
      note "ipfs daemon, then http://127.0.0.1:8080/ipfs/<cid>/"
      ipfs daemon ;;
    *)
      head_ "ipfs"
      say "  Put the UI on IPFS and it stops being a file on your laptop."
      say ""
      printf '  %s%s%s %spin%s [dir]     add it, print the CID, offer the record\n' "$C" "$DOT" "$X" "$B" "$X"
      printf '  %s%s%s %scid%s <file>    work out a CID with no daemon at all\n' "$C" "$DOT" "$X" "$B" "$X"
      printf '  %s%s%s %sget%s <cid>     fetch through a gateway, then verify the hash\n' "$C" "$DOT" "$X" "$B" "$X"
      printf '  %s%s%s %sserve%s         run the daemon\n' "$C" "$DOT" "$X" "$B" "$X"
      say ""
      note "the wheel UI has no webfonts and no external requests, on purpose:"
      note "it renders from a gateway, offline, without phoning anyone"
      echo ;;
  esac
}

# ── CONNECT ─────────────────────────────────────────────────
# One word. The Skywire VPN app has one button and so does this.
#
# The whole of the gate applies here and it matters more here than anywhere
# else in this script: a VPN that says "Connected" without measuring anything
# is the green badge over uncertainty, and it is the single most common lie
# in privacy software. This one earns the word.
#
#   the visor said so            -> reported
#   the exit address changed     -> verified
#
# Commands are the ones Skywire actually ships (skycoin/skywire):
#   skywire-cli vpn list | start <pk> | stop | status
#   skywire-cli visor pk | info
# Look where the source actually is before giving up. A built binary in the
# checkout is the normal state of a Go tree; refusing to see it and telling
# the operator "not installed" is a lie about their own machine.
find_sky(){ # find_sky <binary-name>
  local b="$1" p
  command -v "$b" >/dev/null 2>&1 && { command -v "$b"; return 0; }
  for p in "$GOPATH/bin/$b" "$SKY_GO/$b" "$SKY_GO/build/$b" \
           "$GOPATH/bin/$b.exe" "$SKY_GO/$b.exe" "$SKY_GO/build/$b.exe"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
SKY="${NESS_SKYWIRE_CLI:-$(find_sky skywire-cli 2>/dev/null || echo skywire-cli)}"
PROBE="${NESS_PROBE:-https://api.ipify.org}"

sky(){ command -v "$SKY" >/dev/null 2>&1; }
sky_pk(){ sky || return 1; "$SKY" visor pk 2>/dev/null | grep -oE '[0-9a-f]{66}' | head -1; }
sky_up(){ [ -n "$(sky_pk)" ]; }
sky_status(){ sky || return 1; "$SKY" vpn status 2>&1; }
# "vpn client is not running" contains the word "running". A naive match here
# manufactures a false connection, which is the one failure this whole design
# exists to prevent. Negation is checked FIRST and wins.
sky_is_up(){
  local st="$1"
  printf '%s' "$st" | grep -qiE 'not[[:space:]]+(running|connected)|[[:space:]]stopped|disabled|no[[:space:]]+vpn' && return 1
  printf '%s' "$st" | grep -qiE 'running|connected'
}
# A Skywire public key is 33 bytes — 66 hex characters. Pulling keys out by
# that shape rather than by column position means this keeps working when the
# table format changes, and never mistakes a heading for a key.
sky_servers(){ sky || return 1; "$SKY" vpn list 2>/dev/null | grep -oE '[0-9a-f]{66}' | sort -u; }

# The probe is itself a request that leaves this machine. That is disclosed
# rather than buried, and --no-probe turns it off — at the cost of never being
# able to say "verified", which is exactly the trade being made.
egress(){
  [ "${NO_PROBE:-0}" = 1 ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 8 "$PROBE" 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9a-fA-F:.]+$'
}

connect_pick(){ # choose a server once, remember it after — the APK's model
  local saved; saved=$(conf_get CONNECT_PK)
  if [ -n "$saved" ]; then printf '%s' "$saved"; return 0; fi
  local list n i k
  list=$(sky_servers)
  if [ -z "$list" ]; then
    no "the visor's service discovery returned no VPN servers" >&2
    note "$SKY vpn list   — run it yourself and pass one: $SELF connect <public-key>" >&2
    return 1
  fi
  n=$(printf '%s\n' "$list" | grep -c .)
  head_ "$n servers, from your visor's own discovery" >&2
  i=0
  while IFS= read -r k; do
    i=$((i+1)); printf '  %s%2s%s %s\n' "$GOLD" "$i" "$X" "$k" >&2
  done <<EOF
$list
EOF
  say "" >&2
  local pick; pick=$(ask "which one? (number)" "1")
  k=$(printf '%s\n' "$list" | sed -n "${pick}p")
  [ -n "$k" ] || { no "no such entry" >&2; return 1; }
  conf_set CONNECT_PK "$k"
  printf '%s' "$k"
}

cmd_connect(){
  banner
  local want="${1:-}" before after st pk

  head_ "connect"

  if ! sky; then
    obs connect "" absent "no $SKY on this machine"
    no "no skywire-cli found"
    note "looked in: PATH"
    note "           $GOPATH/bin"
    note "           $SKY_GO"
    note "           $SKY_GO/build"
    say ""
    note "get it and build it, into the path its import name says it belongs:"
    printf '    %s%s build skywire%s\n' "$B" "$SELF" "$X"
    note "or point at an existing one: NESS_SKYWIRE_CLI=/path/to/skywire-cli"
    echo; return 1
  fi
  pk=$(sky_pk)
  if [ -z "$pk" ]; then
    obs connect "" absent "$SKY is here but no visor answered"
    no "no visor answering"
    local vb
    if vb=$(find_sky skywire-visor); then
      note "the visor binary is here but not running:"
      printf '    %s%s%s\n' "$B" "$vb" "$X"
      note "or, if it is installed as a service: systemctl start skywire-visor"
    else
      note "no skywire-visor binary either — $SELF build skywire"
    fi
    note "what $SKY tried: $SKY visor pk"
    echo; return 1
  fi
  # His rule, kept: cryptographic material renders in full, always. Two keys
  # can share any prefix, so an elided key cannot be compared.
  ok "visor answering"
  printf '    %sthis machine is%s %s\n' "$D" "$X" "$pk"

  [ -n "$want" ] || want=$(connect_pick) || { echo; return 1; }

  printf '\n  %smeasuring where you come out, before%s\n' "$D" "$X"
  before=$(egress)
  if [ -n "$before" ]; then
    printf '    %s\n' "$before"
    note "that measurement is itself a request to $PROBE — --no-probe skips it"
  else
    hm "couldn't measure your exit address"
    note "without a before and an after, 'connected' can only ever be reported, not verified"
  fi

  head_ "starting"
  printf '  %s%s vpn start %s%s\n' "$B" "$SKY" "$want" "$X"
  if [ "$DRY" = 1 ]; then hm "dry run — not starting"; echo; return 0; fi
  local out
  if ! out=$("$SKY" vpn start "$want" 2>&1); then
    obs connect visor failed "vpn start refused: $(printf '%s' "$out" | head -1)"
    no "the visor refused"
    printf '    %s%s%s\n' "$D" "$(printf '%s' "$out" | head -3)" "$X"
    logline "connect-failed" "$want"
    echo; return 1
  fi
  logline "connect" "$want"

  printf '  %swaiting for the tunnel%s' "$D" "$X"
  local i
  for ((i=0;i<20;i++)); do
    st=$(sky_status)
    sky_is_up "$st" && break
    printf '.'; sleep 2
  done
  printf '\r%-40s\r' " "

  head_ "did it actually happen"
  st=$(sky_status)
  printf '  %svisor says%s %s\n' "$D" "$X" "$(printf '%s' "$st" | head -1)"

  after=$(egress)
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    obs connect wire verified "you came out at $before before and $after now — the exit moved, measured on the wire"
    conf_set CONNECT_LAST "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    say ""
    rule 46
    printf '  %s%s  CONNECTED%s\n' "$G" "$TICK" "$X"
    printf '  %syou were coming out at%s %s\n' "$D" "$X" "$before"
    printf '  %syou come out at%s        %s\n' "$D" "$X" "$after"
    printf '  %severy route through here runs over Skywire. No hop knows more than%s\n' "$D" "$X"
    printf '  %sthe one before it and the one after it.%s\n' "$D" "$X"
    rule 46
    [ -z "${NO_BELL:-}" ] && printf '\a'
  elif [ -n "$before" ] && [ -n "$after" ]; then
    obs connect wire failed "the exit address did not move: $before before, $after after"
    say ""
    no "the visor started something, but you come out at the same address"
    printf '    %sbefore %s%s\n' "$D" "$before" "$X"
    printf '    %safter  %s%s\n' "$D" "$after" "$X"
    note "that is not a connection. Do not treat it as one."
  else
    obs connect visor reported "the visor reports the client is up; nothing measured it"
    say ""
    hm "the visor reports it started"
    note "nothing here measured the exit, so this is reported — not verified"
    note "$SELF connect  with curl available, or without --no-probe, can say more"
  fi
  say ""
  note "off again: $SELF disconnect"
  echo
}

cmd_disconnect(){
  banner
  sky || die "no $SKY on this machine" "$SELF connect"
  head_ "disconnect"
  if [ "$DRY" = 1 ]; then hm "dry run"; note "$SKY vpn stop"; echo; return 0; fi
  local before after
  before=$(egress)
  "$SKY" vpn stop >/dev/null 2>&1
  sleep 2
  after=$(egress)
  ok "stopped"
  logline "disconnect" "${before:-} -> ${after:-}"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    printf '    %syou are back out at%s %s\n' "$D" "$X" "$after"
  elif [ -n "$after" ]; then
    hm "your exit address did not change when you disconnected"
    note "either it was never connected, or something else is carrying your traffic"
  fi
  echo
}

# ── the button, for people who want a button ────────────────
# A page cannot run skywire-cli, so this serves one that talks to a loopback
# endpoint which can. When the endpoint is not there, the page shows nothing
# at all rather than a plausible screenshot of being connected.
#
# The endpoint can start and stop a VPN, so it is not left open to any web page
# that happens to guess the port: it binds loopback only, requires a token
# generated by openssl for every request, and refuses cross-origin callers.
cmd_button(){
  banner
  sky || die "no $SKY here — the button would have nothing to press" "$SELF connect"
  local py; py=$(find_py) || die "No Python 3 found." "$SELF doctor"
  local tok port html
  tok=$(openssl rand -hex 16 2>/dev/null) || die "openssl is needed to mint a session token"
  port="${NESS_PORT:-8747}"
  html="$KEYS/connect.html"
  [ -f "$html" ] || die "connect.html is missing" "put it next to your keys at $html"

  head_ "the button"
  printf '  %sopen%s  %shttp://127.0.0.1:%s/?t=%s%s\n' "$D" "$X" "$B" "$port" "$tok" "$X"
  note "loopback only · token minted per run · ctrl-c to stop"
  say ""
  NESS_TOKEN="$tok" NESS_HTML="$html" NESS_SKY="$SKY" NESS_PROBE="$PROBE" \
  "$py" - "$port" <<'PYEOF'
import json, os, subprocess, sys, re, hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
TOK=os.environ["NESS_TOKEN"]; HTML=os.environ["NESS_HTML"]
SKY=os.environ["NESS_SKY"];   PROBE=os.environ.get("NESS_PROBE","")
HEX66=re.compile(r'[0-9a-f]{66}')
NEG=re.compile(r'not\s+(running|connected)|\bstopped\b|\bdisabled\b|no\s+vpn',re.I)
POS=re.compile(r'running|connected',re.I)
def is_up(s):
    # negation first: "vpn client is not running" contains "running"
    return bool(s) and not NEG.search(s) and bool(POS.search(s))
def run(*a):
    try: return subprocess.run([SKY,*a],capture_output=True,text=True,timeout=30).stdout
    except Exception as e: return ""
def egress():
    try:
        import urllib.request
        with urllib.request.urlopen(PROBE,timeout=8) as r:
            v=r.read().decode().strip()
        return v if re.fullmatch(r'[0-9a-fA-F:.]+',v) else None
    except Exception: return None
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _tok(self):
        q=self.path.split("?",1)[1] if "?" in self.path else ""
        t=dict(p.split("=",1) for p in q.split("&") if "=" in p).get("t","")
        t=t or self.headers.get("X-Ness-Token","")
        return hmac.compare_digest(t,TOK)
    def _origin_ok(self):
        o=self.headers.get("Origin")
        return o is None or o.startswith("http://127.0.0.1")
    def _send(self,code,body,ctype="application/json"):
        b=body.encode() if isinstance(body,str) else body
        self.send_response(code); self.send_header("Content-Type",ctype)
        self.send_header("Content-Length",str(len(b)))
        self.send_header("Cache-Control","no-store")
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=self.path.split("?",1)[0]
        if p=="/":
            if not self._tok(): return self._send(403,"bad token","text/plain")
            return self._send(200,open(HTML,"rb").read(),"text/html")
        if p=="/api/state":
            if not self._tok(): return self._send(403,'{"error":"bad token"}')
            pk=HEX66.findall(run("visor","pk"))
            st=run("vpn","status")
            srv=sorted(set(HEX66.findall(run("vpn","list"))))
            up=is_up(st)
            return self._send(200,json.dumps({
                "visor": pk[0] if pk else None,
                "status_raw": st.strip()[:400],
                "up": up, "servers": srv, "egress": egress(),
                "probe": PROBE}))
        return self._send(404,'{"error":"no"}')
    def do_POST(self):
        if not self._tok() or not self._origin_ok():
            return self._send(403,'{"error":"refused"}')
        p=self.path.split("?",1)[0]
        n=int(self.headers.get("Content-Length") or 0)
        body=json.loads(self.rfile.read(n) or "{}") if n else {}
        if p=="/api/connect":
            pk=body.get("pk","")
            if not HEX66.fullmatch(pk): return self._send(400,'{"error":"not a public key"}')
            before=egress()
            out=run("vpn","start",pk)
            return self._send(200,json.dumps({"before":before,"out":out[:400]}))
        if p=="/api/verify":
            st=run("vpn","status")
            return self._send(200,json.dumps({
                "up":is_up(st),
                "status_raw":st.strip()[:400],"egress":egress()}))
        if p=="/api/disconnect":
            run("vpn","stop")
            return self._send(200,json.dumps({"egress":egress()}))
        return self._send(404,'{"error":"no"}')
srv=HTTPServer(("127.0.0.1",int(sys.argv[1])),H)
try: srv.serve_forever()
except KeyboardInterrupt: pass
PYEOF
  echo
}

# ── EVIDENCE ────────────────────────────────────────────────
# A failed check that does not hand you the evidence is not an observation,
# it is an accusation. Everything below exists to answer the only question
# that matters after a mismatch: what exactly differs, and what do I type.

# Where the raw sides of a comparison are kept, so `fix` can show them without
# recomputing anything and without asking the node twice.
# Deliberately NOT under the temp dir: the repair command printed on screen
# refers to these files by path. If they vanish when the script exits, the
# command you copied is a command that cannot run.
ev_dir(){ mkdir -p "$KEYS/evidence" 2>/dev/null; chmod 700 "$KEYS/evidence" 2>/dev/null; printf '%s' "$KEYS/evidence"; }

# Compare two files and say something USEFUL about how they differ.
# WORM values are XML, so the answer is almost always "this attribute changed",
# not "byte 412 differs" — but it prints the byte offset too, because when the
# XML will not parse that is the only true thing left to say.
# The same comparison, reduced to the few lines that belong on the failure
# line itself. Nobody should have to run a second command to learn what broke.
worm_summary(){ # worm_summary <chain-file> <local-file>
  local py; py=$(find_py) || return 1
  "$py" - "$1" "$2" <<'PYEOF2'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
try:
    import xml.etree.ElementTree as ET
    def flat(r,p=""):
        d={}; t=p+"/"+r.tag
        for k,v in sorted(r.attrib.items()): d[t+"@"+k]=v
        if (r.text or "").strip(): d[t+"#text"]=r.text.strip()
        for c in r: d.update(flat(c,t))
        return d
    fa=flat(ET.fromstring(a.decode('utf-8','replace')))
    fb=flat(ET.fromstring(b.decode('utf-8','replace')))
    rows=[(k,fa.get(k),fb.get(k)) for k in sorted(set(fa)|set(fb)) if fa.get(k)!=fb.get(k)]
    if not rows:
        print("only the formatting differs (spacing, attribute order)"); sys.exit(0)
    names=" ".join(k for k,_,_ in rows).lower()
    if   any(w in names for w in ("key","pub","verify")): why="your keys were regenerated after this name was registered"
    elif any(w in names for w in ("user","name","owner","master")): why="the name or owner in the record changed"
    elif any(w in names for w in ("url","tariff","service","network")): why="the node's details changed after registration"
    else: why="the record's contents changed after registration"
    print("%d field(s) differ · %s" % (len(rows), why))
    for k,x,y in rows[:4]:
        print("   %s" % k.lstrip("/"))
        print("     on chain : %s" % (x if x is not None else "(absent)"))
        print("     your key : %s" % (y if y is not None else "(absent)"))
    if len(rows)>4: print("   … and %d more" % (len(rows)-4))
except Exception:
    n=min(len(a),len(b)); off=n
    for i in range(n):
        if a[i]!=b[i]: off=i; break
    print("not valid XML on at least one side · first difference at byte %d" % off)
    print("   on chain : %s" % a[max(0,off-20):off+40].decode('utf-8','replace'))
    print("   your key : %s" % b[max(0,off-20):off+40].decode('utf-8','replace'))
PYEOF2
}

worm_explain(){ # worm_explain <chain-file> <local-file>
  local py; py=$(find_py) || { hm "no python to compare with"; return 1; }
  "$py" - "$1" "$2" <<'PYEOF'
import sys, re
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
def show(x,n=90):
    s=x.decode('utf-8','replace')
    return (s[:n]+'…') if len(s)>n else s
print("  on chain   %d bytes" % len(a))
print("  your key   %d bytes" % len(b))
if a==b:
    print("\n  IDENTICAL. Nothing is wrong with these two."); sys.exit(0)
if a.strip()==b.strip():
    print("\n  SAME CONTENT, different surrounding whitespace.")
    print("  chain ends with %r, yours ends with %r" % (a[-3:], b[-3:]))
    print("  This is not a forgery and not a stale record. Nothing needs")
    print("  fixing on the chain — the comparison was too strict.")
    sys.exit(0)
# first differing byte, with a window either side
n=min(len(a),len(b)); off=n
for i in range(n):
    if a[i]!=b[i]: off=i; break
lo=max(0,off-40)
print("\n  first difference at byte %d" % off)
print("    chain … %s" % show(a[lo:off+50]))
print("    yours … %s" % show(b[lo:off+50]))
# the useful part: what CHANGED, field by field
try:
    import xml.etree.ElementTree as ET
    ra=ET.fromstring(a.decode('utf-8','replace'))
    rb=ET.fromstring(b.decode('utf-8','replace'))
    def flat(r,p=""):
        d={}
        tag=p+"/"+r.tag
        for k,v in sorted(r.attrib.items()): d[tag+"@"+k]=v
        if (r.text or "").strip(): d[tag+"#text"]=r.text.strip()
        for c in r: d.update(flat(c,tag))
        return d
    fa,fb=flat(ra),flat(rb)
    keys=sorted(set(fa)|set(fb))
    rows=[(k,fa.get(k),fb.get(k)) for k in keys if fa.get(k)!=fb.get(k)]
    if rows:
        print("\n  what actually changed:")
        for k,x,y in rows:
            print("    %s" % k)
            print("      chain : %s" % (x if x is not None else "(absent)"))
            print("      yours : %s" % (y if y is not None else "(absent)"))
        # name the likely cause rather than making the operator guess
        ch=" ".join(k for k,_,_ in rows)
        print("\n  most likely cause:")
        if any(w in ch.lower() for w in ("key","pub","verify")):
            print("    the PUBLIC KEY differs. The chain holds a record made by a")
            print("    different key than the one in your keys directory — you")
            print("    regenerated your keys after registering. The chain is not")
            print("    wrong; it is simply older than your key.")
        elif any(w in ch.lower() for w in ("user","name","owner","master")):
            print("    the NAME or OWNER differs. Usually a corrected typo: the")
            print("    record was registered under the old spelling.")
        elif any(w in ch.lower() for w in ("url","tariff","service","network")):
            print("    node DETAILS changed. You edited the node config and")
            print("    regenerated the key; the chain still has the old details.")
        else:
            print("    the record's contents were edited after registration.")
    else:
        print("\n  the XML parses the same both sides — the difference is in")
        print("  formatting only (attribute order, indentation, encoding).")
except Exception as e:
    print("\n  (not parseable as XML on at least one side: %s)" % e)
    print("  falling back to the byte difference above.")
PYEOF
}

# Levenshtein on names, so a corrected typo is spotted instead of guessed at.
close_names(){ # close_names <wanted>
  names_load || return 1
  [ -s "$NTMP/names.tsv" ] || return 1
  local py; py=$(find_py) || return 1
  cut -f1 "$NTMP/names.tsv" | "$py" -c '
import sys,difflib
want=sys.argv[1]
have=[l.strip() for l in sys.stdin if l.strip()]
if want in have: sys.exit(0)
# close matches, plus anything differing only by repeated characters
near=difflib.get_close_matches(want,have,n=5,cutoff=0.75)
for n in near: print(n)
' "$1"
}

# ── FIX ─────────────────────────────────────────────────────
# For every failed check: the evidence, the likely cause, and the exact
# command. Nothing here writes on its own — repairs go through the same
# nvs_write that reads the chain, prices it, and makes you type yes.
cmd_fix(){
  banner
  head_ "what is wrong, and what to do about it"
  observe_all

  local id bad=0
  for id in $OBS_ORDER; do
    [ "$(obs_chk "$id")" = failed ] || continue
    bad=$((bad+1))
    printf '\n'
    rule 60
    printf '  %s%s %s%s\n' "$R" "$CROSS" "$id" "$X"
    printf '  %s%s%s\n' "$D" "${OBS_DET[$id]}" "$X"
    rule 60
    case "$id" in
      identity) fix_worm users ;;
      noderec)  fix_worm node ;;
      dns)      fix_dns ;;
      ssl)      fix_ssl ;;
      backup)   fix_backup ;;
      magnet)   hm "the bytes moved or changed since you shared them"
                note "re-share to publish a record that matches what is on disk:"
                note "  $SELF magnet <path>" ;;
      ipfs)     hm "the pinned content no longer hashes to the recorded CID"
                note "  $SELF ipfs cid <file>    — see what it hashes to now"
                note "  $SELF ipfs pin <dir>     — pin and record the new one" ;;
      connect)  hm "the visor started a client but your exit address never moved"
                note "  $SELF connect --no-probe   — start it without the exit check"
                note "  skywire-cli vpn status     — what the visor thinks"
                note "  skywire-visor              — is the visor even running" ;;
      *)        hm "no guided repair for this one yet" ;;
    esac
  done

  if [ "$bad" = 0 ]; then
    ok "nothing failed its check"
    note "$SELF verify shows what was recomputed and what was only reported"
    echo; return 0
  fi
  echo
}

fix_worm(){ # fix_worm <users|node>
  local f="$1" n lv cv d
  d=$(ev_dir)
  n=$(pnt key.py nvs "$KEYS/$f.key.json" 2>/dev/null | tr -d '\r')
  pnt key.py worm "$KEYS/$f.key.json" 2>/dev/null > "$d/$f.local"
  [ -n "$n" ] || { no "PrivatenessTools would not tell me the name for $f.key.json"; return 1; }

  head_ "in plain words"
  printf '  %sYour keys on this computer say you are:%s\n' "$D" "$X"
  printf '    %s%s%s\n' "$GOLD" "$n" "$X"

  # The typo case: the key now makes a name the chain has never seen, while a
  # near-identical one sits in your wallet. Say so plainly.
  local near first
  near=$(close_names "$n")
  if [ -n "$near" ]; then
    first=$(printf '%s\n' "$near" | head -1)
    printf '\n  %sBut the name actually registered on the chain is:%s\n' "$D" "$X"
    printf '%s\n' "$near" | sed "s/^/    $Y/;s/\$/$X/"
    say ""
    printf '  %sThose are the same name with a typo. You fixed the spelling on this\n' "$D"
    printf '  computer after you had already registered the misspelled one.%s\n' "$X"
    say ""
    printf '  %sNothing is broken and nothing is lost. You just own the old spelling\n' "$D"
    printf '  and not the new one. Pick one:%s\n\n' "$X"

    printf '  %s A %s Keep the misspelled name.\n' "$GOLD" "$X"
    printf '      %sIt is registered and it is yours. Rebuild your keys under that\n' "$D"
    printf '      spelling, then publish the new record over the old one. Two steps,\n'
    printf '      and you end up owning one name that is correct in every place:%s\n' "$X"
    printf '        %s%s rekey %s%s\n\n' "$B" "$SELF" "$first" "$X"

    printf '  %s B %s Register the corrected name too.\n' "$GOLD" "$X"
    printf '      %sCosts one more name fee. You end up owning both, which is\n' "$D"
    printf '      usually what you want — nobody else can take the near-miss.%s\n' "$X"
    printf '        %s%s register%s\n\n' "$B" "$SELF" "$X"

    printf '  %s C %s Point the misspelled one at your new record.\n' "$GOLD" "$X"
    printf '      %sAnything already using the old name keeps working, and it\n' "$D"
    printf '      starts describing the key you hold now.%s\n' "$X"
    printf '        %semercoin-cli name_update "%s" "$(cat %s)" 1826%s\n\n' "$B" "$first" "$d/$f.local" "$X"

    printf '  %s D %s Do nothing.\n' "$GOLD" "$X"
    printf '      %sThe old name expires on its own eventually. Until then it still\n' "$D"
    printf '      works. This is a real option and it costs nothing.%s\n' "$X"
    say ""
    say ""
    if confirm "Do A now — rebuild your keys as $first so they match the chain?"; then
      cmd_rekey "$first"; return 0
    fi
    if confirm "Do C instead — point $first at the record your key makes?"; then
      nvs_write "$first" "$(cat "$d/$f.local")" "$(cdef LEASE 1826)" "$d/$f.local"
    else
      hm "nothing changed. A, B, C and D are all still open."
      note "the record your key makes is saved at $d/$f.local"
    fi
    return 0
  fi

  if ! emc_up; then
    hm "no node here, so nothing can be compared against the chain"
    note "run this where emercoind is, or start it: emercoind -daemon"
    return 1
  fi
  cv=$(nvs_value "$n")
  if [ -z "$cv" ]; then
    hm "the chain does not hold $n at all"
    note "so there is nothing to disagree with — it simply is not registered yet"
    note "  $SELF register"
    return 0
  fi
  printf '%s' "$cv" > "$d/$f.chain"

  head_ "what this means"
  printf '  %sThe chain has a record under this name, but it does not match what\n' "$D"
  printf '  your keys produce. Usually that means you made new keys after you\n'
  printf '  registered. The chain is not damaged — it is just older than you.%s\n' "$X"

  head_ "the details, if you want them"
  worm_explain "$d/$f.chain" "$d/$f.local"

  head_ "both sides in full, on disk"
  note "chain : $d/$f.chain"
  note "yours : $d/$f.local"
  note "diff  : diff -u $d/$f.chain $d/$f.local"

  head_ "the repair"
  say ""
  printf '  %sThis replaces what is on the chain with what your keys say today:%s\n' "$D" "$X"
  printf '  %semercoin-cli name_update "%s" "$(cat %s)" 1826%s\n' "$B" "$n" "$d/$f.local" "$X"
  say ""
  printf '  %sIt is safe. It costs one name fee. You can also leave it — the old\n' "$D"
  printf '  record keeps working, it just describes an older you.%s\n' "$X"
  say ""
  if confirm "Walk through that update now? (it still reads the chain and asks you to type yes)"; then
    nvs_write "$n" "$(cat "$d/$f.local")" "$(cdef LEASE 1826)" "$d/$f.local"
  fi
}

fix_dns(){
  local host want cv
  host=$(conf_get DNS_NAME); want="A=$(conf_get DNS_A)"
  local sd; sd=$(conf_get DNS_SD); [ -n "$sd" ] && want="$want|SD=$sd"
  cv=$(nvs_value "dns:$host")
  head_ "the evidence"
  printf '  %son chain%s  %s\n' "$D" "$X" "$cv"
  printf '  %syour conf%s %s\n' "$D" "$X" "$want"
  say ""
  printf '  %sOne of these two is out of date. If the chain is right, fix the config;\n' "$D"
  printf '  if the config is right, update the chain.%s\n' "$X"
  head_ "the repair"
  printf '  %skeep the chain, fix the config:%s\n' "$D" "$X"
  printf '    %s%s dns%s   %s(then edit DNS_A at the review step)%s\n' "$B" "$SELF" "$X" "$D" "$X"
  printf '  %skeep the config, update the chain:%s\n' "$D" "$X"
  printf '    %semercoin-cli name_update "dns:%s" "%s" 1826%s\n' "$B" "$host" "$want" "$X"
  say ""
  if confirm "Update the chain to match your config?"; then
    nvs_write "dns:$host" "$want" "$(cdef LEASE 1826)"
  fi
}

fix_ssl(){
  local name serial crt fp cv
  name=$(conf_get SSL_NAME); serial="${name#ssl:}"; crt="$KEYS/ssl/$serial.crt"
  fp=$(openssl x509 -in "$crt" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | cut -d' ' -f1)
  cv=$(nvs_value "$name")
  head_ "the evidence"
  printf '  %sthe chain names%s   %s\n' "$D" "$X" "$cv"
  printf '  %sthis cert hashes%s  sha256=%s\n' "$D" "$X" "$fp"
  note "$crt"
  say ""
  printf '  %sA browser presenting this certificate will not be recognised, because\n' "$Y"
  printf '  the chain vouches for a different one.%s\n' "$X"
  head_ "the repair"
  printf '  %smake the chain vouch for this certificate:%s\n' "$D" "$X"
  printf '    %semercoin-cli name_update "%s" "sha256=%s" 1826%s\n' "$B" "$name" "$fp" "$X"
  printf '  %sor issue a fresh one and register that:%s\n' "$D" "$X"
  printf '    %s%s ssl%s\n' "$B" "$SELF" "$X"
  say ""
  if confirm "Point the chain at this certificate?"; then
    nvs_write "$name" "sha256=$fp" "$(cdef LEASE 1826)"
  fi
}

fix_backup(){
  head_ "the repair"
  printf '  %sThe backup is older than the keys it is supposed to protect, so\n' "$D"
  printf '  restoring it would not give you back the key you are using.%s\n\n' "$X"
  printf '    %s%s backup%s   %s— makes a new one, and offers to encrypt it%s\n' "$B" "$SELF" "$X" "$D" "$X"
  say ""
  if confirm "Make one now?"; then cmd_backup; fi
}

# ── THE GATE ────────────────────────────────────────────────
# Taken from EmerEyes and brought into the terminal unchanged in spirit.
#
# An observation carries TWO axes and they must never be collapsed into one
# mark. SOURCE is where it came from. CHECK is what THIS MACHINE actually did.
#
#   SOURCE  chain  your node reported it
#           keys   a file on this disk
#           conf   you told this script
#
#   CHECK   verified  recomputed here, and it matched
#           failed    recomputed here, and it did NOT match
#           reported  something said so; nothing was recomputed
#           claimed   it is in our own config; nobody checked anything
#           absent    not observed
#
# "reported" and "claimed" are not passes. They are admissions. A green mark
# is earned by recomputation in this process and by nothing else.
declare -A OBS_SRC OBS_CHK OBS_DET OBS_MORE
OBS_ORDER=""
obs(){ # obs <id> <source> <check> <detail> [evidence]
  OBS_SRC[$1]="$2"; OBS_CHK[$1]="$3"; OBS_DET[$1]="$4"; OBS_MORE[$1]="${5:-}"
  case " $OBS_ORDER " in *" $1 "*) ;; *) OBS_ORDER="$OBS_ORDER $1" ;; esac
}
obs_chk(){ printf '%s' "${OBS_CHK[$1]:-absent}"; }
obs_src(){ printf '%s' "${OBS_SRC[$1]:-}"; }
mark(){ # the one place a check state becomes a symbol
  case "$1" in
    verified) printf '%s%s verified%s' "$G"    "$TICK"  "$X" ;;
    failed)   printf '%s%s FAILED%s'   "$R"    "$CROSS" "$X" ;;
    reported) printf '%s%s reported%s' "$Y"    "$DOT"   "$X" ;;
    claimed)  printf '%s%s claimed%s'  "$GOLD" "$DOT"   "$X" ;;
    *)        printf '%s  not observed%s' "$D" "$X" ;;
  esac
}
src_tag(){
  case "$1" in
    chain) printf '%s[chain]%s' "$C" "$X" ;;
    visor) printf '%s[visor]%s' "$Y" "$X" ;;
    wire)  printf '%s[wire ]%s' "$G" "$X" ;;
    keys)  printf '%s[keys ]%s' "$G" "$X" ;;
    conf)  printf '%s[conf ]%s' "$D" "$X" ;;
    *)     printf '%s[     ]%s' "$D" "$X" ;;
  esac
}
# A derived fact is only as checked as its least-checked input.
# Sound reasoning over a claim produces a claim.
chk_rank(){ case "$1" in failed) echo 0 ;; verified) echo 4 ;; reported) echo 3 ;; claimed) echo 2 ;; *) echo 1 ;; esac; }
weakest_chk(){
  local w="verified" wr=4 i r
  for i in "$@"; do
    r=$(chk_rank "$(obs_chk "$i")")
    if [ "$r" -lt "$wr" ]; then wr=$r; w="$(obs_chk "$i")"; fi
  done
  printf '%s' "$w"
}

# ── the checks: recomputation, or an honest admission ───────

# The strongest thing this script can do: regenerate the WORM document from
# your key and compare it to what the chain actually holds. Neither side alone
# says anything. Together they say the registration is yours and current.
check_worm(){ # check_worm <users|node> <obs-id>
  local f="$1" id="$2" n lv cv
  if [ ! -f "$KEYS/$f.key.json" ]; then
    obs "$id" "" absent "no $f.key.json on this disk"; return
  fi
  n=$(pnt key.py nvs  "$KEYS/$f.key.json" 2>/dev/null | tr -d '\r')
  lv=$(pnt key.py worm "$KEYS/$f.key.json" 2>/dev/null)
  if [ -z "$n" ] || [ -z "$lv" ]; then
    obs "$id" keys claimed "the key file is here but PrivatenessTools could not regenerate its record"; return
  fi
  if ! emc_up; then
    obs "$id" keys reported "$n — regenerated from your key; no node here to compare it against"; return
  fi
  cv=$(nvs_value "$n")
  if [ -z "$cv" ]; then
    # Not registered is not a failure. But a name ONE CHARACTER different
    # sitting in the same wallet is not silence either — that is a corrected
    # typo, and saying nothing about it is how someone loses a name.
    local near; near=$(close_names "$n" | head -1)
    if [ -n "$near" ]; then
      obs "$id" chain failed "your keys say $n — but this wallet holds $near instead" \
        "one of those two spellings is a typo. Nothing is lost: you own the
   registered one, you just do not own the one your keys now produce.
   what to do  : $SELF fix     (offers four ways out, including doing nothing)"
    else
      obs "$id" chain absent "$n — your key produces this record; the chain does not hold it yet"
    fi
    return
  fi
  # Keep both sides on disk so `fix` can show the evidence without asking
  # the node again or regenerating anything.
  local d; d=$(ev_dir)
  printf '%s' "$cv" > "$d/$f.chain"; printf '%s' "$lv" > "$d/$f.local"
  if [ "$cv" = "$lv" ]; then
    obs "$id" chain verified "$n — the chain's value was recomputed from your key here and matched byte for byte"
  elif [ "$(printf '%s' "$cv" | tr -d '[:space:]')" = "$(printf '%s' "$lv" | tr -d '[:space:]')" ]; then
    # Trailing newlines and indentation are not forgery. Calling this FAILED
    # was my bug, not the chain's: the comparison was stricter than the claim.
    obs "$id" chain verified "$n — matches the chain (differs only in surrounding whitespace)"
  else
    obs "$id" chain failed \
      "$n — the chain holds a different value than your key produces" \
      "$(worm_summary "$d/$f.chain" "$d/$f.local")
   full copies : $d/$f.chain
                 $d/$f.local
   what to do  : $SELF fix"
  fi
}

# The certificate your browser presents, hashed here, against the hash the
# chain names. This is the whole of EmerSSL in one comparison.
check_ssl(){
  local name serial crt fp cv
  name=$(conf_get SSL_NAME)
  if [ -z "$name" ]; then obs ssl "" absent "no certificate made yet"; return; fi
  serial="${name#ssl:}"; crt="$KEYS/ssl/$serial.crt"
  if [ ! -f "$crt" ]; then obs ssl conf claimed "$name is in the config but $crt is gone"; return; fi
  fp=$(openssl x509 -in "$crt" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | cut -d' ' -f1)
  [ -n "$fp" ] || fp=$(openssl x509 -in "$crt" -outform DER 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
  if [ -z "$fp" ]; then obs ssl keys claimed "$crt exists but openssl would not hash it"; return; fi
  if ! emc_up; then obs ssl keys reported "$name — certificate hashed here; no node to compare against"; return; fi
  cv=$(nvs_value "$name")
  if [ -z "$cv" ]; then obs ssl chain absent "$name — hashed here, not on the chain yet"; return; fi
  if [ "$cv" = "sha256=$fp" ]; then
    obs ssl chain verified "$name — the DER was hashed here and matched the chain's fingerprint exactly"
  else
    obs ssl chain failed "$name — the chain names a different fingerprint than this certificate hashes to"
  fi
}

# DNS has nothing local to recompute against except the record this script
# composed. Matching proves the chain holds what you last intended, and that
# is all it proves — the wording says so.
check_dns(){
  local host ip sd want cv
  host=$(conf_get DNS_NAME); ip=$(conf_get DNS_A); sd=$(conf_get DNS_SD)
  if [ -z "$host" ]; then obs dns "" absent "no domain set"; return; fi
  if [ -z "$ip" ]; then obs dns conf claimed "dns:$host named, but no address composed"; return; fi
  want="A=$ip"; [ -n "$sd" ] && want="$want|SD=$sd"
  if ! emc_up; then obs dns conf claimed "dns:$host = $want — composed here, never compared to a chain"; return; fi
  cv=$(nvs_value "dns:$host")
  if [ -z "$cv" ]; then obs dns chain absent "dns:$host — composed here, not on the chain"; return; fi
  if [ "$cv" = "$want" ]; then
    obs dns chain verified "dns:$host — the chain holds exactly the record this config composes"
  else
    obs dns chain failed "dns:$host — chain holds '$cv', this config composes '$want'"
  fi
}

# Re-hash the actual bytes, not the note we wrote about them. The .src sidecar
# exists so this comparison can be a recomputation rather than a memory.
check_magnet(){
  local vf label src stored ih_now out cv
  vf=$(ls -t "$KEYS"/magnet-*.nvs 2>/dev/null | head -1)
  if [ -z "$vf" ]; then obs magnet "" absent "nothing shared yet"; return; fi
  label=$(basename "$vf"); label="${label#magnet-}"; label="${label%.nvs}"
  stored=$(cat "$vf" 2>/dev/null)
  src="$KEYS/magnet-$label.src"
  if [ -f "$src" ] && [ -e "$(cat "$src")" ]; then
    out=$(magnet_build "$(cat "$src")" 2>/dev/null) || out=""
    ih_now=$(printf '%s' "$out" | awk '{print $1}')
    if [ -n "$ih_now" ] && printf '%s' "$stored" | grep -q "btih:$ih_now"; then
      obs magnet keys verified "magnet:$label — the source bytes were re-hashed here and still produce the same infohash"
    elif [ -n "$ih_now" ]; then
      obs magnet keys failed "magnet:$label — the source bytes now hash to a different infohash than the record claims"
      return
    fi
  else
    obs magnet keys reported "magnet:$label — record on disk; the source bytes are gone, so nothing was re-hashed"
  fi
  emc_up || return
  cv=$(nvs_value "magnet:$label")
  if [ -n "$cv" ]; then
    if [ "$cv" = "$stored" ]; then
      obs magnet chain verified "magnet:$label — re-hashed here and the chain holds the same record"
    else
      obs magnet chain failed "magnet:$label — the chain holds a different record than the one on this disk"
    fi
  fi
}

# A CID is the one identifier you can always recompute yourself. Under 256 KiB
# this script does it with no daemon and no network at all.
check_ipfs(){
  local cid src got
  cid=$(conf_get IPFS_CID)
  if [ -z "$cid" ]; then obs ipfs "" absent "nothing pinned yet"; return; fi
  src=$(conf_get IPFS_SRC)
  if [ -n "$src" ] && [ -f "$src" ]; then
    got=$(ipfs_cid "$src" 2>/dev/null)
    if [ -n "$got" ] && [ "$got" = "$cid" ]; then
      obs ipfs keys verified "$cid — recomputed from $src here, no daemon, no network"; return
    elif [ -n "$got" ]; then
      obs ipfs keys failed "$cid — $src now computes to $got"; return
    fi
  fi
  obs ipfs conf claimed "$cid — this script wrote that string down; nothing here recomputed it"
}

# A backup is only a backup if it contains the keys you are using now and is
# newer than they are. Both of those are checkable without opening it.
check_backup(){
  local bf list ku kn tb
  bf=$(backup_newest)
  if [ -z "$bf" ]; then obs backup "" absent "no backup on this machine"; return; fi
  if backup_encrypted; then
    obs backup keys claimed "$(basename "$bf") — encrypted, and this script will not decrypt it to look inside"
    return
  fi
  list=$(tar tzf "$bf" 2>/dev/null) || { obs backup keys failed "$(basename "$bf") — tar cannot read it"; return; }
  if ! printf '%s' "$list" | grep -q 'users\.key\.json'; then
    obs backup keys failed "$(basename "$bf") — does not contain users.key.json"; return
  fi
  tb=$(date -r "$bf" +%s 2>/dev/null || stat -c %Y "$bf" 2>/dev/null)
  ku=$(date -r "$KEYS/users.key.json" +%s 2>/dev/null || stat -c %Y "$KEYS/users.key.json" 2>/dev/null)
  kn=$(date -r "$KEYS/node.key.json"  +%s 2>/dev/null || stat -c %Y "$KEYS/node.key.json"  2>/dev/null)
  if [ -n "$tb" ] && [ -n "$ku" ] && [ "$tb" -lt "$ku" ]; then
    obs backup keys failed "$(basename "$bf") — older than users.key.json; it does not cover the key you are using"
  elif [ -n "$tb" ] && [ -n "$kn" ] && [ "$tb" -lt "$kn" ]; then
    obs backup keys failed "$(basename "$bf") — older than node.key.json; it does not cover the key you are using"
  else
    obs backup keys verified "$(basename "$bf") — listed here, holds your keys, and is newer than both"
  fi
}

# The two Go trees are observations too: present, at what commit, built or not.
git_head(){ [ -d "$1/.git" ] || return 1; ( cd "$1" && git rev-parse --short HEAD 2>/dev/null ); }
check_trees(){
  local h b
  if [ -d "$SKY_GO" ]; then
    h=$(git_head "$SKY_GO") || h=""
    if b=$(find_sky skywire-cli); then
      obs skywire keys verified "$SKY_GO${h:+ @ $h} · skywire-cli at $b"
    else
      obs skywire keys reported "$SKY_GO${h:+ @ $h} · source is there, no built skywire-cli found · $SELF build"
    fi
  else
    obs skywire "" absent "$SKY_GO does not exist · $SELF build clones it"
  fi
  if [ -d "$NESS_GO" ]; then
    h=$(git_head "$NESS_GO") || h=""
    obs nessgo keys verified "$NESS_GO${h:+ @ $h}"
  else
    obs nessgo "" absent "$NESS_GO does not exist · $SELF build clones it"
  fi
}

check_watch(){
  if [ ! -f "$WL" ]; then obs watch "" absent "no watchlist"; return; fi
  local n
  n=$(wl_py names 2>/dev/null | grep -c . )
  if [ "${n:-0}" -gt 0 ]; then obs watch keys verified "$n name(s) watched — read from $WL here"
  else obs watch keys reported "watchlist exists but is empty"; fi
}
check_conf(){
  local u nu
  u=$(conf_get NESS_USER); nu=$(conf_get NODE_URL)
  [ -n "$u" ]  && obs whoami   conf claimed "you told this script your name is '$u' — the key file is the only thing that settles it" \
               || obs whoami   "" absent "no name set"
  [ -n "$nu" ] && obs nodeurl  conf claimed "NODE_URL '$nu' — a line in your config, not a reachable fact" \
               || obs nodeurl  "" absent "no node URL set"
  have_src && obs tools keys verified "PrivatenessTools + venv present at $SRC" \
           || obs tools "" absent "PrivatenessTools not installed"
  have_user && obs userkey keys verified "users.key.json read from $KEYS" \
            || obs userkey "" absent "no users.key.json"
  have_node && obs nodekey keys verified "node.key.json read from $KEYS" \
            || obs nodekey "" absent "no node.key.json"
  if emc_up; then obs chain chain reported "your node answered: block $(emercoin-cli getblockcount 2>/dev/null), balance $(emc_balance) EMC"
  elif emc_cli; then obs chain conf claimed "emercoin-cli is here but the node did not answer"
  else obs chain "" absent "no emercoin-cli on this machine"; fi
}

observe_all(){
  OBS_ORDER=""
  check_conf
  check_worm users identity
  check_worm node  noderec
  check_ssl
  check_dns
  check_magnet
  check_ipfs
  check_backup
  check_watch
  check_trees
  check_connect
}
# Connect is observed like everything else: the visor's word and the wire's
# measurement are different facts and never share a mark.
check_connect(){
  if ! sky; then obs connect "" absent "no $SKY on this machine"; return; fi
  local pk st
  pk=$(sky_pk)
  if [ -z "$pk" ]; then obs connect conf claimed "$SKY is installed; no visor answered"; return; fi
  st=$(sky_status)
  if sky_is_up "$st"; then
    obs connect visor reported "visor $pk reports the vpn client is up — nothing here measured the exit"
  else
    obs connect visor reported "visor $pk is answering; the vpn client is not running"
  fi
}

# ── INDEPENDENT DERIVATION ──────────────────────────────────
# Facts that appear in no single observation. Each names its inputs and
# inherits the weakest check among them.
derive_all(){ # prints one block per rule that has its inputs
  local w

  if [ "$(obs_chk identity)" != absent ] && [ "$(obs_chk noderec)" != absent ]; then
    w=$(weakest_chk identity noderec)
    if [ "$(obs_chk identity)" = verified ] && [ "$(obs_chk noderec)" = verified ]; then
      der "D1" "the chain is current with your keys" "$w" "identity + noderec" \
        "both records on chain were regenerated from the keys in $KEYS and matched. Not 'a name exists' — the name holds what this machine can still produce."
    else
      der "D1" "the chain is current with your keys" "$w" "identity + noderec" \
        "cannot be concluded: one side was not recomputed here."
    fi
  fi

  # Does the node record actually name you? Read out of the document itself.
  if have_node && have_user; then
    local u nv
    u=$(conf_get NESS_USER)
    nv=$(pnt key.py worm "$KEYS/node.key.json" 2>/dev/null)
    if [ -n "$u" ] && [ -n "$nv" ]; then
      if printf '%s' "$nv" | grep -q -- "$u"; then
        der "D2" "the node key names you" "$(weakest_chk userkey nodekey)" "userkey + nodekey" \
          "the node's own WORM document contains the master-user '$u'. Membership read out of the record, not taken from the config line that claims it."
      else
        der "D2" "the node key names you" "failed" "userkey + nodekey" \
          "the node's WORM document does not contain '$u'. The config and the key disagree about who owns this node."
      fi
    fi
  fi

  if [ "$(obs_chk ssl)" != absent ]; then
    der "D3" "the certificate the chain names is the one on this disk" "$(obs_chk ssl)" "ssl" \
      "$(printf '%s' "${OBS_DET[ssl]}")"
  fi

  if [ "$(obs_chk backup)" != absent ] && [ "$(obs_chk userkey)" != absent ]; then
    w=$(weakest_chk backup userkey nodekey)
    der "D4" "your backup covers the keys you are using now" "$w" "backup + userkey + nodekey" \
      "a backup that predates a key is not a backup of it. This compares timestamps and contents, not filenames."
  fi
}
der(){ # der <id> <name> <check> <inputs> <detail>
  printf '\n  %s◈ %s%s  ' "$GOLD" "$2" "$X"
  mark "$3"; printf '\n'
  printf '    %sfrom: %s%s\n' "$D" "$4" "$X"
  printf '    %s%s%s\n' "$D" "$5" "$X"
}

# ── verify: the whole gate, printed ─────────────────────────
cmd_verify(){
  banner
  head_ "what this machine actually checked"
  note "source is where it came from. check is what was recomputed here."
  note "a green mark is earned by recomputation in this process and nothing else."
  say ""
  observe_all

  local id v r n=0 ok=0 bad=0
  for id in $OBS_ORDER; do
    [ "$(obs_chk "$id")" = absent ] && continue
    n=$((n+1))
    v=$(obs_chk "$id")
    [ "$v" = verified ] && ok=$((ok+1))
    [ "$v" = failed ] && bad=$((bad+1))
    printf '  %s %s%-9s%s ' "$(src_tag "$(obs_src "$id")")" "$B" "$id" "$X"
    mark "$v"; printf '\n'
    printf '    %s%s%s\n' "$D" "${OBS_DET[$id]}" "$X"
    # A failure prints its evidence here, unprompted. Being told something is
    # wrong without being told what is not a report, it is an accusation.
    if [ -n "${OBS_MORE[$id]:-}" ]; then
      printf '%s\n' "${OBS_MORE[$id]}" | sed "s/^/    $D/;s/\$/$X/"
    fi
  done
  if [ "$n" = 0 ]; then hm "nothing observed yet"; note "$SELF"; echo; return 0; fi

  local miss=0
  for id in $OBS_ORDER; do [ "$(obs_chk "$id")" = absent ] && miss=$((miss+1)); done
  if [ "$miss" -gt 0 ]; then
    head_ "not on this machine yet"
    note "absent is not a failure. It is a thing that has not happened."
    for id in $OBS_ORDER; do
      [ "$(obs_chk "$id")" = absent ] || continue
      printf '  %s        %s%-9s%s %s%s%s\n' "$(src_tag "")" "$D" "$id" "$X" "$D" "${OBS_DET[$id]}" "$X"
    done
  fi

  head_ "independently derived"
  note "facts present in no single observation above"
  derive_all

  local firstfail=""
  for id in $OBS_ORDER; do
    [ "$(obs_chk "$id")" = failed ] && { firstfail="${OBS_DET[$id]}"; break; }
  done
  verify_stamp "$n" "$ok" "$bad" "$firstfail"
  say ""
  rule 46
  printf '  %s%s of %s observations were recomputed here.%s\n' "$B" "$ok" "$n" "$X"
  if [ "$bad" -gt 0 ]; then
    printf '  %s%s check(s) RAN AND FAILED. That is not a warning, it is a mismatch.%s\n' "$R" "$bad" "$X"
    printf '  %s%s fix%s  %s— the evidence, the likely cause, and the command to type%s\n' "$B" "$SELF" "$X" "$D" "$X"
  fi
  local un=$((n-ok-bad))
  [ "$un" -gt 0 ] && printf '  %s%s were reported or claimed and never checked — shown as such, not as verified.%s\n' "$D" "$un" "$X"
  rule 46
  echo
}

# ── self test ───────────────────────────────────────────────
# Run this on a machine you don't trust yet — especially Windows.
# The house rule, enforced against the file you are actually running.
# Strips comments first: prose about the rule is not a breach of it.
fab_hits(){
  grep -nE '\$\{?RANDOM|Math\.random' "$0" \
    | grep -v 'FABCHECK' \
    | awk -F: '{ line=$0; sub(/^[0-9]+:/, "", line); if (line !~ /^[[:space:]]*#/) print }'
}

cmd_selftest_quiet(){ cmd_selftest >/dev/null 2>&1; }
cmd_selftest(){
  banner; head_ "self test"
  local fail=0 t
  [ "$WIN" = 1 ] && ok "Git Bash on Windows detected" || ok "$(uname -s)"

  for t in bash git curl tar sed awk grep mktemp date; do
    command -v "$t" >/dev/null && ok "$t" || { no "$t missing"; fail=1; }
  done
  case "$BASH_VERSION" in ''|3.0*|2.*) no "bash $BASH_VERSION is too old"; fail=1 ;;
    *) ok "bash $BASH_VERSION" ;; esac

  local py; if py=$(find_py); then ok "python $("$py" -V 2>&1 | tr -d '\r')"
  else no "no python 3"; fail=1; py=""; fi

  # A path with a space is the classic Windows tripwire.
  local d="${TMPDIR:-/tmp}/ness self test $$"
  if mkdir -p "$d" 2>/dev/null && printf 'x' > "$d/a b.txt" 2>/dev/null && [ -f "$d/a b.txt" ]; then
    ok "paths with spaces"
  else no "cannot handle a path with a space"; fail=1; fi
  if [ -n "$py" ] && "$py" -c "import sys,os; sys.exit(0 if os.path.isfile(sys.argv[1]) else 1)" "$d/a b.txt" 2>/dev/null; then
    ok "python sees the same file bash does"
  else no "python and bash disagree about paths"; fail=1; fi
  rm -rf "$d" 2>/dev/null

  # CRLF in this very file is the other one.
  if grep -q $'\r' "$0" 2>/dev/null; then
    no "this script has CRLF line endings"
    note "fix: sed -i 's/\r\$//' $0"; fail=1
  else ok "LF line endings"; fi

  # HOUSE RULE, checked against the file you are actually running.
  head_ "no fabricated values"
  # Comments may discuss the rule; code may not break it. FABCHECK marks the
  # two lines of this test itself, which necessarily contain the pattern.
  local hits
  hits=$(fab_hits)                                                    # FABCHECK
  if [ -z "$hits" ]; then
    ok "no fake randomness anywhere in this script"
    note "the only randomness here comes from openssl rand and os.urandom"
  else
    no "$(printf '%s\n' "$hits" | wc -l | tr -d ' ') line(s) reach for a fake random"
    printf '%s\n' "$hits" | sed "s/^/      $D/;s/\$/$X/"
    fail=1
  fi
  if command -v openssl >/dev/null 2>&1; then ok "openssl rand available for the one place we need entropy"
  else hm "no openssl — $SELF ssl won't run"; fi

  head_ "the rest"
  [ -w "$HOME" ] && ok "\$HOME is writable  ($HOME)" || { no "\$HOME not writable"; fail=1; }
  have_src && ok "PrivatenessTools installed" || hm "not installed yet — run: $SELF"
  if have_src; then
    sync_keys_dir
    local told; told=$(pnt key.py 2>/dev/null | sed -n 's/^Keys directory: *//p' | tail -1 | tr -d '\r')
    [ -n "$told" ] && note "the tool keeps its keys in: $told"
    note "this script is using:            $KEYS"
  fi
  if doom_game >/dev/null 2>&1; then ok "doom: $(doom_game)"; else hm "no doom yet — run: $SELF doom setup"; fi
  command -v dig >/dev/null && ok "dig" || { command -v nslookup >/dev/null && ok "nslookup (no dig — fine)" || hm "no DNS tool"; }

  echo
  if [ "$fail" = 0 ]; then printf '  %severything needed is here.%s\n\n' "$G" "$X"
  else printf '  %ssomething above needs fixing first.%s\n\n' "$R" "$X"; return 1; fi
}

# ── dispatch ────────────────────────────────────────────────
ARGS=()
for a in "$@"; do
  case "$a" in
    -y|--yes)     YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    --raw)        RAW=1 ;;
    --no-probe)   NO_PROBE=1 ;;
    --all)        NAME_LIMIT=1000000 ;;
    *)            ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

trap 'rm -rf "${NTMP:-/nonexistent}"' EXIT INT TERM
sync_keys_dir
[ "$DRY" = 1 ] && printf '\n  %sdry run — every command will be printed, nothing will be sent.%s\n' "$GOLD" "$X"

case "${1:-}" in
  ""|go|start)     cmd_go ;;
  status|st)       shift; cmd_status "$@" ;;
  names|ls)        shift; cmd_names "$@" ;;
  build|src)       shift; cmd_build "$@" ;;
  connect|c)       shift; cmd_connect "$@" ;;
  disconnect|d)    shift; cmd_disconnect "$@" ;;
  button|ui)       shift; cmd_button "$@" ;;
  verify|check)    shift; cmd_verify "$@" ;;
  fix|repair)      shift; cmd_fix "$@" ;;
  menu)            shift; cmd_menu "$@" ;;
  door)            shift; cmd_door "$@" ;;
  menu-plain)      shift; menu_plain "$@" ;;
  doctor|doc)      shift; cmd_doctor "$@" ;;
  selftest|test)   shift; cmd_selftest "$@" ;;
  setup|install)   shift; banner; head_ "getting the tools"; cmd_setup "$@" ;;
  user)            shift; banner; cmd_user "$@" ;;
  node)            shift; banner; cmd_node "$@" ;;
  rekey|rename)    shift; cmd_rekey "$@" ;;
  records|rec)     shift; banner; head_ "your records"; cmd_records "$@"; echo ;;
  register)        shift; cmd_register "$@" ;;
  watch|wl)        shift; cmd_watch "$@" ;;
  backup)          shift; cmd_backup "$@" ;;
  trophies|tr)     shift; cmd_trophies "$@" ;;
  why)             shift; cmd_why "$@" ;;
  doom)            shift; cmd_doom "$@" ;;
  emc|coins)       shift; cmd_emc "$@" ;;
  ipfs)            shift; cmd_ipfs "$@" ;;
  ssl|emerssl)     shift; cmd_ssl "$@" ;;
  dns|emerdns)     shift; cmd_dns "$@" ;;
  manage)          shift; cmd_manage "$@" ;;
  magnet|torrent)  shift; cmd_magnet "$@" ;;
  help|-h|--help)  cmd_help ;;
  --version|-V)    say "ness $VERSION" ;;
  *)               die "No such command: $1" "$SELF help" ;;
esac
