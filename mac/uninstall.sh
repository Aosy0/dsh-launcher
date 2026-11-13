#!/bin/bash
# Remove the app, the CLI wrapper, and the per-machine LaunchAgents created by
# the launcher. Personal data (hosts.json, logs, the dsh installation itself) is
# kept unless --purge is given.
#
#   ./uninstall.sh
#   ./uninstall.sh --purge
set -euo pipefail

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            echo "usage: $0 [--purge]"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

APP="${DEST_APP:-$HOME/Applications/DSH Launcher.app}"
CLI="${CLI_DIR:-$HOME/.local/bin}/dshl"
AGENTS="$HOME/Library/LaunchAgents"
SUPPORT="$HOME/Library/Application Support/DshLauncher"

# Stop every local dsh that the launcher owns before deleting its plist.
if [ -d "$AGENTS" ]; then
    for plist in "$AGENTS"/io.github.aosy0.dshlauncher.start-*.plist; do
        [ -e "$plist" ] || continue
        label="$(basename "$plist" .plist)"
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        rm -f "$plist"
        echo "stopped: $label"
    done
fi

rm -rf "$APP"
rm -f "$CLI"
echo "removed: $APP"
echo "removed: $CLI"

if [ "$PURGE" -eq 1 ]; then
    rm -rf "$SUPPORT"
    echo "removed: $SUPPORT"
else
    echo "kept:    $SUPPORT (設定・ログ。消すなら --purge)"
fi
