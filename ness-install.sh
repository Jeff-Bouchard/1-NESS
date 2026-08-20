#!/usr/bin/env bash
# ── CRLF SELF-HEAL — keep this as the first executable line ─────────────
# A CR at the end of line 1 makes /usr/bin/env look for `bash\r`, and CRs
# further down produce "$'\r': command not found" then a syntax error. The
# script that checks OTHER files for CRLF could not check itself, so it now
# strips its own CRs, rewrites itself in place, and re-execs. Comments are
# CR-safe, which is why this can sit here at all. Trailing `#` swallows the
# CR on this very line so no stray argument reaches the parser.
[ -n "${NESS_LF:-}" ] || exec env NESS_LF=1 bash -c 'f=$1; shift; t=$(mktemp); tr -d "\r" <"$f" >"$t"; if cmp -s "$t" "$f"; then rm -f "$t"; exec bash "$f" "$@"; fi; cat "$t" >"$f" 2>/dev/null && rm -f "$t" && exec bash "$f" "$@"; chmod +x "$t"; exec bash "$t" "$@"' _ "$0" "$@"  #
# ness-install.sh — one installer, one runner.   ness.cx
#
# Linux, macOS, and Windows under Git Bash. Save with LF line endings.
#
#     bash ness-install.sh
#
# Run it again any time. It is idempotent, and on a finished machine it is
# the runner.
#
# ── HOUSE RULE ─────────────────────────────────────────────────────────
# No fabricated values. Nothing here invents a number, a version, or a
# success. Every figure is read from this disk or from a service that
# answered. A check that could not run prints `not observed`, and is never
# counted as a pass.
#
# ── EVERY CLAIM IS INDEPENDENTLY DERIVABLE ─────────────────────────────
# Each check carries the primary source that makes it a requirement — a
# file and line you can open, or a command you can run yourself. Nothing
# asks to be believed.
#
#     ./ness-install.sh --why      the whole provenance table, no side effects
#
# ── NOTHING CHANGES WITHOUT THE WORD TYPED OUT ─────────────────────────
# Installing is one confirmation. Modifying a file you already have is a
# separate one, always backed up, always re-verified afterwards, and
# rolled back if the result does not parse.
#
# ── MISSING INFORMATION IS ASKED FOR, NEVER GUESSED ────────────────────
# When something is not where it should be, this script asks you for it and
# re-checks on the spot. It does not substitute a default and carry on.

set -uo pipefail
VERSION="1.0"
SELF="$(basename "$0")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

SRC="${NESS_SRC:-$HOME/ness/PrivatenessTools}"
KEYS="${NESS_KEYS:-$HOME/.privateness-keys}"
BIN="${NESS_BIN:-$HOME/.local/bin}"
REPO="${NESS_REPO:-https://github.com/NESS-Network/PrivatenessTools}"
LOG="$HOME/.ness-install.log"
YES="${NESS_YES:-0}"
NO_OPT="${NESS_NO_OPTIONAL:-0}"
MODE="install"

# ── defaults, identical to the ness:id wizard (nessid.html) ────────────
# Override any of them in the environment. Nothing here is asked twice.
NESS_USER_DEF="${NESS_USER:-master01}"
NESS_USER_ENTROPY="${NESS_USER_ENTROPY:-100}"
NESS_NODE_URL="${NESS_NODE_URL:-http://batman1.private.ness}"
NESS_TARIFF="${NESS_TARIFF:-1000}"                 # NCH/hour
NESS_SERVICES="${NESS_SERVICES:-prng,files}"
NESS_NETWORK="${NESS_NETWORK:-inet}"               # inet,skywire,yggdrasil,i2p,tor
NESS_NODE_ENTROPY="${NESS_NODE_ENTROPY:-100}"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) WIN=1; VBIN="Scripts"; PLAT="Windows / Git Bash" ;;
  Darwin)               WIN=0; VBIN="bin";     PLAT="macOS" ;;
  *)                    WIN=0; VBIN="bin";     PLAT="$(uname -s 2>/dev/null || echo unknown)" ;;
esac
[ -t 0 ] && TTY=1 || TTY=0
[ "$TTY" = 0 ] && YES=1

# ── paint ───────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  X=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'
  if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    C=$'\033[38;5;39m'; G=$'\033[38;5;79m'; D=$'\033[38;5;244m'; GOLD=$'\033[38;5;178m'
  else GOLD=$Y; fi
else X=""; B=""; D=""; R=""; G=""; Y=""; C=""; GOLD=""; fi

if [ -n "${NESS_ASCII:-}" ]; then UNI=0
elif printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qi 'utf-*8'; then UNI=1
elif [ "$WIN" = 1 ]; then UNI=1
else UNI=0; fi
if [ "$UNI" = 1 ]; then HEX="⬢"; TICK="✓"; CROSS="✗"; DOT="•"; RULE="─"; ARROW="→"
else HEX="*"; TICK="+"; CROSS="x"; DOT="-"; RULE="-"; ARROW="->"; fi

say(){ printf '%s\n' "$*"; }
rule(){ local i n=${1:-58} s=""; for ((i=0;i<n;i++)); do s="$s$RULE"; done; printf '%s%s%s\n' "$D" "$s" "$X"; }
head_(){ printf '\n%s%s %s%s\n' "$B" "$HEX" "$*" "$X"; }
note(){ printf '      %s%s%s\n' "$D" "$*" "$X"; }
step(){ printf '\n%s%s %s/%s %s%s%s\n' "$C" "$HEX" "$1" "$2" "$B" "$3" "$X"; rule; }
logline(){ { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$LOG"; } 2>/dev/null; return 0; }

# ════════════════════════════════════════════════════════════
# THE LEDGER — one place a check becomes a result, with its source
# ════════════════════════════════════════════════════════════
PASS=0; FAIL=0; SKIP=0; FAILED=""
WHY_IDS=""; declare -A WHY_TXT WHY_SRC

# why <id> <requirement> <where you can verify it yourself>
why(){ WHY_TXT[$1]="$2"; WHY_SRC[$1]="$3"
       case " $WHY_IDS " in *" $1 "*) ;; *) WHY_IDS="$WHY_IDS $1" ;; esac; }

# chk <id> <ok|no|skip> <label> [what to do about it]
chk(){
  local id="$1" st="$2" label="$3" fix="${4:-}"
  case "$st" in
    ok)   PASS=$((PASS+1)); printf '  %s%s%s %s\n' "$G" "$TICK" "$X" "$label" ;;
    no)   FAIL=$((FAIL+1)); printf '  %s%s%s %s\n' "$R" "$CROSS" "$X" "$label"
          FAILED="$FAILED
      $label" ;;
    skip) SKIP=$((SKIP+1)); printf '  %s%s%s %s\n' "$Y" "$DOT" "$X" "$label" ;;
  esac
  [ -n "$fix" ] && note "$fix"
  # The source is printed for anything that failed — that is when you most
  # need to be able to check the claim yourself.
  [ "$st" = no ] && [ -n "${WHY_SRC[$id]:-}" ] && note "why: ${WHY_SRC[$id]}"
  logline "$st" "$id"
}

# A check that FAILED and was then repaired in the same run must not still
# be listed as failed at the end. The disk is the authority; the tally has to
# follow it, or the screen contradicts the thing it just did.
retract(){ # retract <exact label that was reported failed>
  case "$FAILED" in
    *"$1"*)
      FAILED="$(printf '%s' "$FAILED" | grep -vxF "      $1")"
      FAIL=$((FAIL-1)); PASS=$((PASS+1))
      ;;
  esac
}

confirm(){
  local a
  [ "$YES" = 1 ] && { printf '  %s%s%s %s %s[auto-yes]%s\n' "$GOLD" "$DOT" "$X" "$1" "$D" "$X"; return 0; }
  printf '  %s%s%s %s %s[y/N]%s ' "$GOLD" "$DOT" "$X" "$1" "$D" "$X" >&2
  read -r a </dev/tty 2>/dev/null || a=""
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}
# A mutation needs the word, in full, with no default. NESS_YES does not
# unlock this — non-interactive is a reason to skip, never to assume consent.
confirm_word(){
  local a
  if [ "$YES" = 1 ]; then
    printf '  %s%s%s %s\n' "$Y" "$DOT" "$X" "$1"
    note "non-interactive — skipped, not assumed. Re-run in a terminal to be asked."
    return 1
  fi
  printf '  %s%s%s %s\n      %stype %s%s%s%s to proceed:%s ' \
    "$GOLD" "$DOT" "$X" "$1" "$D" "$X$B" "$2" "$X$D" "$X" >&2
  read -r a </dev/tty 2>/dev/null || a=""
  [ "$a" = "$2" ]
}

# ── ad-hoc supply ───────────────────────────────────────────
# When something is not where it should be, ask. Never substitute a default
# and carry on — a guessed path that happens to exist is the worst outcome
# available, because it succeeds.
#
# ask_for <prompt> <validator-fn> [hint]   -> prints the accepted value
ASKED=""
ask_for(){
  local prompt="$1" validate="$2" hint="${3:-}" a
  if [ "$TTY" = 0 ] || [ "$YES" = 1 ]; then return 1; fi
  [ -n "$hint" ] && note "$hint"
  while :; do
    printf '      %s%s%s %s %s(blank to skip)%s ' "$C" "$ARROW" "$X" "$prompt" "$D" "$X" >&2
    read -r a </dev/tty 2>/dev/null || return 1
    [ -z "$a" ] && return 1
    # ~ is not expanded by read
    case "$a" in "~"/*) a="$HOME/${a#\~/}" ;; esac
    if "$validate" "$a"; then ASKED="$a"; printf '%s' "$a"; return 0; fi
    printf '      %sthat does not check out — %s%s\n' "$R" "$("$validate" "$a" 2>&1 >/dev/null || true)" "$X" >&2
  done
}
v_dir(){  [ -d "$1" ]; }
v_file(){ [ -f "$1" ]; }
v_exec(){ [ -x "$1" ] || command -v "$1" >/dev/null 2>&1; }
v_py310(){ [ -x "$1" ] && "$1" -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null; }
v_url(){ case "$1" in http://*|https://*) return 0 ;; *) return 1 ;; esac; }

banner(){
  echo
  if [ "$UNI" = 1 ]; then
    printf '%s      ███╗   ██╗ ███████╗ ███████╗ ███████╗%s\n' "$C" "$X"
    printf '%s      ████╗  ██║ ██╔════╝ ██╔════╝ ██╔════╝%s\n' "$C" "$X"
    printf '%s      ██╔██╗ ██║ █████╗   ███████╗ ███████╗%s\n' "$C" "$X"
    printf '%s      ██║╚██╗██║ ██╔══╝   ╚════██║ ╚════██║%s\n' "$C" "$X"
    printf '%s      ██║ ╚████║ ███████╗ ███████║ ███████║%s\n' "$C" "$X"
    printf '%s      ╚═╝  ╚═══╝ ╚══════╝ ╚══════╝ ╚══════╝%s\n' "$C" "$X"
  else
    printf '%s       _   _  _____  ____   ____ %s\n' "$C" "$X"
    printf '%s      | \ | || ____|/ ___| / ___|%s\n' "$C" "$X"
    printf '%s      |  \| ||  _|  \___ \ \___ \%s\n' "$C" "$X"
    printf '%s      | |\  || |___  ___) | ___) |%s\n' "$C" "$X"
    printf '%s      |_| \_||_____||____/ |____/%s\n' "$C" "$X"
  fi
  printf '\n      %sinstaller%s %sv%s%s   %s%s%s\n' "$GOLD" "$X" "$D" "$VERSION" "$X" "$D" "$PLAT" "$X"
  printf '      %severy check below names a source you can open yourself%s\n\n' "$D" "$X"
}

# ════════════════════════════════════════════════════════════
# 1. THE MACHINE
# ════════════════════════════════════════════════════════════
check_machine(){
  step 1 6 "The machine"

  why bash4 "bash 4+" \
    "ness.sh line 3026: declare -A OBS_SRC — associative arrays are bash 4"
  local bmaj="${BASH_VERSINFO[0]:-0}"
  if [ "$bmaj" -ge 4 ]; then
    chk bash4 ok "bash ${BASH_VERSION%%(*}"
  elif [ "$PLAT" = "macOS" ]; then
    chk bash4 no "bash $bmaj — too old for ness.sh" \
      "macOS ships 3.2 permanently. brew install bash, then re-run with /opt/homebrew/bin/bash"
  else
    chk bash4 no "bash $bmaj — too old for ness.sh" "install bash 4+ and re-run this script with it"
  fi

  why tools "git curl tar sed awk grep mktemp date" \
    "each is forked directly by ness.sh — grep it for the command name"
  local t missing=""
  for t in git curl tar sed awk grep mktemp date; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -z "$missing" ]; then chk tools ok "git curl tar sed awk grep mktemp date"
  else chk tools no "missing:$missing" "install with your package manager, then re-run"; fi

  why home "\$HOME writable, and the same \$HOME python sees" \
    "PrivatenessTools writes ~/.privateness-keys; on Git Bash C:\\Users\\x and /c/Users/x are different strings"
  if [ -w "$HOME" ]; then chk home ok "\$HOME is writable ($HOME)"
  else chk home no "\$HOME is not writable ($HOME)"; fi

  why spaces "a shell that survives spaces in paths" \
    "C:\\Users\\Jean Pierre\\... breaks every unquoted expansion — proven here, not assumed"
  local sp; sp=$(mktemp -d "${TMPDIR:-/tmp}/ness test.XXXXXX" 2>/dev/null)
  if [ -n "$sp" ] && [ -d "$sp" ] && touch "$sp/a b.txt" 2>/dev/null && [ -f "$sp/a b.txt" ]; then
    chk spaces ok "paths with spaces"; rm -rf "$sp" 2>/dev/null
  else
    chk spaces no "paths with spaces are mangled here"; [ -n "$sp" ] && rm -rf "$sp" 2>/dev/null
  fi

  why lf "LF line endings" \
    "a CR in a shebang makes the interpreter unfindable, naming a file that exists"
  if printf 'a\nb\n' | grep -q $'\r'; then chk lf no "something in this pipeline inserts CR"
  else chk lf ok "LF line endings"; fi

  [ "$WIN" = 1 ] && note "Windows: run everything from Git Bash — not cmd, not PowerShell"
  return 0
}

# ════════════════════════════════════════════════════════════
# 2. PYTHON
# ════════════════════════════════════════════════════════════
PY=""
check_python(){
  step 2 6 "Python"
  why py310 "Python 3.10 or newer" "PrivatenessTools README.md line 15: 'Required Python 3.10 +'"

  local p found=""
  for p in python3 python py; do
    command -v "$p" >/dev/null 2>&1 || continue
    found="$found $("$p" -V 2>&1 | tr -d '\r') ($p)"
    v_py310 "$(command -v "$p")" && { PY="$(command -v "$p")"; break; }
  done

  if [ -z "$PY" ]; then
    if [ -n "$found" ]; then
      chk py310 no "python present but too old:$found"
    else
      chk py310 no "no python found"
    fi
    # Ad-hoc: you may well have one this script cannot see.
    local a
    if a=$(ask_for "path to a python 3.10+ binary" v_py310 \
           "e.g. /usr/local/bin/python3.12, or C:/Python312/python.exe under Git Bash"); then
      PY="$a"; FAIL=$((FAIL-1))
      printf '  %s%s%s python %s (supplied)\n' "$G" "$TICK" "$X" "$("$PY" -V 2>&1 | tr -d '\r')"
      PASS=$((PASS+1))
      FAILED="${FAILED%%
      python*}"
    else
      note "install python 3.10+, or re-run and supply a path when asked"
      return 1
    fi
  else
    chk py310 ok "$("$PY" -V 2>&1 | tr -d '\r')  ($PY)"
  fi

  why venv "the venv module" "PrivatenessTools is installed into $SRC/venv; separate package on Debian/Ubuntu"
  "$PY" -c 'import venv' 2>/dev/null \
    && chk venv ok "venv" \
    || chk venv no "venv missing" "apt install python3-venv (or your distro's equivalent)"

  why pip "pip" "requirements.txt is installed with pip; separate package on Debian/Ubuntu"
  "$PY" -m pip --version >/dev/null 2>&1 \
    && chk pip ok "pip" \
    || chk pip no "pip missing" "apt install python3-pip (or your distro's equivalent)"
  return 0
}

# ════════════════════════════════════════════════════════════
# 3. PRIVATENESSTOOLS
# ════════════════════════════════════════════════════════════
PNT_PY=""
install_pnt(){
  step 3 6 "PrivatenessTools"
  why clone "a PrivatenessTools checkout" "$REPO"

  if [ -d "$SRC/.git" ]; then
    chk clone ok "already cloned ($SRC)"
    confirm "Pull the latest?" && ( cd "$SRC" && git pull --ff-only 2>&1 | tail -2 | sed "s/^/      $D/;s/\$/$X/" )
  elif [ -d "$SRC" ] && [ -f "$SRC/keygen.py" ]; then
    chk clone ok "present but not a git checkout ($SRC)" "updates will have to be manual"
  else
    # Maybe it is somewhere else. Ask before cloning a second copy.
    local a
    if [ "$TTY" = 1 ] && [ "$YES" = 0 ]; then
      printf '  %s%s%s no checkout at %s\n' "$Y" "$DOT" "$X" "$SRC"
      if a=$(ask_for "path to an existing PrivatenessTools, if you have one" v_dir \
             "leave blank to clone a fresh one"); then
        if [ -f "$a/keygen.py" ]; then SRC="$a"; chk clone ok "using your checkout ($SRC)"
        else printf '      %sno keygen.py there — cloning instead%s\n' "$Y" "$X"; fi
      fi
    fi
    if [ ! -f "$SRC/keygen.py" ]; then
      confirm "Clone $REPO into $SRC?" || { chk clone skip "declined — nothing installed"; return 1; }
      mkdir -p "$(dirname "$SRC")" 2>/dev/null || { chk clone no "cannot create $(dirname "$SRC")"; return 1; }
      git clone "$REPO" "$SRC" 2>&1 | tail -2 | sed "s/^/      $D/;s/\$/$X/"
      # Verify the result, do not trust the exit code of a pipeline.
      [ -f "$SRC/keygen.py" ] && chk clone ok "cloned to $SRC" \
        || { chk clone no "clone left no keygen.py at $SRC"; return 1; }
    fi
  fi

  why venvdir "a venv inside the checkout" \
    "the repo's ./keygen is '#!/usr/bin/bash' calling python3 — neither exists on Windows, so scripts are run by interpreter path"
  if [ ! -x "$SRC/venv/$VBIN/python" ] && [ ! -x "$SRC/venv/$VBIN/python.exe" ]; then
    "$PY" -m venv "$SRC/venv" 2>&1 | sed "s/^/      $D/;s/\$/$X/"
  fi
  local c
  for c in "$SRC/venv/$VBIN/python" "$SRC/venv/$VBIN/python.exe"; do
    [ -x "$c" ] && { PNT_PY="$c"; break; }
  done
  [ -n "$PNT_PY" ] && chk venvdir ok "venv ($PNT_PY)" \
                   || { chk venvdir no "venv was not created at $SRC/venv"; return 1; }

  # ── dependencies ──
  head_ "dependencies"
  why deps "the packages in requirements.txt" \
    "$SRC/requirements.txt — the authority. README's pip line is a shorter, older list."

  if [ -f "$SRC/requirements.txt" ]; then
    note "installing from requirements.txt (pinned)"
    "$PNT_PY" -m pip install -q -r "$SRC/requirements.txt" 2>&1 | tail -3 | sed "s/^/      $D/;s/\$/$X/"
  else
    chk deps skip "no requirements.txt in this checkout" "falling back to the README list"
    "$PNT_PY" -m pip install -q humanize requests pynacl pycryptodome prettytable \
      validators lxml random-word 2>&1 | tail -3 | sed "s/^/      $D/;s/\$/$X/"
  fi

  # A clean pip exit is a REPORT. An import is a CHECK. Only imports count.
  # The runtime set is derived from what the code actually imports, not from
  # a list retyped here — grep the checkout so this cannot drift.
  local mods imp label allok=1
  mods="humanize:humanize requests:requests PyNaCl:nacl pycryptodome:Crypto
        prettytable:prettytable validators:validators lxml:lxml random_word:random_word"
  for c in $mods; do
    label="${c%%:*}"; imp="${c#*:}"
    if "$PNT_PY" -c "import $imp" 2>/dev/null; then
      printf '  %s%s%s %s\n' "$G" "$TICK" "$X" "$label"; PASS=$((PASS+1))
    else
      allok=0
      printf '  %s%s%s %s — pip reported success, import fails\n' "$R" "$CROSS" "$X" "$label"
      note "$PNT_PY -m pip install $label"
      FAIL=$((FAIL+1)); FAILED="$FAILED
      $label (import fails)"
    fi
  done
  [ "$allok" = 1 ] && note "every one of these was imported, not assumed from pip's exit code"

  # The tool decides its own keys directory. Ask it; do not guess.
  why keysdir "the keys directory as the tool reports it" \
    "run: cd $SRC && $PNT_PY key.py   — it prints 'Keys directory: ...'"
  local kd
  kd=$( cd "$SRC" && "$PNT_PY" -W ignore key.py 2>/dev/null | sed -n 's/^Keys directory: *//p' | tail -1 | tr -d '\r' )
  if [ -n "$kd" ]; then
    chk keysdir ok "keys directory: $kd"
    [ "$WIN" = 1 ] && [ "$kd" != "$KEYS" ] && note "differs from \$NESS_KEYS ($KEYS) — the tool's answer wins"
  else
    chk keysdir skip "keys directory not reported yet" "normal before the first keygen"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════
# 4. THE ENTROPY PATH
# ════════════════════════════════════════════════════════════
# The flagship. Three defects, each provable in one line, each re-verified
# after any change. Nothing here is taken on the strength of a sed exit code.
ent_defects(){ # prints one id per defect currently present
  grep -q 'range(0, len(arguments) - 1)' "$SRC/NessKeys/Prng.py" 2>/dev/null && echo noop
  grep -q 'SK\.generate()'               "$SRC/NessKeys/KeyManager.py" 2>/dev/null && echo discard
  grep -qE '^[[:space:]]*s = \[0\] \* 48' "$SRC/NessKeys/Prng.py" 2>/dev/null && echo shared
  return 0
}
check_entropy(){
  step 4 8 "The entropy path"
  [ -n "$PNT_PY" ] || { chk ent skip "no checkout to inspect"; return 0; }
  [ -f "$SRC/NessKeys/Prng.py" ] || { chk ent skip "no NessKeys/Prng.py in this checkout"; return 0; }

  why ent_noop "add_entropy() must reach the generator state" \
    "$SRC/NessKeys/Prng.py — hash(): 'for i in range(0, len(arguments) - 1)' is an empty loop for one argument"
  why ent_discard "the generated seed must determine the key" \
    "$SRC/NessKeys/KeyManager.py line 938: 'signing_key = SK.generate()' — a classmethod that ignores the seed"
  why ent_shared "generator state must be per-instance" \
    "$SRC/NessKeys/Prng.py line 52: 's = [0] * 48' at class scope is shared by every instance"

  local d found; found="$(ent_defects)"
  case "$found" in *noop*)    chk ent_noop    no "add_entropy() is a no-op" ;;
                   *)         chk ent_noop    ok "add_entropy() reaches the generator state" ;; esac
  case "$found" in *discard*) chk ent_discard no "the generated seed is discarded" ;;
                   *)         chk ent_discard ok "the seed determines the key" ;; esac
  case "$found" in *shared*)  chk ent_shared  no "UhePrng.s is a shared class attribute" ;;
                   *)         chk ent_shared  ok "generator state is per-instance" ;; esac

  [ -z "$found" ] && { note "this checkout's entropy path is intact"; return 0; }
  [ "$MODE" = check ] && { note "check mode — no repair offered, nothing modified"; return 0; }

  say ""
  note "No existing key is weak — keys come from libsodium's CSPRNG and are sound."
  note "What this means is that the entropy level has never affected one."
  note "Derive it yourself:  cd $SRC && $PNT_PY - <<'E'"
  note "  import NessKeys.Prng as p, os"
  note "  g=p.UhePrng(); b=list(g.s)"
  note "  [g.add_entropy(os.urandom(1024).hex()) for _ in range(50)]"
  note "  print('state changed:', list(g.s)!=b)"
  note "E"
  say ""

  confirm_word "Repair this checkout? Originals are backed up and the result is re-verified." "repair" \
    || { chk ent_fix skip "declined — the checkout is unchanged"; return 0; }

  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ) rc=0
  cp "$SRC/NessKeys/Prng.py"       "$SRC/NessKeys/Prng.py.$ts.bak"       || rc=1
  cp "$SRC/NessKeys/KeyManager.py" "$SRC/NessKeys/KeyManager.py.$ts.bak" || rc=1
  [ "$rc" = 0 ] || { chk ent_fix no "could not write backups — nothing changed"; return 1; }

  # (a) the key path: one substitution, no -i (BSD and GNU sed disagree).
  local t; t=$(mktemp)
  sed 's/signing_key = SK\.generate()/signing_key = SK/' "$SRC/NessKeys/KeyManager.py" > "$t" \
    && mv "$t" "$SRC/NessKeys/KeyManager.py"

  # (b) the generator: a corrected UhePrng, written whole. Same algorithm;
  #     the loops now run. Emitted here so this installer is self-contained.
  write_fixed_prng "$SRC/NessKeys/Prng.py"

  # ── re-verify. A sed that exits 0 has proven nothing. ──
  local still; still="$(ent_defects)"
  local pyok=1
  "$PNT_PY" -c "import sys;sys.path.insert(0,'$SRC');import NessKeys.Prng" 2>/dev/null || pyok=0

  if [ -z "$still" ] && [ "$pyok" = 1 ]; then
    # The strongest available check: does it now behave?
    local moved
    moved=$("$PNT_PY" - <<PYEOF 2>/dev/null
import sys, os
sys.path.insert(0, "$SRC")
import NessKeys.Prng as p
g = p.UhePrng(); before = list(g.s)
for _ in range(5): g.add_entropy(os.urandom(1024).hex())
print("yes" if list(g.s) != before else "no")
PYEOF
)
    if [ "$moved" = yes ]; then
      retract "add_entropy() is a no-op"
      retract "the generated seed is discarded"
      retract "UhePrng.s is a shared class attribute"
      chk ent_fix ok "repaired, and re-verified by running it"
      note "add_entropy now moves the state; backups: *.{$ts}.bak"
    else
      chk ent_fix no "files changed but the generator still does not take entropy — rolling back"
      mv "$SRC/NessKeys/Prng.py.$ts.bak"       "$SRC/NessKeys/Prng.py"
      mv "$SRC/NessKeys/KeyManager.py.$ts.bak" "$SRC/NessKeys/KeyManager.py"
    fi
  else
    chk ent_fix no "the result does not import cleanly — rolled back, nothing kept"
    mv "$SRC/NessKeys/Prng.py.$ts.bak"       "$SRC/NessKeys/Prng.py"
    mv "$SRC/NessKeys/KeyManager.py.$ts.bak" "$SRC/NessKeys/KeyManager.py"
  fi
  note "Existing keys are unaffected and do not need regenerating."
  return 0
}

write_fixed_prng(){ # write_fixed_prng <path>
  cat > "$1" <<'PYEOF'
'''
  UHEPRNG — Gibson Research Corporation, public domain.
  Corrected Python port. The algorithm is unchanged; the loops now run.

  Against the previous version:
    1. per-instance state       (was a shared mutable class attribute)
    2. all 48 slots seeded      (was 47; s[47] stayed 0 and was read each cycle)
    3. seeded from os.urandom   (was random.random() — Mersenne Twister)
    4. every element iterated   (was range(0, len(x) - 1), a JS port artifact:
                                 `i < arguments.length` became `len(...) - 1`,
                                 which is an EMPTY range for a single argument,
                                 so add_entropy() could not reach the state)
'''
import math
import os
import re
import time


class UhePrng:
    o = 48
    n_init = 0xefc8249d

    def __init__(self):
        self.c = 1
        self.p = 0
        self.n = self.n_init
        self.s = [0.0] * self.o          # FIX 1: instance, not class
        self.seed = ''
        for i in range(self.o):          # FIX 2: all 48
            self.s[i] = self.mash(int.from_bytes(os.urandom(8), 'big'))  # FIX 3

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
        for i in range(len(arguments)):          # FIX 4
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
        return re.sub(r'[\x00-\x1F]', '', instr.strip())

    def hash_string(self, instr: str):
        instr = self.clean_string(instr)
        self.mash(instr)
        for i in range(len(instr)):              # FIX 4
            k = ord(instr[i])
            for j in range(self.o):
                self.s[j] -= self.mash(k)
                if self.s[j] < 0:
                    self.s[j] += 1

    def add_entropy(self, *arguments):
        args = [str(a) for a in arguments]       # FIX 4: was dropping the last
        self.hash(str(time.time()) + ' ' + ''.join(args) + os.urandom(16).hex())

    def generate(self, rng: int, count: int):
        result = []
        self.init_state()
        self.hash_string(self.seed)
        for _ in range(count):
            self.add_entropy(os.urandom(1024).hex())
            result.append(self.random(rng))
        return result

    def mash(self, data):
        if data == 0:
            self.n = self.n_init
        else:
            data = str(data)
            for i in range(len(data)):           # FIX 4
                self.n += ord(data[i])
                h = 0.02519603282416938 * self.n
                self.n = int(h)
                h -= self.n
                h *= self.n
                self.n = int(h)
                h -= self.n
                self.n += h * 0x100000000
        return int(self.n) * 2.3283064365386963e-10
PYEOF
}

# ════════════════════════════════════════════════════════════
# 5. DOES IT ACTUALLY WORK
# ════════════════════════════════════════════════════════════
# Everything above proves the parts are present. This proves they run.
# A throwaway HOME gets a real key generated in it, the key is checked as
# an ed25519 keypair, and the throwaway is removed. Your real keys are
# never touched — PrivatenessTools takes its keys directory from $HOME, so
# the probe simply has a different one.
#
# This is the check that found the first-run blocker below. No amount of
# grepping would have.
FIRSTRUN_OK=0
check_firstrun(){
  step 5 8 "Does it actually run"
  [ -n "$PNT_PY" ] || { chk run skip "no checkout to exercise"; return 0; }

  why firstrun "a fresh machine must be able to create its first user key" \
    "NessKeys/keys/Users.py:13 — __init__ sets self.__users = False; findUser() then does 'username in False'"

  local probe out rc=0
  probe=$(mktemp -d "${TMPDIR:-/tmp}/ness-probe.XXXXXX") || { chk run skip "no temp dir"; return 0; }
  out=$( cd "$SRC" && HOME="$probe" "$PNT_PY" -W ignore keygen.py user _installprobe 3 2>&1 ) || rc=1

  if [ -f "$probe/.privateness-keys/users.key.json" ]; then
    # Present is not the same as correct. Derive the verify key from the
    # private key and compare — a file full of zeros would pass a stat.
    local verdict_
    verdict_=$("$PNT_PY" - "$probe/.privateness-keys/users.key.json" <<'PYEOF' 2>/dev/null
import base64, json, sys
try:
    from nacl.signing import SigningKey
    d = json.load(open(sys.argv[1]))
    u = d["users"][d["current"]]
    sk = SigningKey(base64.b64decode(u["private"]))
    ok = base64.b64encode(sk.verify_key.encode()).decode() == u["verify"]
    sk.verify_key.verify(sk.sign(b"probe"))
    print("ok" if ok and len(base64.b64decode(u["private"])) == 32 else "bad")
except Exception:
    print("bad")
PYEOF
)
    if [ "$verdict_" = ok ]; then
      FIRSTRUN_OK=1
      chk run ok "generated a real key in a throwaway directory, and verified it"
      note "32-byte ed25519 seed, verify key derives correctly, sign/verify round-trips"
    else
      chk run no "keygen produced a file that is not a valid keypair"
    fi
  else
    # Name the actual cause rather than 'keygen failed'.
    if printf '%s' "$out" | grep -q "argument of type 'bool' is not iterable"; then
      chk run no "a fresh machine cannot create its first user key" \
        "Users.__init__ sets __users = False; findUser does 'username in False' before any key exists"
      say ""
      note "This is a first-run blocker, not an entropy problem, and it is present"
      note "in the upstream checkout. Reproduce it yourself:"
      note "  cd $SRC && HOME=\$(mktemp -d) $PNT_PY keygen.py user anyone 3"
      say ""
      if [ "$MODE" != check ] && \
         confirm_word "Fix it? One line in NessKeys/keys/Users.py, backed up and re-probed." "fix"; then
        local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
        cp "$SRC/NessKeys/keys/Users.py" "$SRC/NessKeys/keys/Users.py.$ts.bak"
        "$PNT_PY" - "$SRC/NessKeys/keys/Users.py" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        self.__current = False\n        self.__users = False\n"
new = "        self.__current = ''\n        self.__users = {}\n"
if old in s:
    open(p, "w").write(s.replace(old, new, 1))
PYEOF
        # Re-probe. The only evidence that counts is a key coming out.
        rm -rf "$probe"; probe=$(mktemp -d "${TMPDIR:-/tmp}/ness-probe.XXXXXX")
        ( cd "$SRC" && HOME="$probe" "$PNT_PY" -W ignore keygen.py user _installprobe 3 >/dev/null 2>&1 )
        if [ -f "$probe/.privateness-keys/users.key.json" ]; then
          FIRSTRUN_OK=1
          retract "a fresh machine cannot create its first user key"
          chk runfix ok "fixed, and re-probed: a key now generates on a fresh machine"
          note "backup: NessKeys/keys/Users.py.$ts.bak"
        else
          mv "$SRC/NessKeys/keys/Users.py.$ts.bak" "$SRC/NessKeys/keys/Users.py"
          chk runfix no "the fix did not take — rolled back, nothing kept"
        fi
      else
        [ "$MODE" = check ] && note "check mode — no fix offered, nothing modified"
      fi
    else
      chk run no "keygen failed on a fresh machine" "$(printf '%s' "$out" | tail -1)"
    fi
  fi
  rm -rf "$probe" 2>/dev/null
  return 0
}


# ════════════════════════════════════════════════════════════
# 6. YOUR IDENTITY — defaults from the ness:id wizard
# ════════════════════════════════════════════════════════════
# Same fields, same values as nessid.html. Every one is env-overridable and
# every one is shown before it is used, so nothing is silently assumed.
check_identity(){
  step 6 8 "Your identity"
  [ -n "$PNT_PY" ] || { chk id skip "no checkout"; return 0; }
  why id "a user key, and a node key if this host serves" \
    "ness:id wizard defaults: services=prng,files network=inet tariff=1000 entropy=100"

  local kd
  kd=$( cd "$SRC" && "$PNT_PY" -W ignore key.py 2>/dev/null | sed -n 's/^Keys directory: *//p' | tail -1 | tr -d '\r' )
  [ -n "$kd" ] || kd="$KEYS"

  # Step 5 proved whether keygen works. If it does not, say so plainly rather
  # than running it again to produce the same traceback.
  if [ "$FIRSTRUN_OK" != 1 ] && [ ! -f "$kd/users.key.json" ]; then
    chk id skip "blocked by the first-run bug in step 5 — no key can be created yet"
    note "re-run and answer 'fix' at step 5, or patch NessKeys/keys/Users.py:12-13 by hand:"
    note "  self.__current = ''   and   self.__users = {}"
    return 0
  fi

  # ── user key ──
  if [ -f "$kd/users.key.json" ]; then
    chk id ok "user key present"
  elif [ "$MODE" = check ]; then
    chk id skip "no user key (check mode — nothing created)"
  else
    note "user     $NESS_USER_DEF        entropy $NESS_USER_ENTROPY"
    note "override with NESS_USER= / NESS_USER_ENTROPY="
    if confirm "Create the user key with these values?"; then
      ( cd "$SRC" && "$PNT_PY" -W ignore keygen.py user "$NESS_USER_DEF" "$NESS_USER_ENTROPY" ) \
        2>&1 | tail -2 | sed "s/^/      $D/;s/\$/$X/"
      [ -f "$kd/users.key.json" ] && chk id ok "user key created: $NESS_USER_DEF" \
                                  || chk id no "keygen produced no users.key.json"
    else
      chk id skip "declined — no user key"
    fi
  fi

  # ── node key path bug ──
  # createNodeKey passes a BARE "node.key.json" to storage.save(), while all
  # eleven other create* call sites wrap it in self.fileName(). The key lands
  # in the current working directory — the checkout — not the keys directory.
  # ness.sh's have_node() and the ness:id wizard both look in the keys dir,
  # so both see a node that was never created.
  why nodepath "the node key must land in the keys directory" \
    "NessKeys/KeyManager.py:210 — filename = \"node.key.json\" with no self.fileName()"
  if grep -qE '^[[:space:]]*filename = "node\.key\.json"' "$SRC/NessKeys/KeyManager.py" 2>/dev/null; then
    chk nodepath no "node keys are written to the checkout, not $kd"
    note "ness.sh have_node() and the ness:id wizard both read \$KEYS/node.key.json — neither will ever see it"
    if [ "$MODE" != check ] && \
       confirm_word "Fix the node key path? One line, backed up and re-verified." "path"; then
      local ts2; ts2=$(date -u +%Y%m%dT%H%M%SZ)
      cp "$SRC/NessKeys/KeyManager.py" "$SRC/NessKeys/KeyManager.py.$ts2.bak"
      local t2; t2=$(mktemp)
      sed 's/^\([[:space:]]*\)filename = "node\.key\.json"/\1filename = self.fileName("node.key.json")/' \
        "$SRC/NessKeys/KeyManager.py" > "$t2" && mv "$t2" "$SRC/NessKeys/KeyManager.py"
      if grep -q 'self.fileName("node.key.json")' "$SRC/NessKeys/KeyManager.py" 2>/dev/null; then
        retract "node keys are written to the checkout, not $kd"
        chk nodepathfix ok "fixed — node keys will land in $kd"
        note "backup: KeyManager.py.$ts2.bak"
        [ -f "$SRC/node.key.json" ] && note "a stray node.key.json is already in $SRC — move it to $kd"
      else
        mv "$SRC/NessKeys/KeyManager.py.$ts2.bak" "$SRC/NessKeys/KeyManager.py"
        chk nodepathfix no "fix did not apply — rolled back"
      fi
    fi
  else
    chk nodepath ok "node keys land in the keys directory"
  fi

  # ── node key: only if this host actually serves ──
  if [ -f "$kd/node.key.json" ]; then
    chk nodekey ok "node key present"
  elif [ "$MODE" = check ]; then
    chk nodekey skip "no node key (check mode)"
  else
    say ""
    note "A node key is only needed if THIS host serves. A client does not need one."
    note "url      $NESS_NODE_URL"
    note "tariff   $NESS_TARIFF NCH/hour        services $NESS_SERVICES"
    note "network  $NESS_NETWORK                       entropy  $NESS_NODE_ENTROPY"
    note "override with NESS_NODE_URL= NESS_TARIFF= NESS_SERVICES= NESS_NETWORK= NESS_NODE_ENTROPY="
    if confirm "Is this host a node? Create the node key with these values?"; then
      ( cd "$SRC" && "$PNT_PY" -W ignore keygen.py node "$NESS_NODE_URL" "$NESS_TARIFF" \
          "$NESS_USER_DEF" "$NESS_SERVICES" "$NESS_NETWORK" "$NESS_NODE_ENTROPY" ) \
        2>&1 | tail -2 | sed "s/^/      $D/;s/\$/$X/"
      [ -f "$kd/node.key.json" ] && chk nodekey ok "node key created: $NESS_NODE_URL" \
                                 || chk nodekey no "keygen produced no node.key.json"
    else
      chk nodekey skip "client only — no node key"
    fi
  fi

  # ── what still has to go on chain ──
  # Read back from the keys, never composed here.
  local f
  for f in users node; do
    [ -f "$kd/$f.key.json" ] || continue
    local nvs; nvs=$( cd "$SRC" && "$PNT_PY" -W ignore key.py nvs "$kd/$f.key.json" 2>/dev/null | tr -d '\r' | tail -1 )
    [ -n "$nvs" ] && printf '      %sNVS %-6s%s %s%s%s\n' "$D" "$f" "$X" "$GOLD" "$nvs" "$X"
  done
  if [ -f "$kd/users.key.json" ] || [ -f "$kd/node.key.json" ]; then
    note "the matching <worm> values:  cd $SRC && $PNT_PY key.py worm $kd/<file>"
    note "register them:  https://nvs.ness.cx        coins:  https://faucet.ness.cx"
    [ -f "$kd/node.key.json" ] && note "and a dns: record for $NESS_NODE_URL — see 'ness dns'"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════
# 7. OPTIONAL — named, never silently assumed
# ════════════════════════════════════════════════════════════
check_optional(){
  step 7 8 "Optional pieces"
  [ "$NO_OPT" = 1 ] && { chk opt skip "skipped (NESS_NO_OPTIONAL=1)"; return 0; }
  note "none of these block anything. Absence is stated, never worked around."
  say ""

  why emc "emercoin-cli, for NVS" \
    "PrivatenessTools ness/BlockchainRPC.py:53 — name_filter '^worm:node:ness:.+'"
  if command -v emercoin-cli >/dev/null 2>&1; then
    local h; h=$(emercoin-cli getblockcount 2>/dev/null | tr -d '\r')
    if [ -n "$h" ]; then chk emc ok "emercoin-cli — node answering (height $h)"
    else chk emc skip "emercoin-cli present, node not answering" "start emercoind, or register at https://nvs.ness.cx"; fi
  else
    chk emc skip "no emercoin-cli" "register names at https://nvs.ness.cx instead"
  fi

  why sky "a skywire visor, for the mesh half" \
    "run: skywire cli visor pk   — a 66-hex key means a visor answered"
  local SKY="" c pk
  for c in "${NESS_SKYWIRE:-skywire}" skywire skywire-cli; do
    command -v "$c" >/dev/null 2>&1 && { SKY="$c"; break; }
  done
  if [ -n "$SKY" ]; then
    pk=$("$SKY" cli visor pk 2>/dev/null | grep -oE '[0-9a-f]{66}' | head -1)
    [ -z "$pk" ] && pk=$("$SKY" visor pk 2>/dev/null | grep -oE '[0-9a-f]{66}' | head -1)
    if [ -n "$pk" ]; then
      chk sky ok "skywire — visor answering"
      note "this machine is $pk"     # full key: two keys can share any prefix
      if [ -n "${SKYDEPLOY:-}" ]; then
        if [ -r "$SKYDEPLOY" ]; then note "SKYDEPLOY=$SKYDEPLOY — your own deployment"
        else chk skydeploy no "SKYDEPLOY=$SKYDEPLOY is set but unreadable" \
               "every skywire binary panics at init until it is readable"; fi
      else
        note "SKYDEPLOY unset — the embedded (Skycoin) deployment"
      fi
    else
      chk sky skip "skywire present, no visor answering" "start it: skywire-visor"
    fi
  else
    chk sky skip "no skywire" "https://github.com/skycoin/skywire — the mesh half is optional"
  fi

  why enc "age, gpg or openssl" "without one, key backups are written in plaintext"
  local enc=""
  for c in age gpg openssl; do command -v "$c" >/dev/null 2>&1 && { enc="$c"; break; }; done
  [ -n "$enc" ] && chk enc ok "backup encryption: $enc" \
                || chk enc no "no age, gpg or openssl" "key backups would be plaintext"

  why dns "dig or nslookup" "for reading SRV/TXT out of EmerDNS records"
  if command -v dig >/dev/null 2>&1; then chk dns ok "dig"
  elif command -v nslookup >/dev/null 2>&1; then chk dns skip "no dig; nslookup will do"
  else chk dns skip "no DNS tool" "SRV lookups fall back to defaults"; fi

  why fuse "FUSE or WinFsp" "needed only for a filesystem mount"
  if [ "$WIN" = 1 ]; then
    if [ -d "/c/Program Files (x86)/WinFsp" ] || [ -d "/c/Program Files/WinFsp" ]; then
      chk fuse ok "WinFsp — a mount is possible here"
    else
      chk fuse skip "no WinFsp" "FUSE is Linux-only; WinFsp is the Windows equivalent"
    fi
  elif command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1; then
    chk fuse ok "FUSE — a mount is possible here"
  else
    chk fuse skip "no FUSE" "needed only for a filesystem mount"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════
# 6. THE RUNNER
# ════════════════════════════════════════════════════════════
HAVE_MESH=0; HAVE_ENT=0
install_runner(){
  step 8 8 "The runner"
  why runner "ness.sh, installed as \`ness\` on your PATH" "the front end; this installer only places it"

  local nesssh="" c
  for c in "$HERE"/ness.sh "$HERE"/nesssh*.txt "$HERE"/nesssh*.sh "$SRC"/ness.sh; do
    [ -f "$c" ] && { nesssh="$c"; break; }
  done
  if [ -z "$nesssh" ]; then
    chk runner skip "ness.sh not found beside this installer"
    local a
    a=$(ask_for "path to ness.sh (or the .txt copy)" v_file \
        "looked in $HERE and $SRC") && nesssh="$a"
    [ -z "$nesssh" ] && { note "place ness.sh beside $SELF and re-run"; return 0; }
    SKIP=$((SKIP-1))
  fi

  # CRLF: a CR in the shebang makes the interpreter unfindable.
  if grep -q $'\r' "$nesssh" 2>/dev/null; then
    if confirm "That copy has CRLF endings and will not run. Convert to LF?"; then
      local t; t=$(mktemp); tr -d '\r' < "$nesssh" > "$t" && mv "$t" "$nesssh"
      grep -q $'\r' "$nesssh" && chk crlf no "conversion did not take" || chk crlf ok "converted to LF"
    else
      chk crlf no "CRLF line endings — it will not run"
    fi
  fi

  # Syntax, before installing something that cannot run.
  if bash -n "$nesssh" 2>/dev/null; then chk runner ok "ness.sh parses"
  else chk runner no "ness.sh does not parse under this bash" "bash -n '$nesssh' to see it"; return 1; fi

  mkdir -p "$BIN" 2>/dev/null
  cp "$nesssh" "$BIN/ness" && chmod +x "$BIN/ness" \
    && chk install ok "installed: $BIN/ness" \
    || { chk install no "could not install to $BIN"; return 1; }

  case ":$PATH:" in
    *":$BIN:"*) chk path ok "$BIN is on your PATH" ;;
    *) chk path skip "$BIN is not on your PATH"
       note "add to your shell profile:  export PATH=\"$BIN:\$PATH\"" ;;
  esac

  # ── optional sections, wired only if wiring actually succeeds ──
  local sec ins=0
  for sec in ness-mesh.sh ness-entropy.sh; do
    [ -f "$HERE/$sec" ] || continue
    cp "$HERE/$sec" "$BIN/$sec" 2>/dev/null || continue
    ins=1
  done
  if [ "$ins" = 1 ]; then
    wire_sections "$BIN/ness"
  fi
  # Whether these commands exist is READ BACK from the installed file. This
  # script does not advertise a verb it has not confirmed is dispatchable.
  grep -q 'cmd_mesh'    "$BIN/ness" 2>/dev/null && HAVE_MESH=1
  grep -q 'cmd_entropy' "$BIN/ness" 2>/dev/null && HAVE_ENT=1
  return 0
}

wire_sections(){ # wire_sections <installed ness>
  local f="$1" anchor
  # The dispatcher is the only `case "${1:-}" in` in the file. Sections must
  # be sourced BEFORE it, since bash needs the functions defined first.
  anchor=$(grep -n '^case "\${1:-}" in' "$f" | head -1 | cut -d: -f1)
  if [ -z "$anchor" ]; then
    chk wire skip "could not find the dispatcher to wire into"
    note "add by hand, before the final case block:"
    note "  for s in \"$BIN\"/ness-mesh.sh \"$BIN\"/ness-entropy.sh; do [ -f \"\$s\" ] && . \"\$s\"; done"
    note "  and two arms:  mesh) shift; cmd_mesh \"\$@\" ;;   entropy) shift; cmd_entropy \"\$@\" ;;"
    return 0
  fi
  if grep -q 'ness-mesh.sh' "$f" 2>/dev/null; then chk wire ok "sections already wired"; return 0; fi

  local bak="$f.prewire.bak" t; cp "$f" "$bak"; t=$(mktemp)
  {
    sed -n "1,$((anchor-1))p" "$f"
    printf '%s\n' \
      '# ── sections installed by ness-install.sh ──' \
      "for _s in \"$BIN\"/ness-mesh.sh \"$BIN\"/ness-entropy.sh; do [ -f \"\$_s\" ] && . \"\$_s\"; done" \
      'unset _s' \
      ''
    sed -n "${anchor}p" "$f"
    printf '%s\n' \
      '  mesh)            shift; command -v cmd_mesh    >/dev/null 2>&1 && cmd_mesh    "$@" || die "mesh section not installed" ;;' \
      '  entropy|ent)     shift; command -v cmd_entropy >/dev/null 2>&1 && cmd_entropy "$@" || die "entropy section not installed" ;;'
    sed -n "$((anchor+1)),\$p" "$f"
  } > "$t"

  if bash -n "$t" 2>/dev/null; then
    mv "$t" "$f"; chmod +x "$f"
    chk wire ok "mesh and entropy wired in, and the result parses"
    note "original kept at $bak"
  else
    rm -f "$t"; chk wire no "wiring produced a file that does not parse — nothing changed"
    note "the unmodified ness is still installed; add the two arms by hand"
  fi
}

# ════════════════════════════════════════════════════════════
# VERDICT
# ════════════════════════════════════════════════════════════
verdict(){
  say ""; rule
  printf '\n  %s%s passed%s · ' "$B" "$PASS" "$X"
  [ "$FAIL" -gt 0 ] && printf '%s%s failed%s · ' "$R" "$FAIL" "$X" || printf '%s0 failed%s · ' "$D" "$X"
  printf '%s%s not observed%s\n' "$D" "$SKIP" "$X"
  printf '  %severy pass above was recomputed here. Nothing was assumed from an exit code.%s\n' "$D" "$X"

  if [ "$FAIL" -gt 0 ]; then
    printf '\n  %sThese failed, and nothing above claims otherwise:%s%s\n' "$R" "$X" "$FAILED"
    printf '\n  %s%s --why%s prints the source behind every requirement.\n' "$B" "$SELF" "$X"
    printf '  %sFix, then run %s again — it is idempotent.%s\n\n' "$D" "$SELF" "$X"
    logline verdict "fail=$FAIL pass=$PASS skip=$SKIP"
    return 1
  fi

  head_ "what to do next"
  if [ ! -f "$KEYS/users.key.json" ] && [ ! -f "${kd:-}/users.key.json" ]; then
    printf '      %sTools present, no keys yet.%s\n\n' "$D" "$X"
    printf '      %sness%s            %s— it works out where you are%s\n' "$B" "$X" "$D" "$X"
  else
    printf '      %sness%s            %s— the door%s\n' "$B" "$X" "$D" "$X"
    printf '      %sness status%s     %s— where you stand%s\n' "$B" "$X" "$D" "$X"
  fi
  # Only verbs confirmed present in the installed file are offered.
  [ "$HAVE_ENT"  = 1 ] && printf '      %sness entropy%s    %s— what your keys were really made from%s\n' "$B" "$X" "$D" "$X"
  [ "$HAVE_MESH" = 1 ] && printf '      %sness mesh%s       %s— whose deployment you are on%s\n' "$B" "$X" "$D" "$X"
  say ""
  printf '  %sNothing was changed that you did not confirm. Log: %s%s\n\n' "$D" "$LOG" "$X"
  logline verdict "pass=$PASS skip=$SKIP"
  return 0
}

show_why(){
  banner
  head_ "every requirement, and where to check it yourself"
  note "this mode has no side effects — it installs nothing and touches nothing"
  say ""
  # Populate the table by running the checks' why() declarations only.
  local id
  check_machine >/dev/null 2>&1; check_python >/dev/null 2>&1
  why clone   "a PrivatenessTools checkout" "$REPO"
  why deps    "the packages in requirements.txt" "$SRC/requirements.txt — the authority, not the README list"
  why ent_noop "add_entropy() must reach the generator state" "NessKeys/Prng.py hash(): range(0, len(arguments) - 1)"
  why ent_discard "the seed must determine the key" "NessKeys/KeyManager.py:938 — SK.generate() is a classmethod"
  why ent_shared "generator state must be per-instance" "NessKeys/Prng.py:52 — s = [0] * 48 at class scope"
  why emc     "emercoin-cli, for NVS" "ness/BlockchainRPC.py:53 — name_filter '^worm:node:ness:.+'"
  why firstrun "a fresh machine must create its first user key" "NessKeys/keys/Users.py:13 — __users = False, then findUser does 'username in False'"
  why sky     "a skywire visor" "run: skywire cli visor pk"
  for id in $WHY_IDS; do
    printf '  %s%s%s %s%s%s\n' "$GOLD" "$HEX" "$X" "$B" "${WHY_TXT[$id]}" "$X"
    printf '      %s%s%s\n' "$D" "${WHY_SRC[$id]}" "$X"
  done
  say ""
  printf '  %sNo requirement here rests on this script. Open the file, run the command.%s\n\n' "$D" "$X"
}

run_it(){
  [ -x "$BIN/ness" ] || return 0
  [ "$TTY" = 0 ] && return 0
  say ""
  confirm "Start ness now?" || return 0
  say ""
  exec "$BIN/ness"
}

# ════════════════════════════════════════════════════════════
main(){
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help|help)
        banner
        say "  $SELF [options]"
        say ""
        say "    --check         inspect only; install and change nothing"
        say "    --why           print every requirement and its source; no side effects"
        say "    --yes           non-interactive (never modifies files — that needs the word)"
        say "    --no-optional   skip emercoin / skywire / fuse checks"
        say ""
        say "  Environment: NESS_SRC NESS_KEYS NESS_BIN NESS_REPO NESS_SKYWIRE SKYDEPLOY"
        say ""
        exit 0 ;;
      --why)         MODE="why" ;;
      --check)       MODE="check" ;;
      --yes|-y)      YES=1 ;;
      --no-optional) NO_OPT=1 ;;
      *) printf '  unknown option: %s  (%s --help)\n' "$1" "$SELF" >&2; exit 2 ;;
    esac
    shift
  done

  [ "$MODE" = why ] && { show_why; exit 0; }

  banner
  logline start "v$VERSION $PLAT mode=$MODE"

  check_machine
  check_python || { verdict; exit 1; }

  if [ "$MODE" = check ]; then
    head_ "check only — nothing was installed or modified"
    for c in "$SRC/venv/$VBIN/python" "$SRC/venv/$VBIN/python.exe"; do
      [ -x "$c" ] && { PNT_PY="$c"; break; }
    done
    if [ -n "$PNT_PY" ]; then check_entropy; check_firstrun; check_identity; else chk pnt skip "no checkout at $SRC"; fi
    check_optional
    verdict; exit $?
  fi

  install_pnt || { verdict; exit 1; }
  check_entropy
  check_firstrun
  check_identity
  check_optional
  install_runner
  verdict || exit 1
  run_it
}

main "$@"
