#!/bin/bash
# Install the built app into ~/Applications and create a `dshl` wrapper.
#
#   ./build.sh && ./install.sh
#   DEST_APP="$HOME/Applications/DSH Launcher.app" ./install.sh
#
# The app is unsigned (ad-hoc). It stays in the user's home directory; nothing
# is written to /Applications or /usr/local and no sudo is needed.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
SOURCE_APP="$ROOT/dist/DSH Launcher.app"
DEST_APP="${DEST_APP:-$HOME/Applications/DSH Launcher.app}"
CLI_DIR="${CLI_DIR:-$HOME/.local/bin}"

if [ ! -d "$SOURCE_APP" ]; then
    echo "error: $SOURCE_APP がありません。先に ./build.sh を実行してください。" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST_APP")" "$CLI_DIR"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

cat > "$CLI_DIR/dshl" <<EOF
#!/bin/sh
exec "$DEST_APP/Contents/MacOS/DshLauncher" "\$@"
EOF
chmod +x "$CLI_DIR/dshl"

echo "installed: $DEST_APP"
echo "cli:       $CLI_DIR/dshl"
case ":$PATH:" in
    *":$CLI_DIR:"*) ;;
    *)
        echo ""
        echo "ヒント: $CLI_DIR が PATH にありません。~/.zshrc に次を追加してください:"
        echo "  export PATH=\"$CLI_DIR:\$PATH\""
        ;;
esac
