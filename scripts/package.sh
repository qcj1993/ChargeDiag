#!/bin/bash
# Build ChargeDiag and package a TrollStore .tipa.
#
# No signing team is involved: the bundle is signed ad hoc so it validates
# locally, and TrollStore re-signs on install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/ChargeDiag.tipa}"
DD="${DD:-/tmp/chargedign}"
mkdir -p "$DD" "$(dirname "$OUT")"

cd "$ROOT"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
fi

echo "==> building"
xcodebuild -project ChargeDiag.xcodeproj -scheme ChargeDiag \
    -sdk iphoneos -configuration Release -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee "$DD/build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

if ! grep -q "BUILD SUCCEEDED" "$DD/build.log"; then
    echo "build failed; refusing to package" >&2
    grep -E "error:" "$DD/build.log" | head -20 >&2
    exit 1
fi

APP="$DD/Build/Products/Release-iphoneos/ChargeDiag.app"
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

echo "==> validating bundle"
PLIST="$APP/Info.plist"
rc=0
for key in CFBundleIdentifier CFBundleExecutable CFBundleName \
           CFBundlePackageType CFBundleVersion CFBundleShortVersionString \
           MinimumOSVersion UIDeviceFamily; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    if [ -z "$val" ]; then
        echo "  MISSING  $key" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$key" "$(echo "$val" | head -1)"
    fi
done
EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
if [ -n "$EXE" ] && [ ! -f "$APP/$EXE" ]; then
    echo "  MISSING  executable '$EXE'" >&2
    rc=1
fi
[ $rc -eq 0 ] || { echo "==> not installable; refusing to package" >&2; exit 1; }

echo "==> packaging"
STAGE="$(mktemp -d "$DD/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

ENT="$ROOT/ChargeDiag.entitlements"
SAPP="$STAGE/Payload/ChargeDiag.app"
if [ -f "$ENT" ]; then
    codesign --force --sign - --timestamp=none --entitlements "$ENT" "$SAPP"
else
    codesign --force --sign - --timestamp=none "$SAPP"
fi
echo "==> entitlements:"
codesign -d --entitlements - "$SAPP" 2>&1 | head -30 || true

TMP_OUT="$STAGE/package.tmp"
( cd "$STAGE" && zip -qry "$TMP_OUT" Payload )
mv -f "$TMP_OUT" "$OUT"
rm -rf "$STAGE"
echo "==> $OUT"
ls -l "$OUT"
