# Unsigned IPA Verification

**Artifact:** `dist/CHROMEX-unsigned.ipa`
**SHA-256:** `03a02c25b959c954a0d9121b97f8ab7e3d46208e235b748a8c37c177d073e1e3`
**Size:** 1,348,319 bytes
**Built from:** commit `c7b2490`, CI run 43089913502 (macOS 16.4)
**Bundle:** `com.chromex.browser` · version 1.0.0 · build 21 · arm64

---

## 1. Is it genuinely unsigned?

**Yes**, on three independent checks:

| Check | Method | Result |
|---|---|---|
| Bundle-level signing | search for `_CodeSignature/`, `CodeResources` | absent |
| Provisioning profile | search for `embedded.mobileprovision` and `*.mobileprovision` | absent |
| Mach-O signature | load-command scan for `LC_CODE_SIGNATURE` (0x1d) | **no such command** |
| Signing material | search for `.p12`, `.cer` | absent |
| CI cross-check | `codesign -dv` on macOS runner | "code object is not signed at all" |

The local check was performed with `Scripts/verify_ipa.sh` on WSL. Because `codesign` does not exist
on Linux, the script parses the Mach-O load commands directly; on macOS CI the same script uses
`codesign`. Both paths agree.

**Limitation stated honestly:** without a macOS `codesign` run locally, the LC scan is the strongest
local evidence. It is conclusive for "no code signature", because a signed Mach-O must carry
`LC_CODE_SIGNATURE`.

## 2. Archive contents

```
Payload/
Payload/CHROMEX.app/
Payload/CHROMEX.app/CHROMEX               Mach-O 0xfeedfacf, arm64
Payload/CHROMEX.app/Info.plist            com.chromex.browser, 1.0.0 (21)
Payload/CHROMEX.app/Assets.car
Payload/CHROMEX.app/AppIcon60x60@2x.png
Payload/CHROMEX.app/AppIcon76x76@2x~ipad.png
Payload/CHROMEX.app/PrivacyInfo.xcprivacy
Payload/CHROMEX.app/PkgInfo
```

Nine entries, no `Frameworks/`, no `PlugIns/`, no `__MACOSX`.

## 3. What a user must supply

1. **A signing certificate** (Apple Development / distribution) and its private key.
2. **A provisioning profile** whose App ID matches the bundle identifier and whose device list
   includes their iPhone.
3. Nothing else. There are **no entitlements**, no app groups, no keychain groups, no push, no
   associated domains, and no nested bundles.

If their profile is not `com.chromex.browser`:

```bash
bash Scripts/set_bundle_id.sh dist/CHROMEX-unsigned.ipa com.their.bundle.id
```

## 4. Can it be installed directly?

**No.** An unsigned IPA cannot be installed by `xtool install`, Finder, or any normal mechanism. It is
the input to signing. Claiming otherwise would be false.

## 5. Reproduce this verification

```bash
bash Scripts/verify_ipa.sh dist/CHROMEX-unsigned.ipa
sha256sum -c dist/SHA256SUMS.txt
```

Expected final line: `OK: dist/CHROMEX-unsigned.ipa is a valid unsigned IPA (CHROMEX.app,
com.chromex.browser 1.0.0)`.
