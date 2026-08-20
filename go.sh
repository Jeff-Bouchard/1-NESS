#!/usr/bin/env bash
# go.sh — unpack the ness bundle and run it. That is the whole job.
#
#     bash go.sh                 find the bundle here or in ~, unpack, install
#     bash go.sh /path/to/bundle.tar.gz
#     bash go.sh --unpack-only   unpack and stop
#
# Heals its own CRLF first, so a mangled download cannot kill it. Everything
# it extracts gets LF endings and exec bits before anything is run.
[ -n "${NESS_LF:-}" ] || exec env NESS_LF=1 bash -c 'f=$1; shift; t=$(mktemp); tr -d "\r" <"$f" >"$t"; if cmp -s "$t" "$f"; then rm -f "$t"; exec bash "$f" "$@"; fi; cat "$t" >"$f" 2>/dev/null && rm -f "$t" && exec bash "$f" "$@"; chmod +x "$t"; exec bash "$t" "$@"' _ "$0" "$@"  #

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
DEST="${NESS_DEST:-$HERE/ness-bundle}"
UNPACK_ONLY=0
ARC=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  X=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; C=$'\033[36m'
else X=""; B=""; D=""; R=""; G=""; C=""; fi
ok(){ printf '  %s+%s %s\n' "$G" "$X" "$*"; }
no(){ printf '  %sx%s %s\n' "$R" "$X" "$*" >&2; }
nn(){ printf '    %s%s%s\n' "$D" "$*" "$X"; }
die(){ no "$1"; [ -n "${2:-}" ] && nn "$2"; exit 1; }

for a in "$@"; do
  case "$a" in
    --unpack-only) UNPACK_ONLY=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) [ -f "$a" ] && ARC="$a" ;;
  esac
done

printf '\n%s⬢ ness%s %sbootstrap%s\n\n' "$C" "$X" "$D" "$X"

# ── find the archive ────────────────────────────────────────
if [ -z "$ARC" ]; then
  for c in "$HERE"/ness-bundle.tar.gz "$HERE"/ness-bundle.zip \
           "$HOME"/ness-bundle.tar.gz "$HOME"/ness-bundle.zip \
           "$HERE"/ness-bundle*.tar.gz "$HERE"/ness-bundle*.zip; do
    [ -f "$c" ] && { ARC="$c"; break; }
  done
fi

if [ -z "$ARC" ]; then
  # Maybe it is already unpacked, or the files are just sitting here loose.
  if [ -f "$DEST/ness-install.sh" ]; then
    ok "already unpacked ($DEST)"
  elif [ -f "$HERE/ness-install.sh" ]; then
    DEST="$HERE"; ok "files are loose in $HERE — using them as-is"
  else
    die "no ness-bundle.tar.gz or .zip found" \
        "looked in $HERE and $HOME — or pass the path: bash $(basename "$0") /path/to/bundle.tar.gz"
  fi
else
  ok "archive: $ARC"

  # ── unpack, with a fallback for boxes that have no unzip ──
  mkdir -p "$DEST" || die "cannot create $DEST"
  tmp=$(mktemp -d) || die "no temp dir"
  case "$ARC" in
    *.tar.gz|*.tgz)
      command -v tar >/dev/null 2>&1 || die "no tar on this machine" "apt install tar"
      tar -xzf "$ARC" -C "$tmp" || die "tar failed on $ARC" ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -qo "$ARC" -d "$tmp" || die "unzip failed on $ARC"
      elif command -v python3 >/dev/null 2>&1; then
        nn "no unzip — using python's zipfile instead"
        python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
          "$ARC" "$tmp" || die "python could not read $ARC"
      else
        die "no unzip and no python3" "install one, or use the .tar.gz"
      fi ;;
    *) die "not a .tar.gz or .zip: $ARC" ;;
  esac

  # The archive contains a ness-bundle/ directory; flatten either shape.
  src="$tmp"
  [ -d "$tmp/ness-bundle" ] && src="$tmp/ness-bundle"
  cp -f "$src"/* "$DEST"/ 2>/dev/null
  rm -rf "$tmp"
  n=$(ls -1 "$DEST" 2>/dev/null | wc -l | tr -d ' ')
  [ -f "$DEST/ness-install.sh" ] || die "unpacked, but no ness-install.sh in $DEST"
  ok "unpacked $n files to $DEST"
fi

# ── gather ness.sh, if it is sitting beside this script ─────
# Unpacking into a subdirectory would otherwise orphan the installer from a
# ness.sh the user downloaded next to go.sh, and it would silently install
# no runner at all.
if [ "$DEST" != "$HERE" ]; then
  for c in "$HERE"/ness.sh "$HERE"/nesssh*.txt "$HERE"/nesssh*.sh; do
    [ -f "$c" ] || continue
    cp -f "$c" "$DEST"/ness.sh 2>/dev/null && ok "brought $(basename "$c") along as ness.sh"
    break
  done
fi

# ── LF endings and exec bits, before anything runs ──────────
cd "$DEST" || die "cannot enter $DEST"
fixed=0
for f in *; do                      # every file, docs included — a CR in a
  [ -f "$f" ] || continue           # .md is harmless but it means the transfer
  if grep -q $'\r' "$f" 2>/dev/null; then   # mangled things, so it goes too
    t=$(mktemp); tr -d '\r' < "$f" > "$t" && mv "$t" "$f"; fixed=$((fixed+1))
  fi
done
for f in *.sh *.py; do [ -f "$f" ] && chmod +x "$f" 2>/dev/null; done
[ "$fixed" -gt 0 ] && ok "stripped CR from $fixed file(s)" || ok "line endings already LF"

# ── prove it parses before running any of it ────────────────
bad=0
for f in *.sh; do [ -f "$f" ] || continue; bash -n "$f" 2>/dev/null || { no "$f does not parse"; bad=1; }; done
if command -v python3 >/dev/null 2>&1; then
  for f in *.py; do [ -f "$f" ] || continue
    python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null \
      || { no "$f does not parse"; bad=1; }
  done
fi
[ "$bad" = 0 ] && ok "every script parses" || die "something in the bundle is damaged" "re-download it"

if [ "$UNPACK_ONLY" = 1 ]; then
  printf '\n  %sunpacked to%s %s\n\n  next: %sbash %s/ness-install.sh%s\n\n' \
    "$D" "$X" "$DEST" "$B" "$DEST" "$X"
  exit 0
fi

# ── hand over ───────────────────────────────────────────────
printf '\n%s  running the installer. It asks before it changes anything —%s\n' "$D" "$X"
printf '%s  type repair, fix and path in full when offered.%s\n' "$D" "$X"
exec bash "$DEST/ness-install.sh"