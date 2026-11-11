#!/usr/bin/env bash
# Changes the bundle identifier inside an UNSIGNED IPA, for users whose
# provisioning profile requires a specific identifier.
#
# Usage: set_bundle_id.sh <input.ipa> <new.bundle.id> [output.ipa]
#
# This does not sign anything. It only rewrites CFBundleIdentifier in the
# archive's Info.plist so a signing tool sees the identifier your profile
# expects. The app has no nested bundles, so there is nothing else to rewrite.
set -euo pipefail

IPA="${1:?usage: set_bundle_id.sh <input.ipa> <new.bundle.id> [output.ipa]}"
NEW_ID="${2:?usage: set_bundle_id.sh <input.ipa> <new.bundle.id> [output.ipa]}"
OUT="${3:-${IPA%.ipa}-$(echo "$NEW_ID" | tr '.' '-').ipa}"

if ! [[ "$NEW_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "error: '$NEW_ID' is not a valid bundle identifier" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IPA" -d "$WORK"
APP_COUNT="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
if [ "$APP_COUNT" != "1" ]; then
  echo "error: expected exactly one .app in Payload, found $APP_COUNT" >&2
  exit 1
fi

APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_ID" "$APP/Info.plist"

rm -f "$OUT"
( cd "$WORK" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$OUT" )

echo "wrote $OUT with CFBundleIdentifier=$NEW_ID (still unsigned)"
