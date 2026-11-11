# CHROMEX — Build Guide

Everything here runs on **GitHub Actions macOS runners**. You never need a Mac, and you
never need to install Xcode locally.

---

## 1. What the pipeline does

`.github/workflows/ios-build.yml` runs on every push to `main`, every pull request, every tag,
and on demand:

1. checks out the public repository;
2. installs XcodeGen (the only build dependency);
3. generates `CHROMEX.xcodeproj` from `project.yml`;
4. builds the app for `iphoneos` with code signing disabled;
5. runs the unit tests on an iOS simulator;
6. packages `Payload/CHROMEX.app` into `CHROMEX-unsigned.ipa`;
7. verifies the archive is arm64, has a valid `Info.plist`, and contains **no** signature,
   provisioning profile, or signing material;
8. uploads the IPA as an artifact;
9. publishes it to GitHub Releases when the run is a `v*` tag.

No signing identity, certificate, profile, or Apple account is present anywhere in the
repository or the workflow.

---

## 2. Trigger a build without changing code

```bash
gh workflow run ios-build.yml          # default bundle id: com.chromex.browser
gh workflow run ios-build.yml -f bundle_id=com.yourname.chromex
```

Or use the Actions tab → **iOS unsigned build** → **Run workflow**.

The queue time on a hosted macOS runner is usually 1–5 minutes; the build itself is 3–6 minutes.

## 3. Get the artifact

```bash
# latest run's artifact
gh run list --workflow=ios-build.yml --limit 1
gh run download <run-id> -n CHROMEX-unsigned-ipa
```

Or download it from the run page in the Actions tab. Tagged builds also appear under
**Releases**.

---

## 4. Local build (optional)

You only need this if you have a Mac and want a faster loop. The Windows-only path is the
workflow above.

```bash
brew install xcodegen
xcodegen generate
xcodebuild \
  -project CHROMEX.xcodeproj \
  -scheme CHROMEX \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

bash tools/package_ipa.sh build/Build/Products/Release-iphoneos/CHROMEX.app CHROMEX-unsigned.ipa
bash tools/verify_ipa.sh CHROMEX-unsigned.ipa
```

Unit tests locally:

```bash
xcodebuild test -project CHROMEX.xcodeproj -scheme CHROMEX \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## 5. Project layout

```
project.yml                 XcodeGen spec — the only project definition
App/Info.plist              bundle metadata (no entitlements)
App/CHROMEXApp.swift        SwiftUI entry point
App/Sources/Core/           pure logic: models, URL parsing, manifests, packages, filter rules
App/Sources/Browser/        WKWebView tabs, app model, content blocker
App/Sources/Extensions/     Chromex Runtime: shim, scheme handler, background pages, manager
App/Sources/UI/             SwiftUI screens
App/Resources/              asset catalogue and privacy manifest
Tests/                      unit tests (Foundation-only core)
tools/                      packaging, verification, bundle-id rewrite, icon generation
```

The test target compiles the Foundation-only core directly, so it needs no host app and no
WebKit. That is deliberate: it means tests run in seconds and cannot be blocked by UI state.

---

## 6. Changing the bundle identifier

Three options, in increasing order of usefulness to other people:

| Who | How |
|---|---|
| You, at build time | `gh workflow run ios-build.yml -f bundle_id=com.yourname.chromex` |
| You, in the project | edit `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` (one place) |
| Anyone, after download | `bash tools/set_bundle_id.sh CHROMEX-unsigned.ipa com.their.id` |

The app targets a **single bundle** with no nested app extensions, frameworks or app groups.
That is a deliberate trade-off: it makes independent signing dramatically more reliable. See
`UNSIGNED-IPA.md` §4.

---

## 7. When the build fails

| Symptom | Cause | Fix |
|---|---|---|
| `xcodegen: command not found` | Brew step skipped | `brew install xcodegen` |
| `No such module 'SwiftUI'` | Wrong SDK/runner | check `xcodebuild -version`; the workflow needs an iOS SDK |
| `Signing for "CHROMEX" requires a development team` | A signing setting leaked in | confirm the three `CODE_SIGNING_*` flags are present |
| Simulator destination not found | Runner image changed | the workflow selects the first available iPhone simulator; if none exist, update the runner image |
| Tests fail but the app builds | logic regression | run `xcodebuild test` locally with the same destination |
| IPA verification fails | packaging step changed | run `tools/verify_ipa.sh` locally against the artifact |

Build logs are uploaded as `build-logs` when a run fails.

---

## 8. What is intentionally absent

- No CocoaPods, Carthage, or Swift Package dependencies.
- No Fastlane.
- No fastlane match, `ExportOptions.plist`, or archive export step.
- No `xcodebuild archive`/`-exportArchive`: an unsigned IPA is a plain ZIP of `Payload/`, which
  is exactly what independent signing tools expect.
