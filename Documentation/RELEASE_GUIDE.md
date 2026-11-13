# Release Guide

How to build, verify, sign and install CHROMEX from Windows, without a Mac.

---

## 1. Build in this environment

### Primary path — xtool (blocked here today)

```bash
# inside WSL2
cd /mnt/d/iosapp/chromex-browser
bash Scripts/diagnose_environment.sh      # expect exit 0 when ready

xtool sdk install /path/to/Xcode.xip --slim   # one-time, needs an Apple ID download
xtool dev build -c release --ipa              # builds and emits an IPA
bash Scripts/xtool-build.sh                   # build + verify + SHA-256 into dist/
```

`xtool dev build --ipa` without `--sign` produces an **unsigned** archive. This is the primary path
and it is currently blocked: `xtool sdk status` reports `Not installed`, and `xtool dev build`
fails with `Error: Could not read file or directory at path ''` because it tries to generate the
Darwin SDK from a missing Xcode path.

### Fallback path — optional CI lane

```bash
gh workflow run ios-build.yml
gh run download <run-id> -n CHROMEX-unsigned-ipa
```

This produces the same unsigned IPA using XcodeGen + xcodebuild on a macOS runner. It exists only
until the xtool SDK is installed; it is not the documented development loop.

### Linux QA (works today)

```bash
bash Scripts/qa-linux.sh     # 35 assertions + benchmarks + compatibility reports
```

## 2. Verify the artifact

```bash
unzip -l dist/CHROMEX-unsigned.ipa
unzip -t dist/CHROMEX-unsigned.ipa
bash Scripts/verify_ipa.sh dist/CHROMEX-unsigned.ipa
shasum -a 256 dist/CHROMEX-unsigned.ipa | tee dist/SHA256SUMS.txt
```

`verify_ipa.sh` fails if it finds `_CodeSignature`, `embedded.mobileprovision`, `CodeResources`,
a `.p12`, a `.cer`, a non-arm64 executable, or an invalid `Info.plist`.

## 3. Sign it yourself

The unsigned IPA is not installable as-is. Choose one:

| Tool | Platform | What you need |
|---|---|---|
| Sideloadly | Windows | Apple ID (free works) |
| AltStore / SideStore | Windows + iPhone | Apple ID |
| zsign | Windows/Linux/macOS | `.p12` + `.mobileprovision` |
| Xcode | macOS | Apple ID |

If your profile's App ID is not `com.chromex.browser`:

```bash
bash Scripts/set_bundle_id.sh dist/CHROMEX-unsigned.ipa com.your.id
```

No nested bundles, app groups, keychain groups, or push entitlements exist, so a single identifier
and a single profile are sufficient. Entitlements come from your profile; the published app has none.

Full instructions and a 12-row error table: `SIGNING-GUIDE.md`.

## 4. Install and trust

- Sideloadly/AltStore install as part of signing.
- Otherwise: Apple Configurator 2, 3uTools, or `xtool install <signed.ipa>` with the device connected.
- Free-account builds expire after 7 days; re-sign to renew.
- After installing: Settings → General → VPN & Device Management → trust your certificate.
- Developer Mode is required for development-signed builds.

## 5. Extension installation

1. Copy a package from `QA/fixtures/zips/` (or your own `.zip`/`.crx`) to the iPhone via Files/AirDrop.
2. In CHROMEX: **Chromex Hub → +** → pick the file.
3. Read the verdict and the "will not work" list before installing.
4. After install, open a matching page; errors appear under Hub → Diagnostics.

## 6. Known issues at this release

| Issue | Impact |
|---|---|
| xtool SDK missing on this machine | No local build; CI fallback only |
| No device run | Browser and extension runtime behaviour unverified |
| CRX signatures not verified | UI labels this explicitly |
| Extension options pages not hosted | Options UI unavailable |
| `webRequest`, cookies, alarms, i18n, DNR | Unsupported; reported before install |
| Background execution stops on suspend | MV3 service workers are non-persistent pages |
| Screenshots not captured | `Scripts/capture-screenshots.sh` provided but unrun |

## 7. Release checklist

- [ ] `bash Scripts/qa-linux.sh` passes
- [ ] CI green, 57 XCTest cases
- [ ] `dist/CHROMEX-unsigned.ipa` verified and hashed
- [ ] Device QA completed (`RELEASE.md` §7)
- [ ] Screenshots captured
- [ ] SHA-256 published with the release
- [ ] No secrets or profiles committed (`git status` clean of signing material)

Do not tag a release until the device QA items are honestly complete.
