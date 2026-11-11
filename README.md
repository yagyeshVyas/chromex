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
| Address/search with 6 built-in engines + custom | Working |
| Tabs, tab groups, session restore | Working |
| Private browsing (non-persistent data store) | Working |
| Downloads (to `Documents/Downloads`, Files-visible) | Working |
| Bookmarks, history | Working |
| Desktop mode per tab | Working |
| Per-site camera/mic permission enforcement | Working |
| Ad/tracker blocking (`WKContentRuleList`) | Working |
| Privacy dashboard | Working â€” reports compiled rules and real permissions, not invented counts |
| Extension import: ZIP / folder / CRX3 | Working |
| Extension compatibility analysis before install | Working |
| Content scripts (JS + CSS, `run_at`, frames) | Working |
| Extension popups | Working |
| `storage.local`, runtime messaging, `tabs.query/create` | Working (documented subset) |
| Extension background pages (non-persistent) | Working while the app runs |
| `webRequest`, `declarativeNetRequest`, cookies, alarms, i18n | Not supported â€” see the matrix |
| Reader mode | Not in this build |
| Extension options pages | Not hosted in this build |
| CRX signature verification | Not performed (no trust anchor) â€” labelled as such |

Nothing in the app is a placeholder presented as complete: unsupported capabilities are listed
in the extension's verdict before install and in the compatibility document.

---

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

---

## Requirements

- iOS 17.0 or later on the device.
- For building: Windows 11 + WSL2, Swift 6.4, xtool, and the xtool Darwin Swift SDK.
- For signing: any Apple ID (free accounts work, with 7-day certificates).
- Optional: a GitHub account, only for the CI verification lane.

---

## Licence

MIT â€” see [LICENSE](LICENSE). Apple's SDKs and WebKit are governed by their own terms.

