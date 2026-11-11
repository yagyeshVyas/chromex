# Security

CHROMEX runs code it did not write, imported by the user from outside the App Store
distribution model. This document describes the model that makes that defensible, and the
parts that are deliberately out of scope.

---

## 1. Reporting a vulnerability

Open a **private** security advisory via the repository's **Security → Advisories → Report a
vulnerability** tab. Do not open a public issue for anything that could be exploited.

Please include: affected version, steps to reproduce, and whether the issue requires a
malicious extension, a malicious website, or physical device access.

There is no bug bounty. There is a commitment to acknowledge reports and to describe the fix in
the release notes.

---

## 2. Assets

| Asset | Where it lives | Sensitivity |
|---|---|---|
| Browsing history, bookmarks, downloads ledger | JSON in Application Support | High |
| Website cookies and sessions | WebKit data store | High |
| Site permission decisions | JSON in Application Support | Medium |
| Extension packages and their storage | App container | Medium |
| Downloaded files | `Documents/Downloads` (Files-visible) | Variable |
| Extension capability tokens | Memory only | High (in-process) |

CHROMEX has **no server**, no account, and no telemetry endpoint. There is nothing to breach on
the backend because there is no backend.

---

## 3. Threat model

### 3.1 Trust boundaries

```
trusted        SwiftUI · AppModel · ExtensionManager · WebKit (system)
               ▲
semi-trusted   extension JavaScript · extension pages served from a private scheme
               ▲
untrusted      imported packages · websites · page JavaScript
```

The only place a bug becomes a breach is the boundary between semi-trusted and trusted: the
native message bridge. It is therefore the most constrained code in the project.

### 3.2 Threats and controls

| Threat | Control | Residual |
|---|---|---|
| An extension reads another extension's storage | Capability token per injection, bound to one extension id; page JS cannot read the token | None known |
| A website impersonates an extension to the bridge | Same token; message bodies without a valid token are dropped silently | None known |
| Malicious package escapes the container | ZIP path containment, absolute-path and `..` rejection, symlink-free extraction, 16-component depth cap | Unknown parser bug |
| Zip bomb / resource exhaustion | Entry count, per-entry size, total size, compression ratio caps enforced before decompression | CPU spent before a cap trips |
| Remote code in an extension page | CSP on the extension scheme: `script-src 'self' chromex-extension:`, `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'` | Locally bundled obfuscated code |
| Extension reaches a native iOS API | No bridge to UIKit/Foundation capabilities exists; the runtime exposes only browser-shaped calls | A future feature could add one — reviewed as a security change |
| Permission escalation after install | Grants are fixed at install time and shown in the Hub; no runtime permission requests in this build | Re-install with broader grants is visible |
| Private browsing leaks into history | Private tabs use a non-persistent data store and are excluded from history and session restore; extensions do not inject into private tabs | OS-level snapshot cache |
| Data theft at rest | iOS default file protection (`NSFileProtectionCompleteUntilFirstUserAuthentication`) for app-container files | Device passcode is the boundary |
| Malicious download | Downloads are user-initiated and saved to Files; they are never executed or previewed by the app | User can open a bad file themselves |

---

## 4. The capability token

The bridge is a `WKScriptMessageHandler` named `chromexBridge`. Its name is visible to page
JavaScript, so the security does not come from secrecy of the channel — it comes from the token.

At injection time `ExtensionManager` generates a random UUID, maps it to an extension id, and
substitutes it into the JavaScript shim. The shim keeps the token inside a closure:

```js
(function () {
  "use strict";
  var TOKEN = "…uuid…";          // not reachable from page scope
  window.chrome = { … };          // page can call this
})();
```

Page JavaScript can call `chrome.runtime.sendMessage`, but it has no way to read `TOKEN`; a
forged message without a valid token is dropped before any state is touched. Tokens are
per-installation and per-injection, and they die with the process.

Two consequences worth stating:

- The `chrome` object is intentionally visible to page scripts, because content scripts share
  the page's JS context. An extension that leaks data through `chrome` can only leak its own.
- Popup and background pages get their own tokens; they are extension-owned contexts, so the
  token there is about routing, not isolation.

---

## 5. Extension isolation

| Layer | Mechanism |
|---|---|
| Process | WebKit's own web-content process isolation |
| Origin | Each extension gets `chromex-extension://<id>/`; resources are served only from its own directory |
| Storage | One JSON file per extension, inside that extension's directory |
| Messaging | Routed by token and id; no cross-extension delivery path exists |
| Filesystem | Extension packages are read-only after install; extensions cannot write files |
| Native | No `JSExport` of privileged objects; the only crossings are the message bridge |

---

## 6. Package parsing

Parsers are the highest-risk code in any browser. CHROMEX's ZIP and CRX readers are
deliberately small and defensive:

- all reads are bounds-checked (`Data` slicing, no pointer arithmetic in the parser);
- sizes come from the central directory, never from the local header, and are validated
  against the caps before allocation;
- decompression compares the produced byte count with the declared size and fails on mismatch;
- extraction refuses absolute paths, `..`, NUL, backslashes used as separators, more than 16
  path components, and any entry name over 255 bytes;
- the resolved destination path must remain inside the extraction root;
- encrypted entries are refused;
- CRX2 is refused.

What is **not** verified: the CRX signature. There is no trust anchor for an arbitrary
developer key, so a "verified" claim would be misleading. The UI labels such packages
"signature not verified" and the compatibility document repeats it.

---

## 7. Permissions

- Host patterns are granted per extension, at install time, with the consent sheet showing each
  pattern in plain language.
- Content scripts do not inject into a host the user did not allow.
- `<all_urls>` is surfaced as "All websites" with a warning colour.
- Camera and microphone requests are enforced through `WKUIDelegate`; the app's stored decision
  is authoritative, and the default is deny.
- Location and notification decisions are recorded for transparency; WebKit mediates those
  prompts itself, and the app does not claim to override them.
- Private browsing runs with extensions disabled.

---

## 8. Network behaviour

| Traffic | Initiated by | Notes |
|---|---|---|
| Page loads | The user | Through `WKWebView` |
| Downloads | The user | `URLSession`, saved to Files |
| Extension background/popup fetches | The extension | Standard web fetch from its own context |

There is **no request interception API on iOS**, so CHROMEX cannot observe or filter an
extension's network egress. This is disclosed rather than papered over: an extension you grant
access to a site can send what it reads to its author. The mitigation is the consent sheet, the
compatibility verdict, and the fact that extensions are removable in two taps.

The app itself sends nothing: no crash reporting, no analytics, no update pings. Blocking rules
ship in the binary.

---

## 9. Out of scope

- Jailbroken devices and platform-level attacks.
- Malicious signing tools: once you sign an IPA, the signer can modify it.
- Extensions that are deliberately deceptive but technically within their granted permissions.
- Apple's own WebKit vulnerabilities — patching the OS is the mitigation.

---

## 10. Secure development practices in this repository

- No secrets, certificates, profiles, or team identifiers in the tree; `.gitignore` excludes
  them and `verify_ipa.sh` fails the build if any appear in the artifact.
- Signing is disabled in the pipeline by construction (`CODE_SIGNING_ALLOWED=NO`, empty
  identity and team), so a leaked secret cannot be baked in.
- The unsigned IPA is verified for the absence of `_CodeSignature`, `embedded.mobileprovision`,
  `CodeResources`, `.p12`, and `.cer` on every build.
- Security-relevant code paths (package parsing, bridge routing) are unit-tested, including
  traversal, deep paths, CRX version rejection and token-less messages.
- Dependency surface: none. No third-party packages, no SDKs, no Fastlane.
