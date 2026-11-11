#!/usr/bin/env bash
# Build CHROMEX with xtool and emit an unsigned IPA.
#
#   bash Scripts/xtool-build.sh            # release, unsigned
#
# xtool's `dev build --ipa` only signs when `--sign` is passed. We never pass it,
# so the archive has no signature and no provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xtool >/dev/null 2>&1; then
  echo "xtool not found. Install it from https://github.com/xtool-org/xtool/releases" >&2
  exit 1
fi

if xtool sdk status 2>&1 | grep -qi 'not installed'; then
  cat >&2 <<'EOF'
BLOCKER: xtool's Darwin Swift SDK is not installed, so no iOS binary can be produced.

  xtool sdk install /path/to/Xcode.xip --slim

That is a one-time prerequisite documented by xtool:
https://xtool.sh/documentation/xtool/installation-linux
EOF
  exit 2
fi

echo "== building with xtool (release, unsigned) =="
xtool dev build -c release --ipa

IPA="$(find . -maxdepth 4 -name '*.ipa' -newermt '-20 minutes' -print -quit || true)"
if [ -z "$IPA" ]; then
  echo "xtool finished but no fresh .ipa was found. Inspect the output above." >&2
  exit 3
fi

mkdir -p dist
cp -f "$IPA" dist/CHROMEX-unsigned.ipa
bash Scripts/verify_ipa.sh dist/CHROMEX-unsigned.ipa
shasum -a 256 dist/CHROMEX-unsigned.ipa | tee dist/CHROMEX-unsigned.ipa.sha256
echo "OK: dist/CHROMEX-unsigned.ipa"
