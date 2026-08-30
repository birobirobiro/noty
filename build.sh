#!/bin/bash
# Builds Noty.app with the Swift command-line toolchain (no Xcode required).
#   ./build.sh          release build
#   ./build.sh debug    fast build, no optimisation
#   ./build.sh run      build then relaunch the app
#
# Set MARKETING_VERSION / BUILD_NUMBER to stamp the bundle (CI does this from the tag).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Noty.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
MODE="${1:-release}"

MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

OPT="-O"
[ "$MODE" = "debug" ] && OPT="-Onone"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Sparkle is optional: with the framework present the app gets an updater,
# without it Updater.swift compiles to a stub that says so.
SPARKLE_FLAGS=()
if [ -d "$ROOT/Sparkle/Sparkle.framework" ]; then
    echo "→ linking Sparkle"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$ROOT/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
    SPARKLE_FLAGS=(-F "$ROOT/Sparkle" -framework Sparkle
                   -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
else
    echo "→ no Sparkle framework (run ./scripts/fetch-sparkle.sh to add updates)"
fi

echo "→ compiling ($MODE) $MARKETING_VERSION ($BUILD_NUMBER)"
swiftc $OPT -parse-as-library -swift-version 5 \
    -target arm64-apple-macosx15.0 \
    -sdk "$SDK" \
    "${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"}" \
    "$ROOT"/Sources/*.swift \
    $(find "$ROOT/Vendor" -name '*.swift') \
    -o "$APP/Contents/MacOS/Noty"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Translations. Each Resources/<lang>.lproj goes across as it is: .strings are
# read as plain UTF-8, so nothing has to compile them and no Xcode is involved.
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle ships signed by its own team and dyld refuses to load a framework whose
# Team ID differs from the process — so it has to be re-signed with our identity,
# innermost bundle first, before the app that embeds it.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_OPTS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_OPTS+=(--options runtime --timestamp)

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    V="$FW/Versions/B"
    for x in "$V"/XPCServices/*.xpc; do
        [ -e "$x" ] && codesign "${SIGN_OPTS[@]}" "$x"
    done
    [ -e "$V/Updater.app" ]  && codesign "${SIGN_OPTS[@]}" "$V/Updater.app"
    [ -e "$V/Autoupdate" ]   && codesign "${SIGN_OPTS[@]}" "$V/Autoupdate"
    codesign "${SIGN_OPTS[@]}" "$FW"
fi
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ signature valid"

echo "✓ built $APP"

if [ "$MODE" = "run" ] || [ "${2:-}" = "run" ]; then
    pkill -x Noty 2>/dev/null || true
    sleep 0.4
    open "$APP"
    echo "✓ launched"
fi
