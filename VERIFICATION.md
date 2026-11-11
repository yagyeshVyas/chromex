# Verification Record

This document records what was **actually executed** for CHROMEX 1.0.1, on which infrastructure,
and what the results were. It exists because "it builds" is a claim, and claims about unsigned
distribution deserve evidence.

---

## 1. Release under test

| | |
|---|---|
| Repository | `github.com/yagyeshVyas/chromex` (public) |
| Release | [v1.0.1 â€” unsigned IPA](https://github.com/yagyeshVyas/chromex/releases/tag/v1.0.1) |
| Asset | `CHROMEX-unsigned.ipa` |
| Size | 1,345,107 bytes |
| SHA-256 | `a15857388119653e851af6ccfd14b61ea901b80bc5e4c6191a422e9762efc82a` |
| Tag build run | [43083503847](https://github.com/yagyeshVyas/chromex/actions/runs/43083503847) â€” success |
| Main-branch run | [43083499001](https://github.com/yagyeshVyas/chromex/actions/runs/43083499001) â€” success |
| First green run | [43081155839](https://github.com/yagyeshVyas/chromex/actions/runs/43081155839) â€” success |

## 2. Build infrastructure

| | |
|---|---|
| Runner | GitHub-hosted `macos-15` (arm64) |
| Xcode | 16.4 (`/Applications/Xcode_16.4.app`) |
| iOS SDK | iOS 18.x simulator runtimes, `iphoneos` SDK for device build |
| Project generation | XcodeGen from `project.yml` |
| Compiler | Swift 6 language mode (`SWIFT_VERSION = 6.0`) |
| Signing | disabled for every build: `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=""`, `DEVELOPMENT_TEAM=""`, empty entitlements |

## 3. Pipeline steps observed green

| # | Step | Evidence |
|---|---|---|
| 1 | Check out public repository | run log |
| 2 | Report toolchain | `sw_vers`, `xcodebuild -version` printed |
| 3 | Install XcodeGen | `xcodegen --version` |
| 4 | Generate project | `CHROMEX.xcodeproj` produced |
| 5 | Resolve version | tag `v1.0.1` â†’ `MARKETING_VERSION=1.0.1`, build `10` |
| 6 | Show build settings | signing settings printed as off |
| 7 | Build for `iphoneos` unsigned | `** BUILD SUCCEEDED **` |
| 8 | Unit tests on iPhone simulator | 41 tests, 5 suites, `** TEST SUCCEEDED **` |
| 9 | Package `Payload/` â†’ IPA | `CHROMEX-unsigned.ipa`, 1.3 MB |
| 10 | Verify archive | built-in checks passed |
| 11 | Prove signable + re-identifiable | ad-hoc `codesign --verify` passed; bundle id rewrite passed; artifact SHA unchanged |
| 12 | Upload artifact | `CHROMEX-unsigned-ipa` artifact present |
| 13 | Publish release (tag only) | release v1.0.1 created with asset |

## 4. Independent inspection of the released asset

Performed **outside** CI, on Windows, by downloading the published asset and parsing it with an
independent ZIP/plist parser:

```
sha256        a15857388119653e851af6ccfd14b61ea901b80bc5e4c6191a422e9762efc82a
size          1,345,107 bytes
entries       9
roots         Payload/
app           Payload/CHROMEX.app/
CFBundleIdentifier        com.chromex.browser
CFBundleShortVersionString 1.0.1
CFBundleExecutable        CHROMEX
CFBundleVersion           10
Mach-O magic  0xfeedfacf (64-bit)
CPU type      16777228 (arm64)
signing artifacts         none
```

Full entry list:

```
Payload/
Payload/CHROMEX.app/
Payload/CHROMEX.app/AppIcon60x60@2x.png
Payload/CHROMEX.app/Assets.car
Payload/CHROMEX.app/AppIcon76x76@2x~ipad.png
Payload/CHROMEX.app/PrivacyInfo.xcprivacy
Payload/CHROMEX.app/CHROMEX
Payload/CHROMEX.app/Info.plist
Payload/CHROMEX.app/PkgInfo
```

Absent, as required: `_CodeSignature/`, `embedded.mobileprovision`, `CodeResources`, any `.p12`
or `.cer`, any `Frameworks/`, any `PlugIns/`, any `__MACOSX` entry.

## 5. Signing proof

The pipeline performs two checks on the published artifact, on the macOS runner, after the IPA
is built:

1. **Ad-hoc signing** â€” extracts the app, applies `codesign --force --sign -`, and runs
   `codesign --verify --deep --strict`. This proves the bundle is structurally signable and that
   no stale or partial signature blocks re-signing. It uses no certificate and no profile.
2. **Identifier rewrite** â€” copies the IPA, runs `Scripts/set_bundle_id.sh` for
   `com.chromex.signingprobe`, re-parses the resulting `Info.plist`, and asserts the identifier
   changed. It then re-hashes the published IPA to prove the probe did not mutate it.

This is the strongest verification possible without a personal Apple certificate. Signing with a
real identity and profile is, by design, the end user's step â€” see `SIGNING-GUIDE.md`.

## 6. Test coverage

`Tests/CoreTests.swift` â€” 41 tests in 5 suites, all passing on an iOS simulator:

| Suite | What it pins |
|---|---|
| `URLResolverTests` | URL vs. search decisions, scheme handling, localhost, display form |
| `HostMatcherTests` | `<all_urls>`, wildcards, scheme matching, non-web rejection |
| `ManifestTests` | MV2/MV3 parsing, host-permission splitting, analyzer verdicts, grants |
| `PackageTests` | ZIP extraction, traversal/deep-path rejection, CRX3 payload, staging, missing manifest |
| `AdBlockRuleTests` | Adblockâ†’regex translation, exceptions, cosmetic rules, JSON shape, built-in list |

Not covered by automated tests: SwiftUI layout, WebKit runtime behaviour, extension messaging
end-to-end. Those require a signed device build and are listed in Â§7.

## 7. What this verification does **not** claim

| Claim | Status |
|---|---|
| The app launches on a physical iPhone | **Not verified here.** Requires a signed build with a device profile. The artifact is unsigned by design |
| A specific third-party extension runs | **Not verified here.** Needs on-device testing; compatibility is described structurally in `EXTENSION-COMPATIBILITY.md` |
| App Store review would pass | **Not claimed.** Distribution is via independent signing |
| iPad-specific layout quality | **Not verified.** The app is iPhone-first and runs on iPad in compatibility layout |
| Every advertised API behaves exactly as documented | **Partially verified.** The pure logic is unit-tested; WebKit-facing behaviour needs manual device testing |

These are stated plainly because an unsigned-distribution project that overstates verification
is worse than one that does not.

## 8. Reproduce this verification

```bash
gh run download 43083503847 -n CHROMEX-unsigned-ipa
shasum -a 256 CHROMEX-unsigned.ipa          # compare with Â§1
unzip -l CHROMEX-unsigned.ipa               # compare with Â§4
bash Scripts/verify_ipa.sh CHROMEX-unsigned.ipa
```

Or rebuild from the tag:

```bash
git checkout v1.0.1
brew install xcodegen && xcodegen generate
xcodebuild -project CHROMEX.xcodeproj -scheme CHROMEX -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  PRODUCT_BUNDLE_IDENTIFIER=com.chromex.browser \
  MARKETING_VERSION=1.0.1 CURRENT_PROJECT_VERSION=1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
bash Scripts/package_ipa.sh build/Build/Products/Release-iphoneos/CHROMEX.app CHROMEX-unsigned.ipa
bash Scripts/verify_ipa.sh CHROMEX-unsigned.ipa
```

Byte-identical output is not guaranteed across Xcode versions; the structural guarantees in Â§4
are.

