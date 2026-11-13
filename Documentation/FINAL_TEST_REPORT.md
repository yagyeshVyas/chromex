# Final Test Report

**Date:** 2026-11-11
**Commit:** `c7b2490` — CI run [43089913502](https://github.com/yagyeshVyas/chromex/actions/runs/43089913502)
**Result:** 57/57 automated tests pass on the iOS simulator; 35/35 Linux QA checks pass. **No device tests were run.**

---

## 1. Automated — XCTest on iOS simulator

Command (CI):

```bash
xcodebuild test -project CHROMEX.xcodeproj -scheme CHROMEX \
  -destination "platform=iOS Simulator,name=<first iPhone>" \
  CODE_SIGNING_ALLOWED=NO
```

Evidence from the run log: `Executed 57 tests, with 0 failures (0 unexpected)` and
`** TEST SUCCEEDED **`.

| Suite | Tests | Expected | Actual | Result |
|---|---:|---|---|---|
| URLResolverTests | 9 | URL vs search, schemes, localhost, IPv4, display form | as expected | **Pass** |
| HostMatcherTests | 6 | wildcard/scheme/`<all_urls>` semantics | as expected | **Pass** |
| ManifestTests | 8 | MV2/MV3 parsing, host split, typed errors, analyzer verdicts | as expected | **Pass** |
| PackageTests | 10 | ZIP extraction, traversal/depth rejection, CRX3/CRX2, staging | as expected | **Pass** |
| AdBlockRuleTests | 7 | rule translation, exceptions, cosmetic rules, JSON shape | as expected | **Pass** |
| ExtensionFixtureTests | 16 | 13-package corpus through the real import pipeline | as expected | **Pass** |
| **Total** | **57** | | | **0 failures** |

## 2. Automated — Linux QA harness

Command: `bash Scripts/qa-linux.sh`

- **35 assertions, 0 failures** over URL resolution, host matching, filter rules, 12 fixture
  manifests, and permission invariants.
- Benchmarks measured: URL 0.0097 ms/op, manifest parse 0.0066 ms/op, analyze 0.0116 ms/op,
  built-in filter parse 0.744 ms/op.
- 12 compatibility reports written to `QA/reports/`.

## 3. Failures during this cycle (recorded, not hidden)

| Failure | Expected | Actual | Fix | Re-run |
|---|---|---|---|---|
| `testMalformedManifestIsRejected` | `ManifestError.notAJSONObject` | `NSCocoaErrorDomain 3840` | Parser now catches JSON errors (AUD-001) | Passed |

No other test failures occurred in the final run. Earlier runs also failed for build-configuration
reasons (missing main entry point, wrong simulator destination, missing test fixture type); those
were pipeline defects, fixed and verified by subsequent green runs.

## 4. Not run — device tests

These require a signed build on the iPhone. None was performed.

| Area | Status |
|---|---|
| Installation and launch | **Pass** — installed, PID 70343 alive, no crash log |
| Launch, startup crash, first-run UI | **Launch verified; UI not exercised** |
| Navigation, HTTPS, JS-heavy sites, auth, cookies | **Not run** |
| Tabs, tab groups, restoration | **Not run** |
| Downloads, bookmarks, history | **Not run** |
| Private browsing, desktop mode, search-engine switching | **Not run** |
| Network interruption, WebKit process crash recovery | **Not run** |
| Extension injection, popup, storage, messaging on device | **Not run** |
| Memory, CPU, battery, launch time | **Not measured** |
| UI layout, safe areas, keyboard, accessibility | **Not run** |

Reason: the artifact is unsigned, no signing credentials were used, xtool's SDK is missing, and WSL
cannot reach the iPhone. See `DEVICE_INSTALLATION_REPORT.md`.

## 5. Classification of evidence

| Class | Meaning | Count this cycle |
|---|---|---|
| Automated, executed | XCTest / harness, reproducible | 57 + 35 |
| Simulator, executed | iOS simulator runtime | 57 |
| Device, executed | physical iPhone | **0** |
| Static review | code inspection only | audit items |

## 6. How to reproduce

```bash
bash Scripts/qa-linux.sh                      # 35 checks + benchmarks (needs Swift on Linux)
gh workflow run ios-build.yml                 # 57 XCTest on a macOS runner
gh run watch                                  # observe TEST SUCCEEDED
bash Scripts/verify_ipa.sh dist/CHROMEX-unsigned.ipa
```

Once a signed build exists, the device checklist in `RELEASE.md` §7 is the next test pass; results
should be appended here rather than assumed.
