#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROUTER_HOME="$HOME/.config/laya-opencode-router"
OPENCODE_CONFIG_DIR=${OPENCODE_CONFIG_DIR:-"$HOME/.config/opencode"}
PLUGIN_LINK="$OPENCODE_CONFIG_DIR/plugins/laya-router"
AGENT="$HOME/Library/LaunchAgents/com.laya-opencode.router.plist"
PYTHON=${PYTHON:-python3}

"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'
command -v swiftc >/dev/null 2>&1 || { echo "swiftc is required" >&2; exit 1; }

mkdir -p "$ROUTER_HOME" "$OPENCODE_CONFIG_DIR/plugins" "$HOME/Library/LaunchAgents"
if [ ! -e "$ROUTER_HOME/settings.json" ]; then
  cp "$REPO/settings.example.json" "$ROUTER_HOME/settings.json"
fi
if [ -e "$PLUGIN_LINK" ] || [ -L "$PLUGIN_LINK" ]; then
  if [ "$(readlink "$PLUGIN_LINK")" != "$REPO/plugin" ]; then
    echo "Plugin path already exists: $PLUGIN_LINK" >&2
    exit 1
  fi
else
  ln -s "$REPO/plugin" "$PLUGIN_LINK"
fi

if [ ! -x "$ROUTER_HOME/.venv/bin/python" ]; then
  "$PYTHON" -m venv "$ROUTER_HOME/.venv"
fi
"$ROUTER_HOME/.venv/bin/python" -m pip install 'laya[serve]==0.3.20'
"$ROUTER_HOME/.venv/bin/python" -c 'import fastapi, uvicorn; from laya.serve import create_app'

APP="$ROUTER_HOME/Laya Router.app"
mkdir -p "$APP/Contents/MacOS"
swiftc "$REPO/control/Control.swift" -framework AppKit -o "$APP/Contents/MacOS/Laya Router"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.laya-opencode.router-control</string>
<key>CFBundleName</key><string>Laya Router</string>
<key>CFBundleExecutable</key><string>Laya Router</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

"$PYTHON" - "$AGENT" "$ROUTER_HOME" "$REPO" <<'PY'
import plistlib
import sys
from pathlib import Path

agent, home, repo = map(Path, sys.argv[1:])
value = {
    "Label": "com.laya-opencode.router",
    "ProgramArguments": [str(home / ".venv/bin/python"), str(repo / "service/idle_server.py")],
    "EnvironmentVariables": {
        "HF_HOME": str(home / "hf-cache"),
        "LAYA_DEVICE": "mps",
        "LAYA_HOST": "127.0.0.1",
        "LAYA_PORT": "8766",
        "LAYA_PRELOAD": "0",
        "LAYA_IDLE_SECONDS": "90",
    },
    "RunAtLoad": False,
    "KeepAlive": False,
    "StandardOutPath": str(home / "serve.log"),
    "StandardErrorPath": str(home / "serve-error.log"),
}
with agent.open("wb") as output:
    plistlib.dump(value, output)
PY

echo "Installed. Edit $ROUTER_HOME/settings.json and enable routing in /laya."
echo "Restart the OpenCode background service before using /laya."
