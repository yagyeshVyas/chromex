# CHROMEX

**Your Browser. Your Extensions. Your Rules.**

A native iOS browser built with Swift 6, SwiftUI and WebKit, with its own Chrome-style
extension ecosystem â€” distributed as a **certificate-independent unsigned IPA** that you sign
with your own Apple credentials.

[![iOS unsigned build](https://github.com/yagyeshVyas/chromex/actions/workflows/ios-build.yml/badge.svg)](https://github.com/yagyeshVyas/chromex/actions/workflows/ios-build.yml)

---

## What this is

- A real browser: floating address bar, tabs, tab groups, private browsing, downloads,
  bookmarks, history, desktop mode, custom search engines, per-site permissions, a privacy
  dashboard, and declarative ad/tracker blocking.
- An extension platform: import a `.zip`, `.crx` (CRX3) or unpacked folder, have it analysed
  **before** it runs, then install, disable or remove it. Chromex Hub manages them; Chromex
  Runtime executes them; Chromex Extensions defines the supported surface.
- An artifact anyone can sign: the GitHub Actions pipeline compiles on a macOS runner with
  signing disabled and publishes `CHROMEX-unsigned.ipa`. No certificate, profile, team id, or
  Apple account is involved at any point.

It is **not** desktop Chrome. iOS requires WebKit, and WebKit has no V8 extension host, no
`webRequest` interception and no durable background execution. The supported API surface is
documented precisely in [EXTENSION-COMPATIBILITY.md](EXTENSION-COMPATIBILITY.md), and the app
shows the same list before every install.

---

## Install

1. Download `CHROMEX-unsigned.ipa` from [Releases](https://github.com/yagyeshVyas/chromex/releases) or the latest Actions run.
2. Sign it with your own certificate and profile â€” see [SIGNING-GUIDE.md](SIGNING-GUIDE.md).
3. Install the signed IPA and trust your developer certificate once.

The unsigned file itself will not launch. That is expected; it has no signature by design.

---

## Build it yourself (xtool, Windows + WSL2)

CHROMEX is an xtool SwiftPM project. There is no `.xcodeproj` to open and no Mac required.

```bash
# inside WSL2, from the repository root
bash Scripts/xtool-check.sh      # validates Swift, xtool and the Darwin SDK
xtool dev build -c release --ipa # builds the app and emits an unsigned IPA
bash Scripts/xtool-build.sh      # the same, plus verification and a SHA-256 checksum
```

**Prerequisite:** xtool's Darwin Swift SDK, installed once with
`xtool sdk install /path/to/Xcode.xip --slim`. On this machine that SDK is **not**
installed, which is the one thing blocking a local xtool build; the exact failure and the
fix are recorded in [Documentation/XTOOL.md](Documentation/XTOOL.md).

Detailed build steps, the optional CI lane, and how to change the bundle identifier are in
[BUILD.md](BUILD.md). The archive contract is in [UNSIGNED-IPA.md](UNSIGNED-IPA.md).

---

## Feature status

| Area | Status |
|---|---|
| Chrome-style chrome: tab strip, omnibox row, bookmarks bar, three-dot menu | Working |
| Omnibox with history suggestions and select-all-on-focus | Working |
| Tabs, tab groups, session restore (lazy load) | Working |
| Private browsing (non-persistent data store) | Working |
| Downloads: WebKit downloads, blob/data links, direct links, progress | Working |
| File upload (`<input type="file">`) | Working |
| Find in page, zoom, print, share | Working |
| Desktop mode (desktop Chrome user agent) | Working |
| Site permissions: camera, microphone, location, per-site prompts | Working |
| Bookmarks, history, downloads pages | Working |
| Ad/tracker blocking (`WKContentRuleList`) | Working |
| Extension import: ZIP / folder / CRX3 | Working |
| Install from Chrome Web Store (link or 32-character id, native CRX fetch) | Working |
| Extension popups and options pages (full-height sheet, auto-fit viewport) | Working |
| Content scripts (JS + CSS, `run_at`, frames, ISOLATED + MAIN world) | Working |
| `chrome.runtime` messaging incl. long-lived ports | Working |
| `chrome.storage` local/sync/session + `onChanged` | Working |
| `chrome.tabs`, `chrome.scripting`, `chrome.alarms`, `chrome.action` | Working (subset) |
| `chrome.i18n`, `chrome.permissions` | Working |
| `chrome.cookies` (backed by `WKHTTPCookieStore`) | Working |
| `chrome.notifications` (local notifications) | Working |
| Extension `fetch`/XHR to granted hosts without CORS (native bridge) | Working |
| `chrome.proxy` applied to the extension network bridge | Partial — page traffic stays on the app's network stack |
| `declarativeNetRequest` block/allow rules compiled to content blockers | Partial — redirect/modifyHeaders not enforced |
| `webRequest` observation or blocking | Not supported — WebKit exposes no request hook |
| `identity`, `debugger`, `nativeMessaging`, `offscreen` documents | Not supported / stubbed |

Nothing in the app is a placeholder presented as complete: unsupported capabilities are listed
in the extension's verdict before install and in the compatibility document.

## Repository layout

```
project.yml               legacy XcodeGen definition (optional CI lane only)
xtool.yml                 xtool app configuration: bundleID, product, resources
Package.swift             xtool SwiftPM package (library product, Swift 6)
Sources/CHROMEX/Core/         pure logic â€” models, URL resolution, manifests, ZIP/CRX, filter rules
Sources/CHROMEX/Browser/      WKWebView tabs, browser state, content blocker
Sources/CHROMEX/Extensions/   Chromex Runtime â€” shim, scheme handler, background pages, bridge
Sources/CHROMEX/UI/           SwiftUI screens and design system
Tests/                    unit tests for the pure core
Scripts/                    packaging, IPA verification, bundle-id rewrite, icon generation
.github/workflows/        macOS build â†’ verify â†’ artifact â†’ release
```

Architecture in one sentence: SwiftUI renders state owned by `AppModel`; every tab is one
`WKWebView`; extensions are JavaScript in an isolated context talking to native through a
token-scoped message bridge; blocking is a compiled WebKit rule list because that is the only
interception primitive iOS provides.

---

## Documentation

| Document | Purpose |
|---|---|
| [BUILD.md](BUILD.md) | xtool build pipeline, WSL setup, iPhone testing |
| [Documentation/XTOOL.md](Documentation/XTOOL.md) | xtool project shape, verified toolchain, SDK blocker |
| [UNSIGNED-IPA.md](UNSIGNED-IPA.md) | What unsigned means, archive contract, identifiers |
| [SIGNING-GUIDE.md](SIGNING-GUIDE.md) | Signing tools, bundle-id changes, install, error diagnosis |
| [EXTENSION-COMPATIBILITY.md](EXTENSION-COMPATIBILITY.md) | Exact supported API surface |
| [SECURITY.md](SECURITY.md) | Threat model, bridge tokens, reporting |
| [VERIFICATION.md](VERIFICATION.md) | What was actually built, tested, and inspected â€” with hashes |
| [QA/REPORT.md](QA/REPORT.md) | QA audit: executed tests, extension results, defects, performance, readiness |
| [RELEASE.md](RELEASE.md) | Metadata, privacy disclosures, App Store checklist, TestFlight, release notes |
| [Documentation/FINAL_AUDIT.md](Documentation/FINAL_AUDIT.md) | Issues found, severity, fixes, verification |
| [Documentation/IPHONE_CONNECTION_REPORT.md](Documentation/IPHONE_CONNECTION_REPORT.md) | Device detection status and WSL passthrough steps |
| [Documentation/BUILD_VERIFICATION.md](Documentation/BUILD_VERIFICATION.md) | xtool vs CI build evidence |
| [Documentation/UNSIGNED_IPA_VERIFICATION.md](Documentation/UNSIGNED_IPA_VERIFICATION.md) | Why the artifact is unsigned, with checks |
| [Documentation/DEVICE_INSTALLATION_REPORT.md](Documentation/DEVICE_INSTALLATION_REPORT.md) | Why installation is blocked and what it needs |
| [Documentation/EXTENSION_TEST_REPORT.md](Documentation/EXTENSION_TEST_REPORT.md) | Extension results and compatibility matrix |
| [Documentation/FINAL_TEST_REPORT.md](Documentation/FINAL_TEST_REPORT.md) | 57 XCTest + 35 Linux checks, and the untested list |
| [Documentation/RELEASE_GUIDE.md](Documentation/RELEASE_GUIDE.md) | Build, verify, sign, install, checklist |

---

## Current status (2026-11-11)

| Area | Status |
|---|---|
| Swift compilation for iOS | **Pass** — Xcode 16.4, CI run 43089913502 |
| Automated tests | **64/64 pass** on simulator; 35/35 Linux QA checks |
| Unsigned IPA | **Released v1.1.0** — [GitHub release](https://github.com/yagyeshVyas/chromex/releases/tag/v1.1.0), SHA-256 `d74f46f9…ac11425f`, copy in `dist/` |
| xtool build | **Blocked** — Darwin Swift SDK not installed (`xtool sdk install <Xcode.xip>`) |
| iPhone from WSL | **Blocked** — Windows sees it; WSL needs `usbipd` passthrough and `usbmuxd` |
| Device installation | **Pass** — build 35 installed on iPhone16,2 / iOS 27.2; launched (PID 96905), no crash report |
| Browser/extension runtime testing | **Not run** — app launches, but UI interaction was not exercised |

## Known issues

- iOS requires WebKit. There is no Blink, no V8, and no JIT entitlement for third-party
  apps, so "the same engine as desktop Chrome" is not reachable on this platform.
- `webRequest` blocking and observation cannot be provided: WebKit gives browsers no
  per-request hook. Extensions that depend on it will only partially work.
- `chrome.proxy` settings are honoured for extension background requests made through the
  native bridge; page traffic still uses the app's network stack.
- `declarativeNetRequest` block/allow rules work; redirect, modifyHeaders and priority
  ordering are not enforced.
- `chrome.identity`, `chrome.debugger`, `nativeMessaging` and real offscreen documents are
  not implemented; calls are stubbed so extensions fail gracefully.
- Background execution stops when iOS suspends the app; alarms only run while the app runs.
- Extension pages are served over a custom scheme. Secure-context-only APIs that WebKit
  withholds from custom schemes are shimmed (`crypto.subtle` SHA-256/HMAC,
  `navigator.userAgentData`, `navigator.clipboard`).
- Wide desktop popups are scaled to fit the phone viewport.

## Troubleshooting

| Problem | Fix |
|---|---|
| `xtool dev build` says `Could not read file or directory at path ''` | Install the Darwin SDK: `xtool sdk install /path/to/Xcode.xip --slim` |
| `xtool devices` prints nothing | Install `usbipd-win`, attach the iPhone to WSL, start `usbmuxd` |
| `idevice_id -l` fails in WSL | Same as above; confirm the phone shows in Windows device manager |
| `verify_ipa.sh` fails | Run it from the repo root on the artifact; see `Documentation/UNSIGNED_IPA_VERIFICATION.md` |
| Signing error on device | `SIGNING-GUIDE.md` §12 error table |

---

## Requirements

- iOS 17.0 or later on the device.
- For building: Windows 11 + WSL2, Swift 6.4, xtool, and the xtool Darwin Swift SDK.
- For signing: any Apple ID (free accounts work, with 7-day certificates).
- Optional: a GitHub account, only for the CI verification lane.

---

## Licence

MIT â€” see [LICENSE](LICENSE). Apple's SDKs and WebKit are governed by their own terms.

