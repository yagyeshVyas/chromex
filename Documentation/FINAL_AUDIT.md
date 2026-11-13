# Final Audit

**Scope:** entire CHROMEX repository at commit `c7b2490`.
**Method:** source review, static searches, Linux QA harness, iOS-simulator XCTest, artifact inspection.
**Rule applied:** no issue is marked fixed without a passing check; nothing untested is described as working.

---

## 1. Issues found and fixed

| ID | Severity | Location | Root cause | Fix | Verification |
|---|---|---|---|---|---|
| AUD-001 | **High** | `Sources/CHROMEX/Core/ExtensionManifest.swift:80` | `JSONSerialization.jsonObject` was called with `try` out of a `do` block, so malformed manifests threw `NSCocoaErrorDomain 3840` and the UI showed a meaningless message | Catch JSON errors and throw `ManifestError.notAJSONObject` | `ExtensionFixtureTests.testMalformedManifestIsRejected` — passed in CI |
| AUD-002 | Medium | `Sources/CHROMEX/Extensions/ExtensionManager.swift` (token table) | A new capability token was created per injection and never evicted, so a long session grew the dictionary without bound | FIFO cap of 2,000 tokens, oldest evicted | Compiles; CI 57/57. Runtime eviction not device-measured |
| AUD-003 | Medium | `ExtensionManager.injections` / `readText` | Content-script JS/CSS was read from disk **on the main actor on every matching navigation** | Per-extension script cache, warmed at install and on first use, cleared on disable/remove | Compiles; CI 57/57. Latency gain not measured on device |
| AUD-004 | Medium (tooling) | `Scripts/verify_ipa.sh` | Required `file`, `plutil`, `codesign`; failed on WSL after the architecture step | Portable fallbacks: python `plistlib`, Mach-O header parse, `LC_CODE_SIGNATURE` scan, `sha256sum` fallback | Full PASS on WSL against the real artifact |
| AUD-005 | High (tooling) | `Scripts/make_fixtures.py` | The malicious fixture wrote `../../escaped.txt` to disk while *building* the archive | Only `manifest.json` and `evil.js` are written; the traversal entry exists only inside the ZIP | Fixture corpus regenerated; `escaped.txt` confirmed absent |
| AUD-006 | Low | WebKit delegate conformances | `@preconcurrency` is reported as having no effect on the current SDK | Left in place intentionally for older SDK compatibility; documented | Build warnings only |

## 2. Audit checks that passed

| Check | Method | Result |
|---|---|---|
| Crash-inducing constructs | search for `fatalError`, `preconditionFailure` | none |
| Logging of browsing data | search for `print(`, `NSLog(` in shipping sources | none |
| Hardcoded credentials | search for `password =`, `apiKey =`, private-key markers | none in sources; only documentation examples in signing docs |
| Placeholder screens / dead features | search for TODO/FIXME/placeholder | none; the only "not implemented" string is a user-facing API-status message |
| Debug menus | code review | none |
| Extension/native API bridge | code review of runtime module | no UIKit/HealthKit/etc. bridge exists |
| Private browsing isolation | code review | private tabs use `.nonPersistent()` store; history excluded; extensions skip injection |
| Persistence | code review | atomic JSON writes; corrupt state falls back to defaults |
| Entitlements | `Info.plist` + build settings | none declared; unsigned artifact carries none |
| Secrets in repo | `git ls-files` + searches | no `.p12`, `.mobileprovision`, `.cer`, keys |

## 3. Environment findings (not code defects)

| ID | Finding | Impact |
|---|---|---|
| ENV-001 | xtool Darwin SDK absent (`xtool sdk status` → `Not installed`) | xtool build impossible until `xtool sdk install <Xcode.xip>` |
| ENV-002 | Windows detects the iPhone; WSL does not (`usbipd` absent, `usbmuxd` stopped, `idevice_id` fails) | No device install/debug from WSL |
| ENV-003 | No signing credentials used, by policy | Installation of the unsigned artifact is impossible; independent signing required |

## 4. Remaining known issues (not fixed)

| Issue | Reason |
|---|---|
| Extension options pages not hosted | Feature not implemented; analyzer does not claim otherwise |
| CRX signature not verified | No trust anchor for arbitrary developer keys; UI labels packages "signature not verified" |
| `webRequest`, cookies, alarms, i18n, DNR per extension | Platform/engine limits; explicitly reported before install |
| Background execution stops when app is suspended | iOS restriction; MV3 workers run as non-persistent pages |
| Browser runtime behaviour unverified | No signed device build available |
| Screenshots not captured | No simulator/device in this environment |

## 5. Severity summary

| Severity | Found | Fixed | Open |
|---|---:|---:|---:|
| High | 2 | 2 | 0 |
| Medium | 3 | 3 | 0 |
| Low | 1 | 0 | 1 (warning only) |
| Environment blockers | 3 | 0 | 3 |

No high or medium code defects remain open from this audit. The three environment blockers are
outside the repository and are documented in `IPHONE_CONNECTION_REPORT.md` and
`BUILD_VERIFICATION.md`.
