# Build Verification

**Date:** 2026-11-11
**Result:** Swift sources compile and all tests pass on the CI lane. The **xtool build is blocked** by a
missing Darwin SDK, so the xtool path remains unverified.

---

## 1. Toolchain observed

| Component | Version / status |
|---|---|
| WSL | Ubuntu 24.04.3 LTS, kernel 5.15.167.4-microsoft-standard-WSL2 |
| Swift (Linux) | 6.4.2 (`swift-6.4.2-RELEASE`), x86_64 |
| xtool | 1.24.0 at `/usr/local/bin/xtool` |
| xtool Darwin SDK | **Not installed** (`xtool sdk status`) |
| Xcode (CI) | 16.4 on `macos-15` |
| Disk | 949 GB free |

## 2. xtool build attempt

Commands executed exactly as documented:

```bash
xtool sdk status
# Not installed

xtool dev build -c release --ipa
# Now generating the Darwin SDK.
# Error: Could not read file or directory at path ''.
```

`xtool sdk install --help` accepts only `Xcode.xip`, `Xcode.app`, or a `darwin.xtoolsdk`. None exist on
this machine, and xtool's GitHub release ships only the CLI. **This is an external blocker, not a
project defect.** Fix: `xtool sdk install /path/to/Xcode.xip --slim`.

Project-side validation that *did* run:

```bash
swift package dump-package    # parses; library product CHROMEX, iOS 17
bash Scripts/xtool-check.sh   # package/xtool.yml valid; exits 12 on the SDK
```

## 3. CI build (optional lane, executed)

Run [43089913502](https://github.com/yagyeshVyas/chromex/actions/runs/43089913502), commit
`c7b2490`, macOS 15, Xcode 16.4:

| Step | Result |
|---|---|
| XcodeGen project generation | pass |
| `xcodebuild -sdk iphoneos` with signing disabled | `** BUILD SUCCEEDED **` |
| Unit tests on iPhone simulator | **57 tests, 0 failures** |
| Package `Payload/` → IPA | pass |
| Unsigned verification | pass |
| Ad-hoc signing + identifier-rewrite probe | pass |
| Artifact upload | pass |

Build settings confirmed in the log: `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`,
`CODE_SIGN_IDENTITY=""`, empty `DEVELOPMENT_TEAM`, no entitlements file.

## 4. Warnings

- `@preconcurrency` on `WKNavigationDelegate` / `WKUIDelegate` / `WKURLSchemeHandler` conformances is
  reported as having no effect on this SDK. Harmless; the protocols are already main-actor annotated.
  Left in place for compatibility with older SDKs.
- No compiler errors. Warnings are not treated as errors, deliberately, so a runner SDK change does
  not break the build for a non-semantic warning.

## 5. Commands

```bash
# Linux QA (works now)
bash Scripts/qa-linux.sh

# CI build (works now)
gh workflow run ios-build.yml

# xtool build (blocked until SDK installed)
xtool sdk install /path/to/Xcode.xip --slim
xtool dev build -c release --ipa
bash Scripts/xtool-build.sh
```

## 6. Verdict

| Question | Answer |
|---|---|
| Do the Swift sources compile for iOS? | **Yes**, verified on Xcode 16.4 |
| Do tests pass? | **Yes**, 57/57 |
| Does xtool build this project? | **Unverified** — blocked on the SDK |
| Is the IPA produced by xtool? | **No**; the artifact came from the CI lane |

The xtool path must be re-verified after `xtool sdk install`; nothing in this report claims otherwise.
