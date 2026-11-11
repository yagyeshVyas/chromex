#!/usr/bin/env bash
# CHROMEX environment diagnostics.
#
# Exit codes:
#   0  everything required is present
#   10 Swift toolchain missing or unusable
#   11 xtool missing
#   12 xtool Darwin SDK missing (build impossible)
#   13 device tooling missing (build still possible)
#   14 no iOS device visible to WSL (build still possible)
set -u
cd "$(dirname "$0")/.."

status=0
note() { printf '%s\n' "$*"; }
fail() { printf 'MISSING: %s\n' "$*" >&2; }

note "== WSL / Ubuntu =="
note "kernel : $(uname -srm)"
if [ -r /etc/os-release ]; then . /etc/os-release; note "distro : $PRETTY_NAME"; else note "distro : unknown"; fi
note "cpu    : $(nproc) cores"
note "memory : $(free -h 2>/dev/null | awk '/Mem:/{print $2}')"
note "disk   : $(df -h . | awk 'NR==2{print $4" free of "$2}')"

note ""
note "== Swift =="
if command -v swift >/dev/null 2>&1; then
  note "$(swift --version 2>&1 | head -2 | tr '\n' ' ')"
else
  fail "swift"
  status=10
fi

note ""
note "== xtool =="
if command -v xtool >/dev/null 2>&1; then
  note "binary : $(command -v xtool)"
  note "version: $(xtool --version 2>&1 | head -1)"
else
  fail "xtool"
  [ "$status" -eq 0 ] && status=11
fi

note ""
note "== Darwin Swift SDK =="
if command -v xtool >/dev/null 2>&1; then
  SDK_STATUS="$(xtool sdk status 2>&1 || true)"
  note "$SDK_STATUS"
  if printf '%s' "$SDK_STATUS" | grep -qi 'not installed'; then
    note "fix: xtool sdk install /path/to/Xcode.xip --slim"
    [ "$status" -eq 0 ] && status=12
  fi
else
  note "skipped (xtool missing)"
fi
if command -v swift >/dev/null 2>&1; then
  note "swift sdk list: $(swift sdk list 2>&1 | tr '\n' ' ')"
fi

note ""
note "== project =="
for file in Package.swift xtool.yml project.yml README.md; do
  [ -f "$file" ] && note "$file: present" || { fail "$file"; [ "$status" -eq 0 ] && status=11; }
done
if command -v swift >/dev/null 2>&1; then
  if swift package dump-package >/dev/null 2>&1; then
    note "Package.swift: parses"
  else
    fail "Package.swift does not parse"
    [ "$status" -eq 0 ] && status=11
  fi
fi

note ""
note "== device tooling =="
device_tooling=0
for tool in usbmuxd idevice_id ideviceinfo; do
  if command -v "$tool" >/dev/null 2>&1; then
    note "$tool: $(command -v "$tool")"
  else
    fail "$tool"
    device_tooling=1
  fi
done
if pgrep -x usbmuxd >/dev/null 2>&1; then
  note "usbmuxd: running"
else
  note "usbmuxd: not running"
fi
if [ "$device_tooling" -eq 1 ]; then
  note "fix: sudo apt-get install -y usbmuxd libimobiledevice-utils"
  [ "$status" -eq 0 ] && status=13
fi

note ""
note "== iOS device visibility from WSL =="
if command -v idevice_id >/dev/null 2>&1; then
  DEVICES="$(idevice_id -l 2>/dev/null || true)"
  if [ -n "$DEVICES" ]; then
    note "devices: $DEVICES"
  else
    note "devices: none visible"
    note "Windows may still see the phone. WSL needs USB passthrough:"
    note "  (Windows) winget install usbipd"
    note "  (Windows admin) usbipd list ; usbipd bind --busid <id> ; usbipd attach --wsl --busid <id>"
    [ "$status" -eq 0 ] && status=14
  fi
fi

note ""
if [ "$status" -eq 0 ]; then
  note "RESULT: all checks passed"
else
  note "RESULT: exit $status (see MISSING lines above)"
fi
exit "$status"
