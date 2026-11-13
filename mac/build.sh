#!/bin/bash
# Build the macOS app bundle and CLI wrapper.
#
#   ./build.sh            # release build -> dist/DSH Launcher.app + dist/dshl + zip
#   VERSION=0.1.16 ./build.sh   # override (normally read from the Windows csproj)
#
# The version is shared with the Windows app: src/DshLauncher/DshLauncher.csproj
# is the single source of truth, and this script reads its <Version>.
#
# Requires Xcode Command Line Tools (swift, sips, iconutil, codesign).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
PROJECT="$ROOT/../src/DshLauncher/DshLauncher.csproj"
VERSION="${VERSION:-$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$PROJECT" | head -n 1 | tr -d '[:space:]')}"
if [ -z "$VERSION" ]; then
    echo "error: ${PROJECT} の <Version> を読めません。VERSION=... で指定してください。" >&2
    exit 1
fi
APP="$ROOT/dist/DSH Launcher.app"
BIN="$ROOT/.build/$CONFIG/DshLauncher"

echo "==> version $VERSION (from DshLauncher.csproj)"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product DshLauncher

echo "==> assemble app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DshLauncher"
chmod +x "$APP/Contents/MacOS/DshLauncher"
sed "s/__VERSION__/$VERSION/" "$ROOT/Support/Info.plist" > "$APP/Contents/Info.plist"

if [ -f "$ROOT/Support/AppIcon-1024.png" ]; then
    echo "==> icon"
    ICONSET="$ROOT/.build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ROOT/Support/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ROOT/Support/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc sign"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> CLI wrapper + zip"
mkdir -p "$ROOT/dist"
cat > "$ROOT/dist/dshl" <<EOF
#!/bin/sh
exec "$APP/Contents/MacOS/DshLauncher" "\$@"
EOF
chmod +x "$ROOT/dist/dshl"
ARCH="$(uname -m)"
ZIP="$ROOT/dist/DSHLauncher-$VERSION-mac-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "built: $APP"
echo "cli:   $ROOT/dist/dshl"
echo "zip:   $ZIP"
