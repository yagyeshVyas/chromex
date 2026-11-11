#!/usr/bin/env bash
# Verifies that an IPA is structurally valid, arm64, and genuinely unsigned.
# Exits non-zero on any violation so CI can gate on it.
# Usage: verify_ipa.sh <path/to/app.ipa>
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <CHROMEX.ipa>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

[ -f "$IPA" ] || fail "file not found: $IPA"

echo "== ZIP integrity =="
unzip -t "$IPA" >/dev/null || fail "archive failed zip integrity check"

LIST="$(unzip -Z1 "$IPA")"
echo "$LIST" | grep -qx 'Payload/' || fail "archive has no Payload/ directory"
APP_ENTRY="$(echo "$LIST" | grep -E '^Payload/[^/]+\.app/$' | head -1 || true)"
[ -n "$APP_ENTRY" ] || fail "archive has no .app bundle inside Payload/"
APP_NAME="$(basename "$APP_ENTRY")"

if echo "$LIST" | grep -q '__MACOSX'; then
  fail "archive contains __MACOSX resource-fork entries"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/$APP_NAME"
[ -d "$APP" ] || fail "app bundle missing after extraction"

echo "== Bundle =="
note "app: $APP_NAME"
[ -f "$APP/Info.plist" ] || fail "Info.plist missing"
plutil -lint "$APP/Info.plist" >/dev/null || fail "Info.plist is not a valid plist"

EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")"
note "bundle id: $BUNDLE_ID"
note "executable: $EXECUTABLE"

[ -f "$APP/$EXECUTABLE" ] || fail "executable $EXECUTABLE missing"
[ -x "$APP/$EXECUTABLE" ] || fail "executable $EXECUTABLE is not executable"

echo "== Architecture =="
file "$APP/$EXECUTABLE" | tee /tmp/chromex-file.txt
grep -q 'Mach-O' /tmp/chromex-file.txt || fail "executable is not Mach-O"
grep -q 'arm64' /tmp/chromex-file.txt || fail "executable is not arm64"

echo "== Signing material must be absent =="
if [ -d "$APP/_CodeSignature" ]; then fail "_CodeSignature directory present"; fi
if [ -f "$APP/embedded.mobileprovision" ]; then fail "embedded.mobileprovision present"; fi
if [ -n "$(find "$APP" -name '*.mobileprovision' -print -quit)" ]; then fail "provisioning profile found in bundle"; fi
if [ -n "$(find "$APP" -name 'CodeResources' -print -quit)" ]; then fail "CodeResources found in bundle"; fi
if [ -n "$(find "$APP" -name '*.p12' -print -quit)" ]; then fail "PKCS#12 signing material found in bundle"; fi
if [ -n "$(find "$APP" -name '*.cer' -print -quit)" ]; then fail "certificate file found in bundle"; fi
note "no _CodeSignature, no provisioning profile, no signing material"

echo "== Mach-O signature =="
if command -v codesign >/dev/null 2>&1; then
  if codesign -dv "$APP/$EXECUTABLE" >/dev/null 2>&1; then
    fail "code signature present on executable"
  fi
  note "codesign reports no signature (expected)"
fi

echo "== Licence & size =="
note "$(du -h "$IPA" | cut -f1) archive"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$IPA" | awk '{print "  sha256: "$1}'
fi

echo "OK: $IPA is a valid unsigned IPA ($APP_NAME, $BUNDLE_ID)"
