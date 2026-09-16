#!/usr/bin/bash
# Copy this repo into Omarchy's plugin directory so the live shell can load it.
# Walk, copy, delete, and controller exec stay on retained O_NOFOLLOW
# directory fds; pathnames are not used after the destination is opened.
set -euo pipefail
export PATH=/usr/bin:/bin
unset PYTHONPATH PYTHONHOME PYTHONUSERBASE BASH_ENV ENV LD_PRELOAD PERL5LIB PERL5OPT
ROOT="$(cd "$(/usr/bin/dirname "$0")" && /usr/bin/pwd -P)"
DEST="$(/usr/bin/python3 -I -S "$ROOT/omarchy64-fs.py" install-plugin "$ROOT")"
# Plugin file-watch reload reuses the existing QML component for the same
# URL, so the bar keeps showing the previous Panel.qml until the shell
# process is replaced.
if /usr/bin/omarchy restart shell >/dev/null; then
  echo "Installed $DEST (shell restarted)"
else
  echo "Installed $DEST (restart the shell to load Panel.qml)"
fi
