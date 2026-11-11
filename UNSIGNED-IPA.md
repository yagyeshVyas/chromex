# The Unsigned IPA

This document is about exactly one artifact: `CHROMEX-unsigned.ipa`, produced by the macOS
workflow in this repository. It explains what that file is, what it is **not**, and how to
verify both claims yourself.

---

## 1. What "unsigned" means â€” and what it does not

An unsigned IPA is a ZIP archive containing `Payload/CHROMEX.app`, where the executable has
**no `LC_CODE_SIGNATURE`**, the bundle has **no `_CodeSignature/`**, and there is **no
`embedded.mobileprovision`**.

That makes it certificate-independent: nothing in it is tied to a developer account, a team,
a device list, or an expiry date. It is also **not installable as-is**. iOS refuses to launch
an unsigned app. It becomes installable only after *you* sign it with *your* certificate and
provisioning profile. That is the whole point: the same file works for everyone, and the
signing material never leaves your control.

> The repository does not contain, and the workflow never touches, an Apple certificate, a
> private key, a provisioning profile, a team identifier, or an Apple ID credential.

## 2. Archive structure

```
CHROMEX-unsigned.ipa
â””â”€â”€ Payload/
    â””â”€â”€ CHROMEX.app/
        â”œâ”€â”€ CHROMEX                     Mach-O 64-bit executable, arm64
        â”œâ”€â”€ Info.plist                  CFBundleIdentifier, version, orientations
        â”œâ”€â”€ Assets.car                  compiled asset catalogue (app icon included)
        â”œâ”€â”€ PrivacyInfo.xcprivacy       privacy manifest
        â””â”€â”€ ...                         resources
```

There is **no** `Frameworks/` directory (no dynamic dependencies), **no** `PlugIns/` or
`AppExtensions/` directory, and **no** entitlements file. This is a single-bundle app by
design â€” see Â§5.

## 3. Verifying it yourself

You do not have to trust this document. The same checks CI runs are available to you:

```bash
unzip -l CHROMEX-unsigned.ipa                 # structure
unzip -t CHROMEX-unsigned.ipa                 # integrity
shasum -a 256 CHROMEX-unsigned.ipa            # compare with the release notes
```

Then, after extracting:

```bash
unzip -q CHROMEX-unsigned.ipa -d /tmp/chromex
APP=/tmp/chromex/Payload/CHROMEX.app

plutil -p "$APP/Info.plist" | head -20         # metadata
file "$APP/CHROMEX"                            # Mach-O ... arm64
codesign -dv "$APP/CHROMEX" 2>&1               # "code object is not signed at all"
ls "$APP" | grep -i -E 'codesign|provision'    # no output
```

The automated equivalent is `Scripts/verify_ipa.sh`, which exits non-zero if any of the
following is found: `_CodeSignature/`, `embedded.mobileprovision`, `CodeResources`, a `.p12`,
a `.cer`, a code signature on the executable, a non-arm64 binary, an invalid `Info.plist`,
`__MACOSX` entries, or a broken ZIP.

## 4. Identifier strategy

Default: **`com.chromex.browser`**.

The identifier lives in exactly one place in the project (`project.yml` â†’
`PRODUCT_BUNDLE_IDENTIFIER`) and is copied into `Info.plist` at build time. Three ways to
change it:

| Situation | Method |
|---|---|
| Build your own IPA from this repo | `gh workflow run ios-build.yml -f bundle_id=com.you.chromex` |
| Fork and change it permanently | edit `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` |
| You already downloaded the IPA | `bash Scripts/set_bundle_id.sh CHROMEX-unsigned.ipa com.you.chromex` |

A provisioning profile matches an identifier **exactly** (or via a wildcard). If your profile
is `com.alice.*`, then `com.alice.chromex` will match; `com.chromex.browser` will not.
Mismatch is the single most common signing failure, and the fix is the table above.

Because the app has no nested bundles, changing the identifier requires no other edits â€” no
extension identifiers to keep in sync, no app-group names, no keychain access groups.

## 5. Identifier-dependent features: what we deliberately do not use

The brief asks for these to be accounted for. They are accounted for by **not shipping them**,
which is what makes the artifact portable:

| Feature | Used? | Consequence |
|---|---|---|
| App extensions (share, widget, Safari extension) | No | Nothing nested to sign separately; one profile covers the app |
| App groups | No | No shared-container entitlement to provision |
| Keychain access groups | No | Keychain uses the default access group derived from the app id |
| Push notifications (APNs) | No | No `aps-environment` entitlement; no server certificates |
| Associated domains | No | No domain-to-team binding |
| iCloud / CloudKit | No | No container identifiers |
| Background modes | No | No `UIBackgroundModes` entitlement |
| Sign in with Apple | No | No capability |

If a future version adds any of these, that release will stop being one-profile-signable and
this document will say so explicitly at the top.

## 6. Entitlements

The built app carries **no entitlements**. When you sign it, your provisioning profile's
entitlements become the app's entitlements. The app does not require:

- `get-task-allow` (debugging),
- `com.apple.developer.team-identifier`,
- network extensions, VPN, or any restricted entitlement,
- increased memory limit.

It requests no sensitive privacy permission at launch. Camera and microphone access is only
requested by a website, and only if you have allowed that site in CHROMEX.

## 7. Installability and expiry

The signed result is only as good as your signing material:

| Signing method | Typical validity | Device limits |
|---|---|---|
| Free Apple ID (personal team) | 7 days, re-sign to renew | 3 apps per device, 10 app IDs per 7 days |
| Paid Apple Developer Program | 1 year, renew annually | 100 devices per type per year |
| Enterprise / ad-hoc profile | Profile-dependent | Profile-dependent |

CHROMEX reads the entitlements it is given; it never phones home to check them. Nothing in the
app breaks when a free certificate expires â€” iOS simply refuses to launch it until you re-sign.

## 8. Reproducibility

The IPA is built from a tagged commit by a public workflow. To reproduce it byte-for-byte:

```bash
git checkout v1.0.0
xcodegen generate
xcodebuild -project CHROMEX.xcodeproj -scheme CHROMEX -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
bash Scripts/package_ipa.sh build/Build/Products/Release-iphoneos/CHROMEX.app CHROMEX-unsigned.ipa
```

Byte-identical archives are not guaranteed across Xcode versions (compiler output and ZIP
metadata vary). The **structure and the absence of signing material are guaranteed**, and
those are the properties that matter for independent signing.

