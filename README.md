# CHROMEX

**Your Browser. Your Extensions. Your Rules.**

A native iOS browser built with Swift 6, SwiftUI and WebKit, with its own Chrome-style
extension ecosystem — distributed as a **certificate-independent unsigned IPA** that you sign
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

1. Download `CHROMEX-unsigned.ipa` from [Releases](../../releases) or the latest Actions run.
2. Sign it with your own certificate and profile — see [SIGNING-GUIDE.md](SIGNING-GUIDE.md).
3. Install the signed IPA and trust your developer certificate once.

The unsigned file itself will not launch. That is expected; it has no signature by design.

---

## Build it yourself

Everything runs on GitHub's macOS runners. No Mac, no local Xcode.

```bash
gh workflow run ios-build.yml
gh run download --name CHROMEX-unsigned-ipa
```

Full details, including how to change the bundle identifier at build time, are in
[BUILD.md](BUILD.md). The archive contract and identifier strategy are in
[UNSIGNED-IPA.md](UNSIGNED-IPA.md).

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
| Privacy dashboard | Working — reports compiled rules and real permissions, not invented counts |
| Extension import: ZIP / folder / CRX3 | Working |
| Extension compatibility analysis before install | Working |
| Content scripts (JS + CSS, `run_at`, frames) | Working |
| Extension popups | Working |
| `storage.local`, runtime messaging, `tabs.query/create` | Working (documented subset) |
| Extension background pages (non-persistent) | Working while the app runs |
| `webRequest`, `declarativeNetRequest`, cookies, alarms, i18n | Not supported — see the matrix |
| Reader mode | Not in this build |
| Extension options pages | Not hosted in this build |
| CRX signature verification | Not performed (no trust anchor) — labelled as such |

Nothing in the app is a placeholder presented as complete: unsupported capabilities are listed
in the extension's verdict before install and in the compatibility document.

---

## Repository layout

```
project.yml               XcodeGen project definition (the only project file)
App/Sources/Core/         pure logic — models, URL resolution, manifests, ZIP/CRX, filter rules
App/Sources/Browser/      WKWebView tabs, browser state, content blocker
App/Sources/Extensions/   Chromex Runtime — shim, scheme handler, background pages, bridge
App/Sources/UI/           SwiftUI screens and design system
Tests/                    unit tests for the pure core
tools/                    packaging, IPA verification, bundle-id rewrite, icon generation
.github/workflows/        macOS build → verify → artifact → release
```

Architecture in one sentence: SwiftUI renders state owned by `AppModel`; every tab is one
`WKWebView`; extensions are JavaScript in an isolated context talking to native through a
token-scoped message bridge; blocking is a compiled WebKit rule list because that is the only
interception primitive iOS provides.

---

## Documentation

| Document | Purpose |
|---|---|
| [BUILD.md](BUILD.md) | CI pipeline, local builds, troubleshooting |
| [UNSIGNED-IPA.md](UNSIGNED-IPA.md) | What unsigned means, archive contract, identifiers |
| [SIGNING-GUIDE.md](SIGNING-GUIDE.md) | Signing tools, bundle-id changes, install, error diagnosis |
| [EXTENSION-COMPATIBILITY.md](EXTENSION-COMPATIBILITY.md) | Exact supported API surface |
| [SECURITY.md](SECURITY.md) | Threat model, bridge tokens, reporting |

---

## Requirements

- iOS 17.0 or later on the device.
- For building: a GitHub account (Actions), or a Mac with Xcode 16+ and XcodeGen.
- For signing: any Apple ID (free accounts work, with 7-day certificates).

---

## Licence

MIT — see [LICENSE](LICENSE). Apple's SDKs and WebKit are governed by their own terms.
