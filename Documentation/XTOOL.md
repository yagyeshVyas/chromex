# Building CHROMEX with xtool (primary)

CHROMEX is an xtool SwiftPM project. xtool is the primary build system: it turns
`Package.swift` into an iOS app, and `xtool dev build --ipa` emits the IPA.

The **only** reason this machine cannot produce that IPA today is a missing xtool
prerequisite, documented below with the exact command output.

---

## 1. Project shape (matches xtool's own template)

`xtool new Probe --skip-setup` on xtool 1.24.0 produces:

```
Package.swift      swift-tools-version 6.0, one *library* product, one target
xtool.yml          version: 1, bundleID
Sources/Probe/     @main SwiftUI App + views
```

CHROMEX follows that exactly:

```
Package.swift            library product "CHROMEX", target path Sources/CHROMEX
xtool.yml                version 1, bundleID com.chromex.browser, product CHROMEX
Sources/CHROMEX/
├── App/                 CHROMEXApp.swift (@main)
├── Browser/             AppModel, BrowserTab, AdBlocker
├── Core/                models, URL resolution, manifest, packaging, filter rules
├── Extensions/          manifest + package formats (Chromex Extensions)
├── ExtensionHub/        Hub UI (currently HubViews.swift in Browser/)
├── ExtensionRuntime/    shim, scheme handler, background runtimes, manager
├── Resources/           privacy manifest (+ asset catalogue, excluded from SwiftPM)
└── UI/                  design system and screens
```

Two deliberate differences from the template:

1. **Asset catalogue excluded from SwiftPM.** `actool` is an Xcode tool; xtool bundles
   resources declared in `xtool.yml`. `Sources/CHROMEX/Resources` is excluded from the
   SwiftPM target and the privacy manifest is listed under `resources:` in `xtool.yml`.
2. **No test target in `Package.swift`.** xtool 1.24 has no `dev test` subcommand
   (`xtool dev --help` lists only `generate-xcode-project`, `build`, `run`,
   `build-server`). The XCTest suite runs in the optional CI lane instead.

## 2. Required toolchain, verified locally

| Requirement | Observed on this machine |
|---|---|
| WSL2 Ubuntu | Ubuntu 24.04.3 LTS, kernel 5.15.167.4-microsoft-standard-WSL2 |
| Swift 6.4 toolchain | `Swift version 6.4.2 (swift-6.4.2-RELEASE)`, target x86_64-linux |
| xtool | `/usr/local/bin/xtool`, `xtool 1.24.0` |
| SwiftPM manifest | `swift package dump-package` parses `Package.swift` successfully |
| `xtool.yml` | present, `version: 1` |
| **Darwin Swift SDK** | **`xtool sdk status` → `Not installed`** |

## 3. The blocker, verbatim

```
$ xtool dev build -c release --ipa
Now generating the Darwin SDK.

Error: Could not read file or directory at path ''.
  See 'xtool help sdk' for usage.
```

`xtool sdk install --help` shows the accepted inputs:

```
USAGE: xtool sdk install <path> [--slim]
ARGUMENTS:
  <path>   Path to Xcode.xip, Xcode.app, or darwin.xtoolsdk
```

There is no `Xcode.xip`, `Xcode.app`, or `darwin.xtoolsdk` on this machine, and
xtool does not publish a standalone SDK asset (its GitHub release contains only the
CLI binaries and dSYM). Building the SDK therefore requires downloading Xcode from
Apple with an authenticated Apple ID.

This is a *prerequisite*, not a bug in CHROMEX.

## 4. One-time fix

1. Download Xcode 27.1 (or current) from
   <https://developer.apple.com/download/all/?q=Xcode> — any Apple ID can download it;
   no paid developer programme is required for the SDK.
2. Install the SDK:

   ```bash
   xtool sdk install /mnt/c/Users/<you>/Downloads/Xcode_27.1.xip --slim
   swift sdk list          # should print: darwin
   ```

3. Verify the project:

   ```bash
   bash Scripts/xtool-check.sh     # exits 0 when ready
   ```

4. Build the unsigned IPA:

   ```bash
   bash Scripts/xtool-build.sh
   # equivalent to:
   xtool dev build -c release --ipa
   ```

## 5. Why the IPA is unsigned

`xtool dev build --help` lists `--sign` as an explicit opt-in:

```
-s, --sign   Codesign the built app
-i, --ipa    Output a .ipa file instead of a .app
```

`Scripts/xtool-build.sh` never passes `--sign`, so the archive contains no signature,
no provisioning profile and no developer identity. It then runs
`Scripts/verify_ipa.sh`, which fails if it finds `_CodeSignature`,
`embedded.mobileprovision`, `CodeResources`, a `.p12` or a `.cer`, and writes a
SHA-256 checksum.

## 6. What is verified today, and what is not

| Claim | Status |
|---|---|
| The project is a valid xtool SwiftPM package | **Verified**: template-matched, `dump-package` parses |
| The Swift sources compile for iOS | **Verified via the optional CI lane** (XcodeGen + xcodebuild), not via xtool |
| `xtool dev build --ipa` produces the app | **Blocked** on the Darwin SDK |
| The published IPA is unsigned | **Verified** for the CI-built artifact (see `VERIFICATION.md`) |

The moment the SDK is installed, `Scripts/xtool-build.sh` is the whole build.

## 7. Why there is still a CI lane

`.github/workflows/ios-build.yml` remains as an **optional** verification/fallback lane.
It is not the development loop and not the documented build command. It exists because,
until the Darwin SDK is installed, it is the only way to prove the Swift sources still
compile and to keep a signed-independent IPA available for testers.
