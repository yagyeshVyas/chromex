# Extension Test Report

**Date:** 2026-11-11
**Scope:** Chromex Extensions / Chromex Hub / Chromex Runtime
**Verdict:** import, containment and analysis are **tested and pass**; extension *execution*
(injection, popups, storage round-trips, messaging) is **implemented but not executed** — no signed
device build was available. No extension is claimed as fully working.

---

## 1. What was executed

`Tests/ExtensionFixtureTests.swift` — 16 XCTest cases over 13 generated packages, on the iOS
simulator, all passing in CI. The corpus is produced by `Scripts/make_fixtures.py`.

| Fixture | Purpose | Observed result |
|---|---|---|
| `basic-content` | MV3 content script | staged, `runs`, 1 script |
| `dark-mode` | CSS + JS injection | staged, `runs`, CSS declared |
| `ad-blocker` | DNR ruleset | staged, `runs-with-limits`, DNR unsupported, broad access |
| `popup` | action popup | staged, `runs`, popup path parsed |
| `storage` | MV3 service worker + storage | staged, `runs` |
| `messaging` | content ↔ background | staged, `runs`, background script parsed |
| `background-mv2` | MV2 background scripts | staged, `runs`, MV2 split correct |
| `permission-restricted` | narrow host grant | one consent pattern exactly |
| `unsupported-api` | alarms + cookies | `runs-with-limits`, both listed |
| `broad-access` | `<all_urls>` | flagged as broad access |
| `malformed` | invalid JSON | rejected with typed `ManifestError` |
| `missing-manifest` | no manifest | rejected with `PackageError.missingManifest` |
| `malicious-traversal` | `../../escaped.txt` | rejected with `PackageError.pathTraversal` |

Additional executed tests: CRX2 rejection, quarantine containment (no file outside the staging
directory), and archive structure.

## 2. Compatibility matrix

Status reflects **code plus tests**, not a device run.

| Capability | Status | Evidence |
|---|---|---|
| Manifest V3 parsing | **Supported** | parser + analyzer tests |
| Manifest V2 parsing | **Supported** | MV2 fixture test |
| Host permission splitting (V2) | **Supported** | test |
| ZIP package import | **Supported** | 12 staged fixtures |
| Unpacked folder import | **Implemented, not executed** | code path uses document picker |
| CRX3 payload extraction | **Supported (structural)** | unit test; signature not verified |
| CRX2 | **Rejected** | test |
| Path traversal / bombs / caps | **Supported** | rejection tests |
| Content scripts — JS | **Implemented, not executed** | injection built as `WKUserScript` |
| Content scripts — CSS | **Implemented, not executed** | style injection source |
| `run_at` / `all_frames` | **Implemented, not executed** | mapped to injection time |
| Popup UI | **Implemented, not executed** | sheet + `chromex-extension://` |
| Background page (MV2/MV3) | **Implemented, not executed** | hidden `WKWebView` |
| `chrome.storage.local` | **Implemented, not executed** | JSON store per extension |
| `chrome.storage.sync/session` | **Partial** | aliased to local |
| `chrome.runtime.sendMessage` | **Implemented, not executed** | token-scoped bridge |
| `chrome.tabs.query/create` | **Partial** | active tab only; URL gated by grants |
| `chrome.scripting.executeScript` | **Unsupported** | reported by analyzer |
| `chrome.action` badge | **Unsupported** | no badge surface |
| `chrome.declarativeNetRequest` | **Unsupported per extension** | built-in blocker only |
| `chrome.webRequest` | **Unsupported** | no WebKit hook |
| `chrome.cookies` | **Unsupported** | not exposed |
| `chrome.i18n` | **Unsupported** | `_locales` not resolved |
| `chrome.alarms` | **Unsupported** | no durable scheduler |
| Extension options page | **Unsupported (not hosted)** | parsed but no UI |
| Extension identifiers | **N/A** | no app extensions; single bundle |

## 3. Security results

| Test | Result |
|---|---|
| ZIP traversal | rejected before write |
| Absolute path | rejected |
| Deep path (>16) | rejected |
| Entry-count / size / ratio caps | enforced |
| Encrypted entries | rejected |
| Malformed manifest | rejected with typed error (defect fixed this phase) |
| Broad host access | flagged in verdict and consent |
| Extension ↔ native API | no bridge in runtime; inspection only |
| Cross-extension storage | per-extension token + directory; **not executed** |
| Private browsing | extensions skip injection entirely (code path) |

## 4. What remains untested

Everything that requires WebKit execution: real content-script injection, popup rendering, storage
round-trips, message routing, background suspension behaviour, cross-extension access attempts, and
malicious JavaScript containment. The fixture packages are ready in `QA/fixtures/zips/` for that run.

**To close this:** install a signed build on the iPhone, import each fixture from Files, and record
observed behaviour in the runtime columns. Until then the classification stays *partially compatible*.
