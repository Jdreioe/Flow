#!/bin/sh
# Build Flow.app, tag a release, and publish it to GitHub Releases.
# Usage: scripts/release-macos.sh [version]
#   version defaults to MARKETING_VERSION from the Xcode project.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_ROOT/macos/Flow.xcodeproj"
SCHEME="Flow"
REPO="jdreioe/Flow"
BUILD_DIR="${TMPDIR:-/tmp}/flow-release-build"
CONFIGURATION="Release"
DEVELOPMENT_TEAM="9BB3E6JDX4"
SIGN_IDENTITY="Developer ID Application"
NOTARY_PROFILE="${FLOW_NOTARY_PROFILE:-Flow-Notary}"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not authenticated with gh. Run: gh auth login" >&2; exit 1; }

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "error: no '$SIGN_IDENTITY' certificate found. Check Xcode > Settings > Accounts." >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
fi

VERSION="${1:-$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk '/MARKETING_VERSION/ { print $3; exit }')}"
[ -n "$VERSION" ] || { echo "error: could not determine version; pass one: $0 1.2.0" >&2; exit 1; }
case "$VERSION" in
    v*) VERSION="${VERSION#v}" ;;
esac
case "$VERSION" in
    *[!0-9.]*|.*|*.)
        echo "error: version must contain only digits and dots: $VERSION" >&2
        exit 1
        ;;
esac
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

PROJECT_FILE="$PROJECT_ROOT/macos/Flow.xcodeproj/project.pbxproj"
MARKETING_VERSION_COUNT="$(awk '/MARKETING_VERSION = [0-9][0-9.]*/ { count++ } END { print count + 0 }' "$PROJECT_FILE")"
[ "$MARKETING_VERSION_COUNT" -eq 2 ] || {
    echo "error: expected two MARKETING_VERSION settings, found $MARKETING_VERSION_COUNT" >&2
    exit 1
}
echo "Updating Xcode marketing version to $VERSION..."
sed -i '' -E "s/MARKETING_VERSION = [0-9]+(\.[0-9]+)*;/MARKETING_VERSION = $VERSION;/g" "$PROJECT_FILE"

rm -rf "$BUILD_DIR"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_GET_TASK_ALLOW=NO \
    CODE_SIGN_ENTITLEMENTS="$PROJECT_ROOT/macos/Flow/FlowRelease.entitlements" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_ENABLE_HARDENED_RUNTIME=YES \
    -allowProvisioningUpdates \
    build

APP="$BUILD_DIR/Build/Products/$CONFIGURATION/Flow.app"
[ -d "$APP" ] || { echo "error: built app not found at $APP" >&2; exit 1; }

echo "Verifying code signature..."
ENTITLEMENTS="$PROJECT_ROOT/macos/Flow/FlowRelease.entitlements"
sign_code() {
    codesign --force \
        --options runtime \
        --timestamp \
        --preserve-metadata=identifier,entitlements \
        --sign "$SIGN_IDENTITY" \
        "$1"
}

verify_developer_id_signature() {
    codesign --verify --strict "$1"
    SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$1" 2>&1)"
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q "Authority=Developer ID Application:" || {
        echo "error: $1 is not signed with a Developer ID Application certificate" >&2
        exit 1
    }
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q "Timestamp=" || {
        echo "error: $1 does not have a secure timestamp" >&2
        exit 1
    }
}

SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Signing embedded Sparkle helpers..."
    SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
    for COMPONENT in \
        "$SPARKLE_VERSION"/XPCServices/*.xpc \
        "$SPARKLE_VERSION"/Updater.app; do
        [ -e "$COMPONENT" ] || continue
        sign_code "$COMPONENT"
        verify_developer_id_signature "$COMPONENT"
    done
    for AUTOUPDATE_BINARY in "$SPARKLE_VERSION"/Autoupdate; do
        [ -e "$AUTOUPDATE_BINARY" ] || continue
        sign_code "$AUTOUPDATE_BINARY"
        verify_developer_id_signature "$AUTOUPDATE_BINARY"
    done
    sign_code "$SPARKLE_FRAMEWORK"
    verify_developer_id_signature "$SPARKLE_FRAMEWORK"
fi

codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
codesign --verify --deep --strict "$APP" || { echo "error: signature verification failed" >&2; exit 1; }
verify_developer_id_signature "$APP"
echo "Signed with $SIGN_IDENTITY, hardened runtime, secure timestamp."
codesign -d --entitlements :- "$APP" | grep -q "get-task-allow" && {
    echo "error: debug entitlement still present" >&2
    exit 1
}
codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=/Signed: /p; s/^Authority=/Certificate: /p'

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

echo "Submitting $TAG to Apple notarization (this can take a few minutes)..."
NOTARY_RESULT="$BUILD_DIR/notarization-result.plist"
NOTARY_LOG="$BUILD_DIR/notarization-log.json"
if xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format plist > "$NOTARY_RESULT"; then
    NOTARY_EXIT=0
else
    NOTARY_EXIT=$?
fi

if [ "$NOTARY_EXIT" -ne 0 ]; then
    echo "error: notarization failed." >&2
    echo "  One-time setup: xcrun notarytool store-credentials \"$NOTARY_PROFILE\"" >&2
    exit 1
fi

NOTARY_STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$NOTARY_RESULT" 2>/dev/null || true)"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo "error: notarization status is '${NOTARY_STATUS:-unknown}', not Accepted." >&2
    if [ -n "$NOTARY_ID" ]; then
        if xcrun notarytool log "$NOTARY_ID" \
            --keychain-profile "$NOTARY_PROFILE" \
            "$NOTARY_LOG"; then
            echo "Notarization log: $NOTARY_LOG" >&2
        else
            echo "  Could not download the notarization log for $NOTARY_ID." >&2
        fi
    fi
    exit 1
fi

echo "Stapling ticket to app..."
xcrun stapler staple "$APP"
codesign --verify --deep --strict "$APP"
spctl -a -vv "$APP"

ditto -c -k --keepParent "$APP" "$ZIP_PATH"

SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || {
    echo "error: Sparkle's generate_appcast tool was not resolved at $GENERATE_APPCAST" >&2
    exit 1
}

UPDATES_DIR="$BUILD_DIR/updates"
APPCAST_PATH="$BUILD_DIR/appcast.xml"
mkdir -p "$UPDATES_DIR"
cp "$ZIP_PATH" "$UPDATES_DIR/$(basename "$ZIP_PATH")"
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    -o "$APPCAST_PATH" \
    "$UPDATES_DIR"

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
    "$ZIP_PATH" \
    "$APPCAST_PATH"

echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
