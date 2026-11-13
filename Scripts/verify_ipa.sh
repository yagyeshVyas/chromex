#!/usr/bin/env bash
# Verifies that an IPA is structurally valid, arm64, and genuinely unsigned.
# Portable across macOS and Linux/WSL: falls back to python3 when `file`,
# `plutil`, `codesign` or `shasum` are unavailable.
#
# Usage: verify_ipa.sh <path/to/app.ipa>
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <CHROMEX.ipa>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

[ -f "$IPA" ] || fail "file not found: $IPA"

echo "== ZIP integrity =="
if command -v unzip >/dev/null 2>&1; then
  unzip -t "$IPA" >/dev/null || fail "archive failed zip integrity check"
  LIST="$(unzip -Z1 "$IPA")"
else
  python3 - "$IPA" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
PY
  LIST="$(python3 - "$IPA" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print("\n".join(z.namelist()))
PY
)"
fi

echo "$LIST" | grep -qx 'Payload/' || fail "archive has no Payload/ directory"
APP_ENTRY="$(echo "$LIST" | grep -E '^Payload/[^/]+\.app/$' | head -1 || true)"
[ -n "$APP_ENTRY" ] || fail "archive has no .app bundle inside Payload/"
APP_NAME="$(basename "$APP_ENTRY")"

if echo "$LIST" | grep -q '__MACOSX'; then
  fail "archive contains __MACOSX resource-fork entries"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$IPA" -d "$WORK"
else
  python3 - "$IPA" "$WORK" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
fi
APP="$WORK/Payload/$APP_NAME"
[ -d "$APP" ] || fail "app bundle missing after extraction"

echo "== Bundle =="
note "app: $APP_NAME"
[ -f "$APP/Info.plist" ] || fail "Info.plist missing"

read_plist() {
  local key="$1" file="$2"
  if command -v plutil >/dev/null 2>&1; then
    plutil -extract "$key" raw "$file"
  else
    python3 - "$key" "$file" <<'PY'
import plistlib, sys
with open(sys.argv[2], "rb") as handle:
    data = plistlib.load(handle)
print(data[sys.argv[1]])
PY
  fi
}

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP/Info.plist" >/dev/null || fail "Info.plist is not a valid plist"
fi

EXECUTABLE="$(read_plist CFBundleExecutable "$APP/Info.plist")"
BUNDLE_ID="$(read_plist CFBundleIdentifier "$APP/Info.plist")"
VERSION="$(read_plist CFBundleShortVersionString "$APP/Info.plist" 2>/dev/null || echo unknown)"
note "bundle id: $BUNDLE_ID"
note "version: $VERSION"
note "executable: $EXECUTABLE"

[ -f "$APP/$EXECUTABLE" ] || fail "executable $EXECUTABLE missing"
[ -x "$APP/$EXECUTABLE" ] || fail "executable $EXECUTABLE is not executable"

echo "== Architecture =="
if command -v file >/dev/null 2>&1; then
  file "$APP/$EXECUTABLE" | tee /tmp/chromex-file.txt
  grep -q 'Mach-O' /tmp/chromex-file.txt || fail "executable is not Mach-O"
  grep -q 'arm64' /tmp/chromex-file.txt || fail "executable is not arm64"
else
  python3 - "$APP/$EXECUTABLE" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as handle:
    header = handle.read(8)
magic = struct.unpack("<I", header[:4])[0]
cpu = struct.unpack("<i", header[4:8])[0]
assert magic in (0xFEEDFACF, 0xFEEDFACE), f"not Mach-O: {magic:#x}"
assert cpu in (16777228, 12), f"not arm64: {cpu}"
print(f"  Mach-O {magic:#x}, cputype {cpu} (arm64)")
PY
fi

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
else
  if python3 - "$APP/$EXECUTABLE" <<'PY'
import struct, sys
# Scan load commands for LC_CODE_SIGNATURE (0x1d).
with open(sys.argv[1], "rb") as handle:
    data = handle.read()
if len(data) < 32:
    sys.exit(1)
if struct.unpack("<I", data[:4])[0] != 0xFEEDFACF:
    sys.exit(1)
ncmds = struct.unpack("<I", data[16:20])[0]
offset = 32
for _ in range(ncmds):
    cmd, size = struct.unpack("<II", data[offset:offset + 8])
    if cmd == 0x1D:
        sys.exit(0)
    if size == 0:
        sys.exit(1)
    offset += size
sys.exit(1)
PY
  then
    fail "LC_CODE_SIGNATURE load command present"
  fi
  note "no LC_CODE_SIGNATURE load command (parsed Mach-O; codesign unavailable)"
fi

echo "== Licence & size =="
note "$(du -h "$IPA" | cut -f1) archive"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$IPA" | awk '{print "  sha256: "$1}'
else
  sha256sum "$IPA" | awk '{print "  sha256: "$1}'
fi

echo "OK: $IPA is a valid unsigned IPA ($APP_NAME, $BUNDLE_ID $VERSION)"
