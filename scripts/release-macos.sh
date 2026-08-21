#!/bin/sh
# Build Flow.app, tag a release, and publish it to GitHub Releases.
# Usage: scripts/release-macos.sh [version]
#   version defaults to MARKETING_VERSION from the Xcode project.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$PROJECT_ROOT/macos/Flow.xcodeproj"
SCHEME="Flow"
REPO="jdreioe/Flow"
BUILD_DIR="${TMPDIR:-/tmp}/flow-release-build"
CONFIGURATION="Release"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not authenticated with gh. Run: gh auth login" >&2; exit 1; }

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
        | awk '/MARKETING_VERSION/ { print $3; exit }')"
fi
[ -n "$VERSION" ] || { echo "error: could not determine version; pass one: $0 1.2.0" >&2; exit 1; }
case "$VERSION" in
    v*) TAG="$VERSION" ;;
    *) TAG="v$VERSION" ;;
esac

echo "Releasing $TAG from $REPO"

if git -C "$PROJECT_ROOT" rev-parse "refs/tags/$TAG" >/dev/null 2>&1 \
    || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: $TAG already exists" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    build

APP="$BUILD_DIR/Build/Products/$CONFIGURATION/Flow.app"
[ -d "$APP" ] || { echo "error: built app not found at $APP" >&2; exit 1; }

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -n "$BUILT_VERSION" ] && [ "$BUILT_VERSION" != "${VERSION#v}" ]; then
    echo "warning: app version ($BUILT_VERSION) does not match release tag (${VERSION#v})" >&2
    echo "         bump MARKETING_VERSION in the Xcode project before releasing." >&2
    printf 'Continue anyway? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi

ZIP_PATH="$BUILD_DIR/Flow-$TAG.zip"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

NOTES_FILE="$BUILD_DIR/notes.md"
cat > "$NOTES_FILE" <<EOF
Flow $TAG for macOS

Download and unzip, then drag Flow.app to /Applications.

If macOS blocks the app on first launch, right-click Flow.app and choose Open.
EOF

gh release create "$TAG" \
    --repo "$REPO" \
    --title "Flow $TAG (macOS)" \
    --notes-file "$NOTES_FILE" \
    "$ZIP_PATH"

echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
