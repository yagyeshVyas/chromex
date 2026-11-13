# Device Installation Report

**Result: INSTALLED AND LAUNCHED on the physical iPhone.**
Device: `Mafia` (iPhone16,2, iOS 27.2, UDID `00008130-000E35E60E30001C`)
Installed bundle: `app.mountain3690.pegasus6317` (display name **CHROMEX**)
Time: 2026-11-13 11:07 local (initial) — **reinstalled 11:18 with build 26**, which contains the security-scoped import fix
Launch after reinstall: processIdentifier **70440**, no crash report

---

## 1. What was done

The published artifact is unsigned, so it was signed locally with the **existing development
assets already on this machine** — no credentials were transmitted or requested:

```bash
zsign -f \
  -k 00008130-...p12 -p <password from build.sh> \
  -m 00008130-...mobileprovision \
  -b app.mountain3690.pegasus6317 \
  -o dist/CHROMEX-signed.ipa dist/CHROMEX-unsigned.ipa
```

Observed output:

```
>>> AppName:  CHROMEX
>>> BundleId: app.mountain3690.pegasus6317
>>> TeamId:   24B36A6LKT
>>> SignFile: CHROMEX
>>> Signed OK!
>>> Archive OK! (3.23 MB)
```

The signed archive was verified before installation: `_CodeSignature/` present,
`embedded.mobileprovision` present, `LC_CODE_SIGNATURE` present, bundle id rewritten.

Installation used Windows-side tooling (the device is visible there; WSL is not):

```powershell
python -m pymobiledevice3 apps install dist\CHROMEX-signed.ipa
```

```
Stage: VerifyingApplication ... InstallingApplication ... InstallComplete
Installation succeed.
```

Registration check:

```powershell
python -m pymobiledevice3 apps list   # contains CHROMEX, app.mountain3690.pegasus6317
```

## 2. Launch evidence

```powershell
python -m pymobiledevice3 developer core-device launch-application app.mountain3690.pegasus6317
```

Returned a launch result with `processIdentifier: 70343` and the on-device executable path
`/private/var/containers/Bundle/Application/07E5F1A4-.../CHROMEX.app/CHROMEX`.

Six seconds later:

- `developer core-device list-processes` still lists PID 70343 → **the app did not crash on launch**.
- `crash list` contains **no CHROMEX report**.
- `developer core-device screen-capture screenshot screenshots/chromex-device.png` produced a
  1290×2796 PNG.

## 3. Important side effect

The provisioning profile is **explicit** (`24B36A6LKT.app.mountain3690.pegasus6317`), not a wildcard.
Installing CHROMEX therefore **replaced the earlier ChromeX prototype** that used the same identifier.
This is a signing constraint, not a CHROMEX choice: an IPA can only be signed with an identifier the
profile authorises. Users signing their own copies can choose any identifier their profile allows.

## 4. Signing material

Only local assets were used: the `.p12` and `.mobileprovision` already present in
`00008130-000E35E60E30001C/`. Profile expiry **2026-12-23**; the app stops launching after that date
unless re-signed. Nothing was uploaded; no Apple ID was used.

## 5. What is verified, and what is not

| Check | Status |
|---|---|
| Signed IPA structure | **Verified** (signature, profile, bundle id) |
| Installation | **Verified** (`Installation succeed`) |
| App registered on device | **Verified** (`apps list`) |
| Launch without crash | **Verified** (PID alive after 6 s, no crash log) |
| Screenshot captured | **Done** — PNG 1290×2796 at `screenshots/chromex-device.png`; **not visually inspected** (the assistant cannot read images in this session) |
| UI interaction, navigation, tabs, downloads | **Not tested** |
| Extension import on device | **Not tested** |
| Persistence across relaunch | **Not tested** |
| Memory/CPU/battery | **Not measured** |

## 6. How to repeat or roll back

```powershell
# reinstall the same build
python -m pymobiledevice3 apps install dist\CHROMEX-signed.ipa

# remove it
python -m pymobiledevice3 apps uninstall app.mountain3690.pegasus6317
```

The signed IPA (`dist/CHROMEX-signed.ipa`) is local only and is intentionally not published; the
public artifact remains `dist/CHROMEX-unsigned.ipa`.
