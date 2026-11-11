#!/usr/bin/env bash
# Packages a built .app into Payload/ and zips it into an unsigned IPA.
# Usage: package_ipa.sh <path/to/CHROMEX.app> [output.ipa]
set -euo pipefail

APP="${1:?usage: package_ipa.sh <CHROMEX.app> [output.ipa]}"
OUT="${2:-CHROMEX-unsigned.ipa}"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

APP_NAME="$(basename "$APP")"
rm -rf Payload "$OUT"
mkdir -p Payload

# ditto preserves bundle structure, permissions and symlinks better than cp -R.
/usr/bin/ditto "$APP" "Payload/$APP_NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$OUT"

SIZE="$(du -h "$OUT" | cut -f1)"
echo "packaged $OUT ($SIZE) containing Payload/$APP_NAME"
