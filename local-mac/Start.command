#!/bin/bash
set -e
cd "$(dirname "$0")"
if [ "$(uname -m)" != arm64 ]; then
  echo "This version requires an Apple Silicon Mac."
  read -r -p "Press Return to close."; exit 1
fi
trap 'echo "Setup or startup failed. Read the error above."; read -r -p "Press Return to close."' ERR
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
if [ ! -f .venv/ether-installed ] || ! cmp -s requirements.txt .venv/ether-installed; then
  echo "Installing local voice dependencies. Internet access is required for setup."
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt
  cp requirements.txt .venv/ether-installed
fi
export HF_HOME="$PWD/private-data/model-cache"
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
.venv/bin/python server.py &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
for attempt in {1..30}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "Server did not start. Another app may be using port 8765."
    read -r -p "Press Return to close."; exit 1
  fi
  if /usr/bin/curl -fsS http://127.0.0.1:8765/api/status >/dev/null 2>&1; then
    open http://127.0.0.1:8765
    break
  fi
  sleep 1
done
wait "$server_pid"
