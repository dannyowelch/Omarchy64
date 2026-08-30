#!/usr/bin/env bash
# Copy this repo into Omarchy's plugin directory so the live shell can load it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ID="$(jq -r .id "$ROOT/manifest.json")"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
mkdir -p "$DEST"
rsync -a --delete --exclude '.git/' --exclude 'install-local.sh' "$ROOT/" "$DEST/"
chmod +x "$DEST/omarchy64-ctl"
"$DEST/omarchy64-ctl" ensure-rules >/dev/null
echo "Installed $ID -> $DEST"
