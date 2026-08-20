# ── the mesh ────────────────────────────────────────────────
# Drop-in section for ness.sh v2.8. Sits alongside the skywire block that
# already wraps `skywire-cli vpn *`, and extends it from "am I connected"
# to "whose deployment am I connected THROUGH".
#
# The rules of the rest of the file apply here without exception:
#
#   * No fabricated values. Every figure is read from a config on this
#     disk or from a service that answered. A service that did not answer
#     is `not observed`, never a zero.
#   * One call per fact, cached for the run. `svc health` is ONE fork that
#     covers six services. Asking per service is how a screen takes ten
#     seconds to draw on Git Bash.
#   * Negation checked FIRST and it wins. "DOWN" contains no substring of
#     "OK", but "not registered" contains "registered", and that is exactly
#     the shape that manufactures a false green.
#   * Cryptographic material renders in full. Two keys can share any prefix,
#     so an elided key cannot be compared.
#   * A service reporting its own version is REPORTED. A service answering
#     at all, measured from here, is VERIFIED. They are not the same claim
#     and they do not get the same mark.

# `mesh` joins chain/visor/wire/keys/conf as a source. It means: a
# deployment service answered us directly.
# Add to src_tag():   mesh)  printf '%s[mesh ]%s' "$C" "$X" ;;

SKYD="${NESS_SKYWIRE:-skywire}"          # the unified binary; skywire-cli is a subcommand
sky_bin(){ command -v "$SKYD" >/dev/null 2>&1; }

# ── whose deployment is this? ───────────────────────────────
# SKYDEPLOY replaces the embedded services-config.json for EVERY skywire
# binary at init (deployment/config_native.go). Unset means you are on
# Skycoin's deployment. That is a fact about your network, not a detail,
# and it is stated rather than left to be assumed.
mesh_deploy(){
  local f="${SKYDEPLOY:-}"
  if [ -z "$f" ]; then
    obs deploy conf claimed "SKYDEPLOY unset — the embedded (Skycoin) deployment"
    return 0
  fi
  if [ ! -r "$f" ]; then
    obs deploy conf failed "SKYDEPLOY=$f — set, but this file cannot be read" \
        "every skywire binary will panic at init until it can"
    return 1
  fi
  local py n_srv dd
  py=$(find_py) || { obs deploy conf claimed "SKYDEPLOY=$f — present, not parsed (no python)"; return 0; }
  # Read the file, do not describe it. If it will not parse, say so.
  read -r n_srv dd <<EOF
$("$py" -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print("ERR",str(e).replace(" ","_")); sys.exit()
e=d.get("prod") or d.get("test") or {}
print(len(e.get("dmsg_servers",[])), e.get("dmsg_discovery_dmsg","-"))
' "$f" 2>/dev/null)
EOF
  case "$n_srv" in
    ERR|"") obs deploy conf failed "SKYDEPLOY=$f — not valid deployment JSON" "$dd" ; return 1 ;;
  esac
  # minsess defaults to 2. One server is a deployment that never reaches its
  # own session target, and it fails quietly rather than loudly.
  if [ "$n_srv" -lt 2 ]; then
    obs deploy conf failed \
      "your deployment: $n_srv dmsg server(s) — below the default --minsess 2" \
      "visors will sit permanently under target. Add a server, or lower minsess deliberately."
  else
    obs deploy conf claimed "your deployment: $n_srv dmsg servers, dmsgd $dd"
  fi
  return 0
}

# ── one call, six services ──────────────────────────────────
# `skywire cli svc health` prints STATUS LATENCY PROTOCOL VERSION PK for
# every deployment service. Parsed once into a table, read many times.
MTMP="${TMPDIR:-/tmp}/ness-mesh.$$"
mesh_load(){
  [ -f "$MTMP/health.tsv" ] && return 0
  mkdir -p "$MTMP" 2>/dev/null; chmod 700 "$MTMP" 2>/dev/null
  sky_bin || { : > "$MTMP/health.tsv"; return 1; }
  # Never let a hung service hold the whole screen. No timeout command on
  # some platforms, so the absence of one is tolerated rather than fatal.
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 "$SKYD" cli svc health 2>/dev/null
  else
    "$SKYD" cli svc health 2>/dev/null
  fi | awk 'NR>1 && NF>=3 {
        # service name may contain spaces; status is the first ALL-CAPS field
        st=""; for(i=1;i<=NF;i++) if($i=="OK"||$i=="DOWN"||$i=="ERROR"){st=i;break}
        if(st==0||st=="") next
        name=""; for(i=1;i<st;i++) name=name (i>1?" ":"") $i
        printf "%s\t%s\t%s\t%s\t%s\n", name, $st, $(st+1), $(st+2), $(st+3)
      }' > "$MTMP/health.tsv" 2>/dev/null
  return 0
}
mesh_field(){ # mesh_field <service-name-prefix> <col 2=status 3=lat 4=proto 5=ver 6=pk>
  mesh_load || return 1
  awk -F'\t' -v n="$1" -v c="$2" 'index($1,n)==1{print $(c-1); exit}' "$MTMP/health.tsv"
}

# The negation rule, applied. "DOWN" is checked before "OK" is looked for,
# and an empty status is not a pass — it is silence.
mesh_is_ok(){
  local st="$1"
  [ -n "$st" ] || return 1
  case "$st" in *DOWN*|*ERROR*|*FAIL*) return 1 ;; esac
  case "$st" in *OK*) return 0 ;; esac
  return 1
}

# One row per service. Reachability is measured from here, so it is
# VERIFIED. The version string is whatever the service said about itself,
# so wherever it is shown it is REPORTED and labelled as such.
mesh_services(){
  local id name st lat proto ver pk
  mesh_load || { obs mesh "" absent "no $SKYD on this machine"; return 1; }
  if [ ! -s "$MTMP/health.tsv" ]; then
    obs mesh "" absent "$SKYD is here but svc health returned nothing"
    return 1
  fi
  while IFS=$'\t' read -r name st lat proto ver pk; do
    [ -n "$name" ] || continue
    id="svc_$(printf '%s' "$name" | tr 'A-Z ' 'a-z_')"
    if mesh_is_ok "$st"; then
      # full key, always — a prefix cannot be compared against anything
      obs "$id" mesh verified "$name — answered over $proto in $lat" \
          "${pk:+pk $pk}${ver:+ · reports version $ver}"
    else
      obs "$id" mesh failed "$name — $st over ${proto:-?}" \
          "${pk:+pk $pk}"
    fi
  done < "$MTMP/health.tsv"
}

# ── dmsg: configured vs actually sessioned ──────────────────
# The gap between these two numbers is the whole story. A config listing
# nine servers and a visor holding one session is not a healthy mesh, and
# nothing else on the screen would have said so.
mesh_dmsg(){
  sky_bin || { obs dmsg "" absent "no $SKYD on this machine"; return 1; }
  local listed sessions
  listed=$("$SKYD" cli svc dmsgd all-servers 2>/dev/null | grep -cE '[0-9a-f]{66}')
  sessions=$("$SKYD" cli dmsg 2>/dev/null | grep -cE '[0-9a-f]{66}')
  if [ "${listed:-0}" -eq 0 ]; then
    obs dmsg "" absent "dmsg-discovery did not list any servers"
    return 1
  fi
  if [ "${sessions:-0}" -eq 0 ]; then
    obs dmsg mesh failed "$listed servers listed, this visor holds 0 sessions" \
        "nothing that rides dmsg will work — not the mount, not chunk-serve, not skychat"
  elif [ "${sessions:-0}" -lt 2 ]; then
    obs dmsg mesh failed "$listed servers listed, $sessions session held" \
        "default --minsess is 2; one session is one restart away from none"
  else
    obs dmsg mesh verified "$sessions sessions held, of $listed servers listed"
  fi
}

# ── the visor itself ────────────────────────────────────────
mesh_visor(){
  local pk
  sky_bin || { obs visor "" absent "no $SKYD on this machine"; return 1; }
  pk=$("$SKYD" cli visor pk 2>/dev/null | grep -oE '[0-9a-f]{66}' | head -1)
  if [ -z "$pk" ]; then
    obs visor "" absent "$SKYD is here but no visor answered"
    return 1
  fi
  obs visor visor verified "this machine is $pk"
  # The PK in the three encodings that matter, because they are not
  # interchangeable and choosing wrong is a silent interop failure.
  local py b32 b64
  if py=$(find_py); then
    read -r b32 b64 <<EOF
$("$py" -c '
import base64,sys
raw=bytes.fromhex(sys.argv[1])
print(base64.b32encode(raw).decode().lower().rstrip("="), base64.b64encode(raw).decode())
' "$pk" 2>/dev/null)
EOF
    [ -n "$b32" ] && obs visor_enc conf claimed \
      "label form (base32, DNS-legal): $b32" \
      "TXT/PTR form (base64, NOT a legal label): $b64"
  fi
}

# ── the one screen ──────────────────────────────────────────
cmd_mesh(){
  banner
  head_ "whose deployment"
  mesh_deploy
  printf '  %s %s\n' "$(src_tag conf)" "${OBS_DET[deploy]}"
  [ "$(obs_chk deploy)" = failed ] && note "${OBS_MORE[deploy]}"

  head_ "this visor"
  mesh_visor
  local row
  for row in visor visor_enc; do
    [ "$(obs_chk "$row")" = absent ] && continue
    printf '  %s %s ' "$(src_tag "$(obs_src "$row")")" "$(mark "$(obs_chk "$row")")"
    printf '%s\n' "${OBS_DET[$row]}"
    [ -n "${OBS_MORE[$row]:-}" ] && note "${OBS_MORE[$row]}"
  done

  head_ "deployment services"
  note "reachability measured from here. Versions are what each service says of itself."
  mesh_services
  local id
  for id in $OBS_ORDER; do
    case "$id" in svc_*) ;; *) continue ;; esac
    printf '  %s ' "$(src_tag mesh)"
    mark "$(obs_chk "$id")"
    printf ' %s\n' "${OBS_DET[$id]}"
    [ -n "${OBS_MORE[$id]:-}" ] && note "${OBS_MORE[$id]}"
  done

  head_ "dmsg"
  mesh_dmsg
  if [ "$(obs_chk dmsg)" != absent ]; then
    printf '  %s ' "$(src_tag mesh)"; mark "$(obs_chk dmsg)"; printf ' %s\n' "${OBS_DET[dmsg]}"
    [ -n "${OBS_MORE[dmsg]:-}" ] && note "${OBS_MORE[dmsg]}"
  else
    note "${OBS_DET[dmsg]}"
  fi

  # The census, last, the way status does it: you should know how much of
  # what you just read was checked.
  local n=0 ok=0 bad=0
  for id in $OBS_ORDER; do
    case "$(obs_chk "$id")" in
      absent) continue ;;
      verified) ok=$((ok+1)); n=$((n+1)) ;;
      failed)   bad=$((bad+1)); n=$((n+1)) ;;
      *)        n=$((n+1)) ;;
    esac
  done
  say ""
  if [ "$bad" -gt 0 ]; then
    printf '  %s%s of %s mesh observations FAILED their check.%s\n' "$R" "$bad" "$n" "$X"
  else
    printf '  %s%s of %s mesh observations were recomputed here.%s\n' "$D" "$ok" "$n" "$X"
  fi
  echo
}

# Wire-up, three lines elsewhere in the file:
#   MENU_LABEL+=("Mesh");  MENU_ACT+=("mesh")      # in menu_build, under Connect
#   mesh) cmd_mesh ;;                              # in menu_run
#   mesh) shift; cmd_mesh "$@" ;;                  # in the arg dispatcher
#
# And in menu_states, from the cache rather than a fresh fork:
#   mesh) if [ -n "$cache_sky" ]; then MENU_STATE+=("${D}${cache_deploy:-embedded} deployment${X}")
#         else MENU_STATE+=("${D}no visor here${X}"); fi ;;
#
# The sixth hexbar cell (`served`) gains an obvious new lighting condition:
# a visor holding >=2 dmsg sessions is serving reachability whether or not
# anything is registered on chain yet.
