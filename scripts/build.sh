#!/bin/bash
#
# Build TapDock.app with swiftc. Command Line Tools are enough; Xcode is not.
#
#   ./scripts/build.sh                 # dist/TapDock.app  (arm64, ad-hoc signed)
#   ./scripts/build.sh --universal     # arm64 + x86_64, merged with lipo
#   ./scripts/build.sh --zip           # also dist/TapDock-<version>-<arch>.zip
#   ./scripts/build.sh --release       # same as --zip
#   ./scripts/build.sh --universal --zip
#
# The app is ad-hoc signed (`codesign --force --deep --sign -`). macOS may ask
# you to allow it on first launch, and Accessibility permission is tied to the
# signature, so a rebuild can require toggling that permission again.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="TapDock"
DIST="$ROOT/dist"
APP_BUNDLE="$DIST/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
EXEC="$MACOS_DIR/$APP_NAME"
INFO_PLIST="$ROOT/Info.plist"
ENTITLEMENTS="$ROOT/entitlements.plist"

UNIVERSAL=0
ZIP=0

usage() {
    cat <<'EOF'
Usage: ./scripts/build.sh [--universal] [--zip|--release]

  (default)    Build dist/TapDock.app for arm64 and ad-hoc sign it.
  --universal  Compile arm64 and x86_64, then merge them with lipo.
  --zip        Also write dist/TapDock-<version>-<arch>.zip.
  --release    Same as --zip.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --zip|--release) ZIP=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "TapDock builds on macOS with Command Line Tools. This host is $(uname -s)." >&2
    exit 1
fi

for tool in swiftc codesign lipo ditto; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing '$tool'. Install Xcode Command Line Tools and try again." >&2
        exit 1
    fi
done

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    echo "Missing /usr/libexec/PlistBuddy." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

SOURCES=(
    "$ROOT/Sources/TapDock/main.swift"
    "$ROOT/Sources/TapDock/AppModel.swift"
    "$ROOT/Sources/TapDock/DockController.swift"
    "$ROOT/Sources/TapDock/PopoverView.swift"
    "$ROOT/Sources/TapDock/AppDelegate.swift"
)

for source in "${SOURCES[@]}"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing source file: $source" >&2
        exit 1
    fi
done

compile_arch() {
    local arch="$1"
    local output="$2"
    echo "  compiling ${arch}"
    swiftc \
        -O \
        -target "${arch}-apple-macos13.0" \
        -swift-version 5 \
        -framework Cocoa \
        -framework SwiftUI \
        -framework ApplicationServices \
        -framework ServiceManagement \
        -o "$output" \
        "${SOURCES[@]}"
}

echo "Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER})"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

if [[ "$UNIVERSAL" -eq 1 ]]; then
    ARCH_LABEL="universal"
    compile_arch arm64 "$TMPDIR_BUILD/TapDock-arm64"
    compile_arch x86_64 "$TMPDIR_BUILD/TapDock-x86_64"
    lipo -create \
        "$TMPDIR_BUILD/TapDock-arm64" \
        "$TMPDIR_BUILD/TapDock-x86_64" \
        -output "$EXEC"
else
    ARCH_LABEL="arm64"
    compile_arch arm64 "$EXEC"
fi

chmod 755 "$EXEC"

cp "$INFO_PLIST" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$RESOURCES_DIR/MenuBarIcon.png"
cp "$ROOT/Resources/MenuBarIcon@2x.png" "$RESOURCES_DIR/MenuBarIcon@2x.png"
cp "$ROOT/Resources/MenuBarIcon@3x.png" "$RESOURCES_DIR/MenuBarIcon@3x.png"

# Ad-hoc signature. Entitlements cover the Apple Event fallback used when
# Accessibility hiding is declined; the primary path is the Accessibility API.
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE"

if [[ "$ZIP" -eq 1 ]]; then
    ARCHIVE="$DIST/${APP_NAME}-${VERSION}-${ARCH_LABEL}.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
    echo "Archive: $ARCHIVE"
fi

echo "Built: $APP_BUNDLE"
echo "Run:   open \"$APP_BUNDLE\""
