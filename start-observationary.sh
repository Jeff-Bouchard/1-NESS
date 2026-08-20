#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=""
if command -v python3 >/dev/null 2>&1; then PY="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then PY="$(command -v python)"
else echo "python3 or python required" >&2; exit 1
fi
exec "$PY" "$HERE/ness_dashboard_manage.py" --host 127.0.0.1 --port 0 --open
