# iPhone Connection Report

**Date:** 2026-11-11
**Host:** Windows 11 + WSL2 Ubuntu 24.04
**Result: the iPhone is detected by Windows, NOT by WSL. Installation is blocked.**

---

## 1. Windows detection

Commands and observed output:

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'Apple|iPhone' }
```

```
Status Class     FriendlyName
------ -----     ------------
OK     USBDevice Apple Mobile Device USB Composite Device
OK     WPD       Apple iPhone
OK     USBDevice Apple Mobile Device USB Device
```

**Interpretation:** the phone is physically connected, unlocked enough for Windows to enumerate it as an
Apple device, and the Apple Mobile Device USB driver is loaded. Windows can see it.

## 2. WSL access

```bash
lsusb            # not installed
usbipd           # NOT INSTALLED on Windows
idevice_id -l    # ERROR: Unable to retrieve device list!
pgrep usbmuxd    # not running
xtool devices    # (no output)
```

| Check | Result |
|---|---|
| usbmuxd binary | present (`/usr/sbin/usbmuxd`) |
| libimobiledevice tools | present (`/usr/bin/idevice_id`, `ideviceinfo`) |
| usbmuxd running | **no** |
| WSL USB passthrough (`usbipd`) | **not installed** |
| Device visible in WSL | **no** |

**Why:** WSL2 does not inherit Windows USB devices. Without `usbipd-win` binding and attaching the
Apple device, `/dev/bus/usb` has no iPhone, usbmuxd has nothing to serve, and `idevice_id` fails.
`xtool devices` is therefore empty — not because the phone is absent, but because WSL cannot reach it.

## 3. What is missing

1. **USB passthrough.** Install `usbipd-win` on Windows (admin), then bind and attach the Apple
   device to WSL.
2. **usbmuxd running in WSL.** xtool talks to devices through it.
3. Nothing else: the cable, trust relationship, and driver are working at the Windows level.

Exact commands (run as Administrator in PowerShell, then in WSL):

```powershell
winget install --interactive --exact dorssel.usbipd-win
usbipd list
usbipd bind --busid <BUSID>          # once per device
usbipd attach --wsl --busid <BUSID>  # after every reboot/reconnect
```

```bash
sudo apt-get install -y usbmuxd libimobiledevice-utils
sudo usbmuxd -f -v            # or: sudo systemctl start usbmuxd
idevice_id -l                 # should print a UDID
xtool devices
```

When Windows shows the “Trust This Computer?” prompt, tap **Trust** and enter the passcode.

## 4. Device details

**Not obtained.** `ideviceinfo` could not reach the device from WSL, so the model and iOS version are
unknown to this environment. Windows reports the device as *Apple iPhone* but does not expose the
iOS version without an Apple toolchain (iTunes/Apple Devices).

## 5. Installation capability

| Requirement | Status |
|---|---|
| Device visible to build tooling | **No** |
| Signed build for this device | **No** (no signing credentials used, unsigned artifact) |
| xtool Darwin SDK | **No** — `xtool sdk status` → `Not installed` |
| Installation attempted | **No** — correctly not attempted |

An unsigned IPA cannot be installed by `xtool install` or any ordinary mechanism. Installation needs a
development-signed build (Apple ID + provisioning) or an independently signed IPA.

## 6. Blockers, ordered

1. xtool Darwin SDK missing (`Xcode.xip`) — blocks any local build.
2. WSL USB passthrough missing — blocks device communication even if a signed IPA existed.
3. No signing credentials used by policy — blocks installation of the unsigned artifact by design.

## 7. Next action for the operator

Install `usbipd-win`, attach the iPhone to WSL, start `usbmuxd`, then re-run:

```bash
bash Scripts/diagnose_environment.sh
xtool devices
```

Expected diagnostic exit code after fixing the SDK: `0`. Until then it is `12` (SDK) or `13`/`14`
(device stack).

---

## 8. Update — 2026-11-13: install path used Windows tooling

The iPhone is still invisible to WSL, but installation succeeded from **Windows** using
pymobiledevice3 over usbmux, after signing the IPA locally with the existing certificate/profile.
See DEVICE_INSTALLATION_REPORT.md.

So the WSL passthrough steps above remain required only for xtool/device work **inside WSL**.
Windows-side install and launch do not need usbipd.
