#!/bin/bash
# Build the Flow AppImage, tag a release, and publish it to GitHub Releases.
# Usage: scripts/release-linux.sh <version>
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="jdreioe/Flow"
BUILD_DIR="${TMPDIR:-/tmp}/flow-release-build"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
LINUXDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
BUILD_ONLY="${FLOW_RELEASE_BUILD_ONLY:-0}"

command -v cargo >/dev/null || { echo "error: cargo not found" >&2; exit 1; }
if [ "$BUILD_ONLY" != "1" ]; then
    command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "error: not authenticated with gh. Run: gh auth login" >&2; exit 1; }
fi

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "error: pass a version: $0 1.2.0" >&2; exit 1; }
case "$VERSION" in
    v*) VERSION="${VERSION#v}" ;;
esac
case "$VERSION" in
    *[!0-9.]*|.*|*.)
        echo "error: version must contain only digits and dots: $VERSION" >&2
        exit 1
        ;;
esac
TAG="v$VERSION"

if [ "$BUILD_ONLY" != "1" ] && { git -C "$PROJECT_ROOT" rev-parse "refs/tags/$TAG" >/dev/null 2>&1 \
    || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; }; then
    echo "error: $TAG already exists" >&2
    exit 1
fi

echo "Releasing $TAG from $REPO"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/tools"

FLOW_VERSION="$VERSION" cargo build --release --locked --package flow-linux
BINARY="$PROJECT_ROOT/target/release/flow-linux"
[ -x "$BINARY" ] || { echo "error: built binary not found at $BINARY" >&2; exit 1; }

APPDIR="$BUILD_DIR/AppDir"
mkdir -p "$APPDIR/usr/bin" \
    "$APPDIR/usr/share/icons/hicolor/16x16/apps" \
    "$APPDIR/usr/share/icons/hicolor/32x32/apps" \
    "$APPDIR/usr/share/icons/hicolor/48x48/apps"
cp "$BINARY" "$APPDIR/usr/bin/flow-linux"
cp "$PROJECT_ROOT/linux/io.github.jdreioe.flow.desktop" "$APPDIR/"
cp "$PROJECT_ROOT/linux/assets/flow-48.png" "$APPDIR/io.github.jdreioe.flow.png"
for SIZE in 16 32 48; do
    cp "$PROJECT_ROOT/linux/assets/flow-$SIZE.png" \
        "$APPDIR/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps/io.github.jdreioe.flow.png"
done

# Bundle the Piper offline speech engine (binary plus espeak-ng data) next to
# flow-linux so Piper voices work without a separate install.
PIPER_VERSION="2023.11.14-2"
case "$(uname -m)" in
    aarch64) PIPER_TARBALL="piper_linux_aarch64.tar.gz" ;;
    *) PIPER_TARBALL="piper_linux_x86_64.tar.gz" ;;
esac
curl -fL -o "$BUILD_DIR/tools/$PIPER_TARBALL" \
    "https://github.com/rhasspy/piper/releases/download/$PIPER_VERSION/$PIPER_TARBALL"
tar -xzf "$BUILD_DIR/tools/$PIPER_TARBALL" -C "$APPDIR/usr/bin" --strip-components=1

LINUXDEPLOY="$BUILD_DIR/tools/linuxdeploy-x86_64.AppImage"
curl -fL -o "$LINUXDEPLOY" "$LINUXDEPLOY_URL"
LINUXDEPLOY_QT="$BUILD_DIR/tools/linuxdeploy-plugin-qt-x86_64.AppImage"
curl -fL -o "$LINUXDEPLOY_QT" "$LINUXDEPLOY_QT_URL"
chmod +x "$LINUXDEPLOY" "$LINUXDEPLOY_QT"

# The qt plugin bundles the linked Qt libraries and scans the QML sources so
# every imported module ships inside the AppImage.
export QML_SOURCES_PATHS="$PROJECT_ROOT/linux/qml"
export EXTRA_QT_PLUGINS="svg;multimedia"
export LD_LIBRARY_PATH="$APPDIR/usr/bin:${LD_LIBRARY_PATH:-}"
export PATH="$BUILD_DIR/tools:$PATH"
"$LINUXDEPLOY" --appimage-extract-and-run \
    --appdir "$APPDIR" \
    --plugin qt \
    --output appimage

BUILT_APPIMAGE="$(find "$BUILD_DIR" -maxdepth 2 -name '*.AppImage' ! -path '*/tools/*' | head -n 1)"
[ -n "$BUILT_APPIMAGE" ] || { echo "error: linuxdeploy produced no AppImage" >&2; exit 1; }
DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"
ARTIFACT="$DIST_DIR/Flow-linux-$TAG-x86_64.AppImage"
mv "$BUILT_APPIMAGE" "$ARTIFACT"
echo "Built $ARTIFACT"

NOTES_FILE="$BUILD_DIR/notes.md"
cat > "$NOTES_FILE" <<EOF
Flow $TAG for Linux

Download the AppImage, make it executable (\`chmod +x\`), and run it. Installed
builds update themselves from the tray menu (Check for Updates).
EOF

if [ "$BUILD_ONLY" = "1" ]; then
    echo "Package ready for the shared release: $ARTIFACT"
else
    gh release create "$TAG" \
        --repo "$REPO" \
        --title "Flow $TAG (Linux)" \
        --notes-file "$NOTES_FILE" \
        "$ARTIFACT"
    echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
fi
