#!/usr/bin/env python3
"""PrivateNESS real-only dashboard runtime.

- Collects observed local service / transport / listener state.
- Serves the dashboard on loopback only.
- Provides an authenticated local KILL endpoint for listening processes.
- Can write a static JSON snapshot for file-only use.

No fake data is generated. Missing observations remain missing/false.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import http.server
import json
import os
import pathlib
import platform
import re
import secrets
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timezone
from typing import Any

BASE_DIR = pathlib.Path(__file__).resolve().parent
HTML_PATH = BASE_DIR / "ness_dashboard_real.html"
TRUST_ROOT = "dpo:PrivateNESS.Network"


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd: list[str], timeout: float = 3.0) -> tuple[int, str, str]:
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return cp.returncode, (cp.stdout or "").strip(), (cp.stderr or "").strip()
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as exc:
        return 127, "", str(exc)


def http_get(url: str) -> tuple[bool, int | None, str]:
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return True, getattr(response, "status", 200), response.read(320).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(320).decode("utf-8", "replace")
        except Exception:
            body = ""
        # An HTTP response proves a listener exists, even if health is unhappy.
        return True, exc.code, body
    except Exception as exc:
        return False, None, str(exc)


def tcp_open(host: str, port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(1.2)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def process_cmdline(pid: int) -> dict[str, Any]:
    info: dict[str, Any] = {"pid": pid, "cmdline": "", "exe": "", "user": ""}
    if pid <= 0:
        return info
    if os.name == "nt":
        # WMIC exists on many Git Bash/Windows installations. No PowerShell dependency.
        if shutil.which("wmic"):
            rc, out, _ = run([
                "wmic", "process", "where", f"processid={pid}",
                "get", "CommandLine,ExecutablePath,Name,ProcessId", "/format:list"
            ], timeout=4)
            if rc == 0:
                vals = {}
                for line in out.splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        vals[k.strip()] = v.strip()
                info["cmdline"] = vals.get("CommandLine", "")
                info["exe"] = vals.get("ExecutablePath", "") or vals.get("Name", "")
        if not info["cmdline"] and shutil.which("tasklist"):
            rc, out, _ = run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"])
            if rc == 0:
                info["cmdline"] = out.splitlines()[0] if out else ""
        return info

    proc = pathlib.Path("/proc") / str(pid)
    try:
        raw = (proc / "cmdline").read_bytes()
        info["cmdline"] = raw.replace(b"\x00", b" ").decode("utf-8", "replace").strip()
    except Exception:
        pass
    try:
        info["exe"] = os.readlink(proc / "exe")
    except Exception:
        pass
    try:
        st = (proc / "status").read_text(errors="replace")
        m = re.search(r"^Uid:\s+(\d+)", st, re.M)
        if m:
            import pwd
            info["user"] = pwd.getpwuid(int(m.group(1))).pw_name
    except Exception:
        pass
    if not info["cmdline"]:
        rc, out, _ = run(["ps", "-p", str(pid), "-o", "args="])
        if rc == 0:
            info["cmdline"] = out.strip()
    return info


def listeners_linux() -> list[dict[str, Any]]:
    rc, out, _ = run(["ss", "-H", "-lntup"], timeout=4)
    if rc != 0:
        rc, out, _ = run(["ss", "-H", "-lntp"], timeout=4)
    rows: list[dict[str, Any]] = []
    if rc != 0 or not out:
        return rows
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        proto = parts[0]
        # ss output: Netid State Recv-Q Send-Q Local:Port Peer:Port Process
        bind = parts[4] if len(parts) >= 6 and parts[1].upper() in {"LISTEN", "UNCONN"} else parts[3]
        if bind.startswith("[") and "]:" in bind:
            addr, port = bind.rsplit(":", 1)
        elif ":" in bind:
            addr, port = bind.rsplit(":", 1)
        else:
            addr, port = bind, ""
        pid_match = re.search(r"pid=(\d+)", line)
        name_match = re.search(r'\("([^\"]+)"', line)
        pid = int(pid_match.group(1)) if pid_match else None
        proc = process_cmdline(pid) if pid else {"cmdline": "", "exe": "", "user": ""}
        rows.append({
            "proto": proto,
            "addr": addr,
            "port": port,
            "pid": pid,
            "process": name_match.group(1) if name_match else "",
            "cmdline": proc.get("cmdline", ""),
            "exe": proc.get("exe", ""),
            "user": proc.get("user", ""),
            "raw": line,
        })
    return rows


def listeners_windows() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    rc, out, _ = run(["netstat", "-ano"], timeout=5)
    if rc != 0:
        return rows
    for line in out.splitlines():
        s = line.strip()
        if not s or not (s.startswith("TCP") or s.startswith("UDP")):
            continue
        parts = s.split()
        proto = parts[0].lower()
        if proto == "tcp":
            if len(parts) < 5 or parts[3].upper() != "LISTENING":
                continue
            bind, pid_s = parts[1], parts[4]
        else:
            if len(parts) < 4:
                continue
            bind, pid_s = parts[1], parts[-1]
        try:
            pid = int(pid_s)
        except ValueError:
            pid = None
        addr, port = bind.rsplit(":", 1) if ":" in bind else (bind, "")
        proc = process_cmdline(pid) if pid else {}
        rows.append({
            "proto": proto,
            "addr": addr,
            "port": port,
            "pid": pid,
            "process": pathlib.Path(proc.get("exe", "")).name if proc.get("exe") else "",
            "cmdline": proc.get("cmdline", ""),
            "exe": proc.get("exe", ""),
            "user": proc.get("user", ""),
            "raw": s,
        })
    return rows


def listeners_fallback() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if shutil.which("lsof"):
        rc, out, _ = run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout=5)
        if rc == 0:
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) < 9:
                    continue
                try:
                    pid = int(parts[1])
                except ValueError:
                    continue
                bind = parts[-2] if "->" not in parts[-1] else parts[-1].split("->",1)[0]
                addr, port = bind.rsplit(":",1) if ":" in bind else (bind,"")
                proc = process_cmdline(pid)
                rows.append({"proto":"tcp","addr":addr,"port":port,"pid":pid,"process":parts[0],"cmdline":proc.get("cmdline",""),"exe":proc.get("exe",""),"user":proc.get("user",""),"raw":line})
    return rows


def get_listeners() -> list[dict[str, Any]]:
    if os.name == "nt":
        rows = listeners_windows()
    elif sys.platform.startswith("linux"):
        rows = listeners_linux()
    else:
        rows = listeners_fallback()
    # deterministic ordering helps humans compare snapshots
    def key(r: dict[str, Any]):
        p = str(r.get("port") or "")
        return (r.get("proto") or "", int(p) if p.isdigit() else 999999, r.get("addr") or "")
    return sorted(rows, key=key)


def process_search(process_names: list[str], arg_regex: str | None = None) -> list[dict[str, Any]]:
    """Find real processes without treating arbitrary shell arguments as service evidence."""
    matches: list[dict[str, Any]] = []
    names = [n.lower() for n in process_names]
    if os.name == "nt":
        rc, out, _ = run(["tasklist", "/FO", "CSV", "/NH"], timeout=5)
        if rc == 0:
            import csv, io
            for row in csv.reader(io.StringIO(out)):
                if len(row) < 2:
                    continue
                image = row[0]
                try:
                    pid = int(row[1])
                except ValueError:
                    continue
                low = image.lower().removesuffix('.exe')
                info = process_cmdline(pid)
                matched = any(low == n or low.startswith(n + '-') for n in names)
                if not matched and arg_regex:
                    matched = re.search(arg_regex, info.get("cmdline", ""), re.I) is not None
                if matched:
                    matches.append({"pid": pid, "name": image, "cmdline": info.get("cmdline", "")})
        return matches

    rc, out, _ = run(["ps", "-eo", "pid=,comm=,args="], timeout=5)
    if rc == 0:
        for line in out.splitlines():
            m = re.match(r"\s*(\d+)\s+(\S+)\s+(.*)", line)
            if not m:
                continue
            pid, comm, args = int(m.group(1)), m.group(2), m.group(3)
            low = pathlib.Path(comm).name.lower()
            matched = any(low == n or low.startswith(n + '-') for n in names)
            if not matched and arg_regex:
                # Argument matching is intentionally narrow, for Java-style I2P launches.
                matched = re.search(arg_regex, args, re.I) is not None and low in {"java", "i2prouter", "i2p"}
            if matched:
                matches.append({"pid": pid, "name": comm, "cmdline": args})
    return matches


def transport_status(name: str, mandatory: bool, binaries: list[str], process_patterns: list[str], probe: list[str] | None = None) -> dict[str, Any]:
    binary = next((shutil.which(b) for b in binaries if shutil.which(b)), None)
    processes = process_search(process_patterns, r"(?:^|[\\/ ])i2p(?:[\\/ .-]|$)" if name == "I2P" else None)
    probe_out = ""
    probe_ok: bool | None = None
    if probe and binary:
        cmd = [binary] + probe[1:] if probe[0] in binaries else probe
        rc, out, err = run(cmd, timeout=4)
        probe_ok = rc == 0
        probe_out = (out or err)[:500]
    running = bool(processes)
    # A successful control probe is stronger evidence than process-name matching.
    ok = True if probe_ok is True else running
    return {
        "name": name,
        "mandatory": mandatory,
        "ok": ok,
        "binary": binary or "",
        "running": running,
        "processes": processes[:8],
        "probe_ok": probe_ok,
        "probe_output": probe_out,
    }


def skywire_status() -> dict[str, Any]:
    binary = shutil.which("skywire")
    processes = process_search(["skywire", "skywire-visor", "visor"])
    pk = ""
    probe_ok: bool | None = None
    probe_output = ""
    if binary:
        rc, out, err = run([binary, "cli", "visor", "pk"], timeout=5)
        probe_ok = rc == 0 and bool(out.strip())
        probe_output = (out or err)[:500]
        if probe_ok:
            pk = out.strip().splitlines()[-1].strip()
    running = bool(processes)
    return {
        "name": "Skywire",
        "mandatory": True,
        "ok": True if probe_ok else running,
        "binary": binary or "",
        "running": running,
        "processes": processes[:8],
        "probe_ok": probe_ok,
        "probe_output": probe_output,
        "public_key": pk,
    }


def collect_state() -> dict[str, Any]:
    events: list[dict[str, str]] = []
    def add(level: str, message: str):
        events.append({"timestamp": utcnow(), "level": level, "message": message})

    checks: dict[str, Any] = {}
    ok, code, body = http_get("http://127.0.0.1:6660/api/v1/health")
    checks["ness_http_health"] = {
        "ok": ok,
        "endpoint": "http://127.0.0.1:6660/api/v1/health",
        "http_code": code,
        "note": "HTTP health endpoint responded" if ok else "No HTTP response observed",
        "body_excerpt": body.replace("\n", " ")[:320],
    }
    add("ok" if ok else "warn", f"PrivateNESS daemon health endpoint {'responded' if ok else 'did not respond'} on 127.0.0.1:6660")

    emc = tcp_open("127.0.0.1", 6662)
    checks["emercoin_rpc"] = {"ok": emc, "endpoint":"127.0.0.1:6662", "http_code":None, "note":"TCP port reachable" if emc else "TCP port not reachable", "body_excerpt":""}
    add("ok" if emc else "warn", f"Emercoin RPC {'reachable' if emc else 'not reachable'} at 127.0.0.1:6662")

    sock_path = pathlib.Path("/run/ness402d.sock")
    sock_ok = False
    try:
        sock_ok = sock_path.exists() and sock_path.is_socket()
    except OSError:
        pass
    checks["ness402_socket"] = {"ok":sock_ok,"endpoint":"unix:///run/ness402d.sock","http_code":None,"note":"Unix socket exists" if sock_ok else "Unix socket not present","body_excerpt":""}
    add("ok" if sock_ok else "info", f"ness402d socket {'present' if sock_ok else 'not observed'} at /run/ness402d.sock")

    docker_binary = shutil.which("docker")
    if docker_binary:
        rc, out, err = run([docker_binary,"ps","--format","{{.Names}} {{.Status}}"], timeout=4)
        docker_ok = rc == 0
        excerpt = " | ".join(out.splitlines()[:5]) if out else err[:220]
    else:
        docker_ok = False; excerpt = "docker executable not found"
    checks["docker"] = {"ok":docker_ok,"endpoint":"docker ps","http_code":None,"note":"Docker available" if docker_ok else "Docker unavailable or daemon unreachable","body_excerpt":excerpt}

    transports = {
        "skywire": skywire_status(),
        "yggdrasil": transport_status("Yggdrasil", False, ["yggdrasil","yggdrasilctl"], ["yggdrasil"], None),
        "i2p": transport_status("I2P", False, ["i2prouter","i2p"], ["i2p","i2prouter"], None),
        "tor": transport_status("Tor", False, ["tor"], ["tor"], ["tor","--version"]),
    }
    sky = transports["skywire"]
    add("ok" if sky["ok"] else "bad", "Skywire mandatory transport observed" if sky["ok"] else "Skywire mandatory transport NOT observed")
    for key in ("yggdrasil","i2p","tor"):
        tr = transports[key]
        add("info", f"{tr['name']} optional transport {'observed' if tr['ok'] else 'not observed'}")

    chain: dict[str, Any] = {}
    candidate_paths = [os.path.expanduser("~/.emercoin/emercoin.conf")]
    appdata = os.environ.get("APPDATA")
    if appdata:
        candidate_paths.append(os.path.join(appdata, "Emercoin", "emercoin.conf"))
    for p in candidate_paths:
        if os.path.isfile(p):
            chain["config_path"] = p
            add("info", f"Emercoin config observed at {p}")
            break

    listeners = get_listeners()
    mandatory_ready = bool(transports["skywire"]["ok"])
    return {
        "generated_at": utcnow(),
        "trust_root": TRUST_ROOT,
        "host": {"hostname": socket.gethostname(), "platform": platform.platform(), "user": getpass.getuser()},
        "checks": checks,
        "transports": transports,
        "mandatory_ready": mandatory_ready,
        "listeners": listeners,
        "chain": chain,
        "wallet": {},
        "agents": [],
        "events": events,
    }


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    server_version = "NESSDashboard/0.3"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("ness-dashboard: " + (fmt % args) + "\n")

    @property
    def runtime(self) -> "DashboardRuntime":
        return self.server.runtime  # type: ignore[attr-defined]

    def _json(self, code: int, data: Any) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _html(self) -> None:
        if not HTML_PATH.exists():
            self.send_error(404, "ness_dashboard_real.html missing")
            return
        payload = HTML_PATH.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/ness_dashboard_real.html"):
            self._html(); return
        if path in ("/api/state", "/ness-dashboard-state.json"):
            state = collect_state()
            state["manager"] = {"available": True, "token": self.runtime.token, "pid": os.getpid(), "bind": self.runtime.url}
            self._json(200, state); return
        if path == "/api/health":
            self._json(200, {"ok": True, "pid": os.getpid(), "url": self.runtime.url}); return
        self.send_error(404)

    def do_POST(self) -> None:
        path = self.path.split("?",1)[0]
        if path != "/api/kill":
            self.send_error(404); return
        token = self.headers.get("X-NESS-Admin-Token", "")
        if not secrets.compare_digest(token, self.runtime.token):
            self._json(403, {"ok":False,"error":"invalid admin token"}); return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(length, 8192)) or b"{}")
            pid = int(body.get("pid"))
        except Exception:
            self._json(400, {"ok":False,"error":"invalid pid"}); return
        if pid <= 2 or pid in {os.getpid(), os.getppid()}:
            self._json(403, {"ok":False,"error":"refusing protected pid"}); return
        current = collect_state()["listeners"]
        allowed = {int(x["pid"]) for x in current if x.get("pid")}
        if pid not in allowed:
            self._json(409, {"ok":False,"error":"pid is not currently observed as a listener"}); return
        try:
            detail = process_cmdline(pid)
            if os.name == "nt":
                cp = subprocess.run(["taskkill","/PID",str(pid),"/T"], capture_output=True, text=True, timeout=5)
                if cp.returncode != 0:
                    raise RuntimeError((cp.stderr or cp.stdout or "taskkill failed").strip())
                action = "taskkill /T"
            else:
                os.kill(pid, signal.SIGTERM)
                action = "SIGTERM"
            self._json(200, {"ok":True,"pid":pid,"action":action,"cmdline":detail.get("cmdline","")})
        except ProcessLookupError:
            self._json(410, {"ok":False,"error":"process already exited"})
        except PermissionError:
            self._json(403, {"ok":False,"error":"permission denied; run dashboard manager with sufficient privilege to terminate this process"})
        except Exception as exc:
            self._json(500, {"ok":False,"error":str(exc)})


class DashboardRuntime:
    def __init__(self, host: str, port: int):
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("dashboard manager only binds loopback")
        self.token = secrets.token_urlsafe(32)
        self.server = ThreadingHTTPServer((host, port), DashboardHandler)
        self.server.runtime = self  # type: ignore[attr-defined]
        actual_port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{actual_port}/"

    def serve(self, open_browser: bool) -> None:
        print(f"NESS dashboard: {self.url}")
        print("Loopback only. Ctrl-C to stop.")
        if open_browser:
            threading.Timer(0.5, lambda: webbrowser.open(self.url)).start()
        try:
            self.server.serve_forever(poll_interval=0.4)
        except KeyboardInterrupt:
            pass
        finally:
            self.server.server_close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", metavar="FILE", help="write one real observation snapshot and exit")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="loopback port; 0 chooses an available high/random OS port")
    ap.add_argument("--open", action="store_true", help="open dashboard in default browser")
    args = ap.parse_args()
    if args.snapshot:
        pathlib.Path(args.snapshot).write_text(json.dumps(collect_state(), indent=2), encoding="utf-8")
        print(f"Wrote {args.snapshot}")
        return 0
    runtime = DashboardRuntime(args.host, args.port)
    runtime.serve(args.open)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
