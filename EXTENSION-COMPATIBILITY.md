# Extension Compatibility

CHROMEX runs Chrome-style extensions through **Chromex Runtime**, a browser-written WebKit
runtime. This document is the authoritative list of what that runtime actually does. It is
generated from the same catalog the app shows on an extension's detail screen
(`ExtensionAPICatalog` in `App/Sources/Core/ExtensionManifest.swift`).

**CHROMEX is not desktop Chrome.** iOS forces every browser onto WebKit, which has no V8
extension host, no `webRequest` interception, and no durable background execution. Any claim
stronger than this table would be false, so the table is the claim.

---

## 1. Verdicts

Every package is analysed **before** it is installed. The result is one of:

| Verdict | Meaning |
|---|---|
| `runs` | Everything the manifest declares is implemented |
| `runs-with-limits` | It will run; listed capabilities are missing |
| `unsupported` | What CHROMEX can run does not add up to a working extension (for example: no content scripts, no popup, no background) |
| `refused` | It requires `debugger`, `nativeMessaging`, or `webRequestBlocking` — refused by policy and engine |

The verdict is computed from the manifest and a fixed catalog. It is deterministic and offline.
Findings are shown in the app; the limitations below are the same data.

---

## 2. Package support

| Format | Supported | Detail |
|---|---|---|
| `.zip` | Yes | Central-directory parser; deflate and stored entries |
| Unpacked folder | Yes | Picked with the document picker; copied into the app container |
| `.crx` (CRX3) | Yes, structurally | `Cr24` magic, version 3, header length validated; ZIP payload extracted |
| `.crx` (CRX2) | No | Rejected with an explicit error |
| CRX **signature verification** | **No** | CHROMEX has no trust anchor for a developer key, so a "verified" badge would prove only internal consistency. The UI says "signature not verified" |
| Update flow | No | Re-import a newer package; there is no silent update channel |

### Resource limits (enforced before extraction)

| Check | Limit |
|---|---|
| Entry count | 5,000 |
| Total uncompressed | 100 MB |
| Any single entry | 50 MB |
| Compression ratio | 100:1 per entry, 20:1 archive-wide |
| Path depth | 16 components |
| Path containment | No absolute paths, no `..`, no symlink escape, no NUL, no backslash tricks |
| Encrypted entries | Refused |

Every rejection carries a named reason (`PackageError`), shown to the user.

---

## 3. API support

### 3.1 Supported

| Area | Behaviour |
|---|---|
| `content_scripts` | JS and CSS injected into matching pages; `run_at` (`document_start`, `document_end`, `document_idle`), `all_frames`, `exclude_matches`, host-pattern matching. Injection requires a granted host pattern |
| `storage.local` | Per-extension JSON key/value store persisted in the app container; `get` / `set` / `remove` / `clear` / `getBytesInUse`, callbacks and promises |
| `storage.sync`, `storage.session` | **Aliased to local.** There is no Chrome sync service on iOS; values never leave the device |
| `storage.onChanged` | Fired in the background page after a write |
| `runtime.sendMessage` | Content script / popup → background page, with response routing |
| `runtime.onMessage` | Fired in the background page; `sendResponse` supported, including asynchronous responses |
| `runtime.getURL` | Returns `chromex-extension://<id>/<path>` for packaged resources |
| `runtime.id` | The installation identifier |
| `tabs.query` | Reports the active tab. `url` is only included when the extension holds host access |
| `tabs.create` | Opens a real CHROMEX tab |
| `action.default_popup` | Opens in a native sheet with its own web view |
| `action.setBadgeText` | Accepted as a no-op; there is no badge surface in this build |

### 3.2 Unsupported (declared in the catalog, shown before install)

| API | Why |
|---|---|
| `webRequest` (any event) | WebKit exposes no request-observation hook to the browser |
| `webRequestBlocking` | Refused: no interception is possible |
| `declarativeNetRequest` | Per-extension rule sets are not bridged. CHROMEX's own declarative blocker is separate and always available |
| `scripting.executeScript` | Use declared `content_scripts`; dynamic script injection is not bridged in this build |
| `i18n` | `_locales` is not resolved in this build |
| `alarms` | iOS cannot keep a background scheduler alive |
| `notifications` | Not bridged in this build |
| `contextMenus` | Not bridged in this build |
| `commands` | Not bridged in this build |
| `cookies` | Not exposed to extensions |
| `history`, `bookmarks`, `downloads` | Not exposed to extensions |
| `identity` | No OAuth bridge |
| `management` | Not exposed |
| `offscreen` | No offscreen document concept in WebKit |
| `tabGroups`, `sidePanel`, `userScripts`, `omnibox`, `devtools`, `proxy`, `privacy` | Not bridged |
| `nativeMessaging` | Refused: iOS forbids spawning helper processes |
| `debugger` | Refused: no page-process debugging surface |

Unsupported calls **reject or return `undefined`**; they never throw an exception into a popup
and never take a page down. An extension that probes an unsupported API still renders.

### 3.3 Manifest keys

| Key | Behaviour |
|---|---|
| `manifest_version` 2 / 3 | Both parsed; V2 host patterns are split out of `permissions` |
| `name`, `version`, `description` | Required / displayed |
| `icons` | Used for the Hub entry |
| `action` / `browser_action` | Popup, title, popup path |
| `background.service_worker` | Hosted as a non-persistent hidden page running that script |
| `background.scripts` | Same, multiple scripts injected in order |
| `background.page` | Loaded directly |
| `content_scripts` | Supported as above |
| `permissions`, `host_permissions` | Drive the consent sheet |
| `optional_permissions` | Parsed but not requestable at runtime in this build |
| `web_accessible_resources` | Resolved through the extension scheme |
| `options_page` / `options_ui` | Parsed; **not hosted** in this build (no options UI) |
| `content_security_policy` | Parsed; extension pages always get CHROMEX's own restrictive CSP |
| `update_url` | Ignored |
| `devtools_page`, `side_panel` | Unsupported |
| `externally_connectable` | Unsupported |

---

## 4. Execution model

- **Background:** a hidden `WKWebView` runs the service worker / background scripts as a
  non-persistent page. It stops when the app is suspended. `runtime.onStartup` does not exist.
- **Content scripts:** injected as `WKUserScript`s before the navigation they match, in an
  isolated world by default (page JavaScript cannot see them unless the extension injects into
  the page itself).
- **Popups:** a separate `WKWebView` served from `chromex-extension://`.
- **Messaging:** content/popup → native → background → native → content, keyed by request id,
  with a typed envelope and a per-injection capability token.
- **Extension pages:** served by a `WKURLSchemeHandler` with `no-store`, `nosniff`, and a CSP
  that refuses remote script.

### Why a custom runtime instead of `WKWebExtension`

Apple ships a public WebExtensions runtime from iOS 18.4 (`WKWebExtension`). It is the better
long-term path, and `WKWebExtension` is what a v2 should adopt. It was **not** used here because
this build must compile and ship from GitHub Actions with no local Xcode and no fixed Xcode
version: depending on that SDK surface couples the artifact to a specific runner image. The
custom runtime uses only WebKit APIs available since iOS 14, which keeps the unsigned IPA
buildable and signable anywhere.

That trade-off is stated plainly because it changes what extensions can expect: this runtime
implements the table above, not the whole WebExtensions specification.

---

## 5. What a user should expect

| Extension kind | Practical result |
|---|---|
| Dark-mode / CSS restyler | Works |
| Element hider | Works |
| Content tweaker / userscript-style | Works |
| Tab-adjacent helper (active tab) | Partial — `tabs.query` sees the active tab only |
| Extension with a popup UI | Works, if it does not need unsupported APIs |
| Extension with background logic | Works while the app is running |
| Ad blocker with its own DNR rules | **Not supported** — use CHROMEX's built-in blocker |
| Network interceptor / proxy | Refused |
| Cookie editor, download manager | Unsupported |
| Password manager relying on native APIs | Unsupported (system AutoFill is separate) |

---

## 6. Testing an extension

1. Put a `.zip`, `.crx`, or folder where the Files app can reach it.
2. In CHROMEX: **Chromex Hub → +** → choose the package.
3. Check the verdict before installing. If it says `runs-with-limits`, the missing pieces are
   listed under "Not available on iOS".
4. After installing, open a matching page. Content scripts appear in
   **Hub → Diagnostics → Runtime**, and errors from background pages are listed there.
5. Disable the extension to stop injection on newly created tabs.

If an extension fails silently, the audit trail is: verdict → grants → Diagnostics. All three
are visible in the app; none of them are invented after the fact.

---

## 7. Reporting a compatibility bug

Open an issue with:

- extension name and version,
- the verdict CHROMEX gave it,
- what you expected and what happened,
- the Diagnostics lines, if any.

Claims in this document are testable claims. If the runtime does something this table says it
does not do — or fails to do something it says it does — that is a bug, not a nuance.
