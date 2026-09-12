#!/usr/bin/bash
# Copy this repo into Omarchy's plugin directory so the live shell can load it.
set -euo pipefail
export PATH=/usr/bin:/bin
ROOT="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
ID="$(/usr/bin/jq -r .id "$ROOT/manifest.json")"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
/usr/bin/mkdir -p "$DEST"
/usr/bin/rsync -a --delete --exclude '.git/' --exclude 'install-local.sh' "$ROOT/" "$DEST/"
/usr/bin/chmod +x "$DEST/omarchy64-ctl" "$DEST/omarchy64-fs.py" "$DEST/omarchy64-run.py"
"$DEST/omarchy64-ctl" ensure-rules >/dev/null
echo "Installed $ID -> $DEST"
