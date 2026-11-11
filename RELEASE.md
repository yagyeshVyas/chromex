# CHROMEX — Release Preparation

This document contains the release metadata, App Store compliance checklist, privacy
disclosures, TestFlight instructions and release notes. It distinguishes what is prepared from
what still requires an Apple account or a signed device.

---

## 1. Application metadata

| Field | Value |
|---|---|
| Name | CHROMEX |
| Subtitle | Your Browser. Your Extensions. Your Rules. |
| Bundle identifier | `com.chromex.browser` (configurable — see `UNSIGNED-IPA.md` §4) |
| Version | 1.0.1 (build derived from CI run number) |
| Primary category | Utilities |
| Secondary category | Productivity |
| Age rating | **17+** — unrestricted web access, user-installed software |
| Minimum iOS | 17.0 |
| Supported devices | iPhone, iPad (compatibility layout) |
| Encryption | `ITSAppUsesNonExemptEncryption = false` (HTTPS only via WebKit) |
| Languages | English |

**Description (short):** A native iPhone browser with its own extension platform. Import a
`.zip`, `.crx` or folder, see exactly what will work, then run it.

**Description (long):** CHROMEX is built on WebKit, as iOS requires. It has tabs, tab groups,
private browsing, downloads, bookmarks, history, desktop mode, custom search engines, per-site
permissions, a privacy dashboard and declarative ad/tracker blocking. Its differentiator is the
extension platform: Chromex Hub imports packages from your own device, Chromex Runtime runs the
documented subset of the Chrome extension APIs that iOS can support, and every package is
analysed before installation so you know which parts will not work.

**Keywords:** browser, extensions, privacy, adblock, webkit, tabs, private browsing.

## 2. App icon and launch screen

| Asset | Status |
|---|---|
| App icon | Generated (`Scripts/make_icon.py`) into `Assets.xcassets/AppIcon.appiconset` — 1024×1024 |
| Launch screen | `UILaunchScreen` with `LaunchBackground` colour (graphite) in `App/Info.plist` |
| Accent colour | `AccentColor` = electric blue |

## 3. Privacy disclosures

### Data collection

**None.** CHROMEX contains no analytics SDK, no crash-reporting SDK, no advertising SDK, and no
server. It does not transmit URLs, titles, searches, or browsing history anywhere.

| Data | Stored where | Leaves the device? |
|---|---|---|
| Browsing history | app container (JSON) | No |
| Bookmarks, reading list | app container | No |
| Downloads | `Documents/Downloads` | Only if the user shares them |
| Site permission decisions | app container | No |
| Extension packages and storage | app container | No |
| Cookie and website data | WebKit data store | No |

### Privacy manifest

`Sources/CHROMEX/Resources/PrivacyInfo.xcprivacy` declares:

- `NSPrivacyTracking = false`, no tracking domains, no collected data types;
- accessed API reasons: UserDefaults (`CA92.1`), file timestamps (`C617.1`), disk space (`E174.1`).

### Network activity

Page loads and downloads are user-initiated. An installed extension may make network requests
from its own context; CHROMEX cannot see or filter those, and the extension's permissions are
shown before install.

## 4. Permission explanations

CHROMEX requests **no** permission at launch.

| Permission | When it is requested | Explanation shown |
|---|---|---|
| Camera | A website calls `getUserMedia` and you have allowed that site | "This site wants to use your camera." |
| Microphone | Same | "This site wants to use your microphone." |
| Location / notifications | Mediated by WebKit and iOS | System prompt |
| Extension host access | At install, per pattern | "Read and change data on matching sites" |
| Clipboard read | Only through an extension declaring `clipboardRead` (risk tier: critical) | Consent sheet |

No photo-library, contacts, health, motion, Bluetooth, or tracking permission is used.

## 5. App Store review compliance checklist

| Guideline | Requirement | CHROMEX position |
|---|---|---|
| 2.5.6 | Browsers must use WebKit | Fully compliant — `WKWebView` only, no alternative engine |
| 2.5.2 | No downloaded code that changes app functionality | Extensions are JavaScript against browser APIs; app shell is fixed. Review notes must state this |
| 4.7 | Software not embedded in the binary | Extensions are user-imported HTML/JS. Hub provides an index, reporting path and age-rating field |
| 4.7.2 | No native platform APIs exposed to offered software | Architectural firewall: the runtime has no bridge to UIKit/HealthKit/etc. |
| 4.7.3 | No sharing privacy permissions without per-instance consent | Host access is granted per pattern at install |
| 4.7.4 | Index of software | Chromex Hub lists every installed extension with version and permissions |
| 4.7.5 | Age restriction mechanism | 17+ rating; extension metadata carries an age-rating field |
| 5.1.1 | Data collection disclosure | No collection; privacy label = "Data Not Collected" |
| 5.1.2 | Data sharing | None |
| 1.2 | User-generated content | No hosted UGC; reporting exists for extensions |

### Review notes draft

> CHROMEX is a WebKit browser. Extension support uses a browser-side WebExtensions-compatible
> runtime: packages the user selects from Files are parsed and analysed, then run with browser
> APIs only. Extensions cannot access any native iOS framework. Every capability is granted per
> extension with an explicit consent sheet, and the app lists each installed extension with its
> permissions.

Attach: a demo extension package, a screen recording of import → verdict → install, and
`EXTENSION-COMPATIBILITY.md`.

## 6. Screenshots

App Store requires 6.9" and 6.5" iPhone screenshots (and iPad if supported). They must be
captured from a running build.

Prepared script for a Mac/simulator environment:

```bash
bash Scripts/capture-screenshots.sh
```

**Status: not captured.** This environment has no simulator or signed device. The script is
provided so the step is one command on a machine that does.

## 7. TestFlight instructions

Requires a paid Apple Developer Program membership.

1. In App Store Connect, create the app record with bundle id `com.chromex.browser`.
2. On a Mac with Xcode, or with `xtool` + your certificate:
   - `xtool dev build -c release --sign`, or
   - archive with Xcode and upload.
3. Upload to App Store Connect (Xcode Organizer or `xcrun altool`).
4. Add internal testers; TestFlight builds expire after 90 days.
5. Provide testers with: import a fixture from `QA/fixtures/zips`, open
   `https://example.com`, toggle desktop mode, open a private tab.

## 8. Release notes (v1.0.1)

> **CHROMEX 1.0.1**
>
> - WebKit browser with tabs, tab groups, private browsing, downloads, bookmarks and history.
> - Chromex Hub: import `.zip`, `.crx` (CRX3) and unpacked extensions from Files.
> - Chromex Runtime: content scripts, popups, storage, runtime messaging, `tabs.query`/`create`.
> - Compatibility analysis before install, with explicit unsupported-API reporting.
> - Declarative ad/tracker blocking via `WKContentRuleList`.
> - Privacy dashboard reports compiled rules and real permission decisions.
>
> Known limitations: no `webRequest` blocking, no cookie mutation, no extension background
> execution while suspended, no CRX signature verification. See `EXTENSION-COMPATIBILITY.md`.

## 9. Distribution path

The public repository distributes an **unsigned IPA** that users sign themselves. That is a
sideloading path, not App Store distribution. An App Store listing additionally requires:
an Apple Developer Program account, signed archive, App Store Connect metadata (including
screenshots), and review — and the 4.7 review risks in `SECURITY.md` apply.
