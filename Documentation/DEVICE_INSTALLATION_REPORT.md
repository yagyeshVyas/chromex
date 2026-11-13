# Device Installation Report

**Result: BLOCKED. CHROMEX was not installed on the iPhone, and no installation was attempted.**

This report explains precisely why, so the failure is not mistaken for a bug in the app.

---

## 1. The artifact that exists

`dist/CHROMEX-unsigned.ipa` — built by the CI lane, verified to contain no signature, no
provisioning profile, and no signing material (see `UNSIGNED_IPA_VERIFICATION.md`).

An unsigned IPA is a ZIP of `Payload/CHROMEX.app` with an unsigned Mach-O. iOS will not install it.
It is the *input* to signing, not an installable app.

## 2. Why installation was not attempted

| Path | Requirement | Reality |
|---|---|---|
| `xtool install` with an unsigned IPA | A signed app | Unsigned by design; would fail at install |
| `xtool dev build --sign` | Apple ID authentication + Darwin SDK | No credentials used by policy; SDK missing |
| Independent signing (Sideloadly/AltStore/zsign) | Your certificate/profile | Not available to this environment, and should not be |
| Xcode device install | macOS + Xcode | Not available |

Installing would require either your Apple ID (which I must not use without your explicit action)
or your signing certificate. Both are deliberately outside this repository.

## 3. Device connection status

- Windows detects the iPhone (`Apple Mobile Device USB Composite Device`, WPD `Apple iPhone`).
- WSL does not: no `usbipd`, `usbmuxd` not running, `idevice_id -l` fails, `xtool devices` empty.

So even with a signed IPA, the device is not reachable from the build environment yet. Details and
fix commands are in `IPHONE_CONNECTION_REPORT.md`.

## 4. What would be required to install

### Option A — free Apple ID via xtool (after SDK install)

```bash
xtool sdk install /path/to/Xcode.xip --slim
xtool auth                     # interactive; you enter credentials
xtool dev build -c release --sign
xtool install dist/CHROMEX-signed.ipa
```

Limits: 7-day certificate, device must be registered to the Apple ID, Developer Mode enabled.

### Option B — independent signing (no Apple ID shared with this repo)

1. Sign `dist/CHROMEX-unsigned.ipa` with Sideloadly/AltStore/zsign using your own certificate and
   profile (see `SIGNING-GUIDE.md`).
2. Install the signed IPA, then trust the developer certificate in Settings.

## 5. What could not be verified

- Launch, startup crash behaviour, first-run UI, navigation, persistence.
- Any runtime browser or extension behaviour.
- Logs (no install means no device logs).

Every one of these is listed as **unverified** in `FINAL_TEST_REPORT.md`; none is claimed as working.

## 6. Path to unblocking

1. Install the xtool Darwin SDK.
2. Install `usbipd-win`, attach the iPhone to WSL, start `usbmuxd`; confirm `xtool devices`.
3. Either authenticate xtool with your Apple ID (you perform this step) or sign independently.
4. Re-run the device checklist in `RELEASE.md` §7 and record results here.
