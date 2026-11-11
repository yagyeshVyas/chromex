# Signing Guide

The release is certificate-independent. This guide turns `CHROMEX-unsigned.ipa` into an app
your iPhone will actually launch, using **your** certificate and **your** provisioning
profile.

Nothing here requires a Mac, although a Mac makes one of the methods easier.

---

## 1. What you need

| Item | Notes |
|---|---|
| The unsigned IPA | From GitHub Releases or the Actions artifact |
| An Apple ID | A free Apple ID works (7-day certificates) |
| A provisioning profile | Created automatically by most tools, or by you in the Developer portal |
| A signing certificate | `.p12` + password, or managed for you by the tool |
| A USB cable or Wi-Fi pairing | For installing onto the device |
| Device UDID in the profile | Required for ad-hoc/development profiles; **not** for free-account tools that register it for you |

An Apple ID alone is enough for personal use. A paid Apple Developer Program membership is
needed for yearly certificates, more devices, and TestFlight.

---

## 2. Inspect the IPA first

Do this once. It tells you the identifier you are about to sign.

```bash
unzip -l CHROMEX-unsigned.ipa | head -20
unzip -q CHROMEX-unsigned.ipa -d chromex-inspect
plutil -p chromex-inspect/Payload/CHROMEX.app/Info.plist | grep -E 'CFBundleIdentifier|CFBundleShortVersionString|MinimumOSVersion'
```

Expected: `CFBundleIdentifier = com.chromex.browser`, version `1.0.0`, minimum iOS `17.0`.

Confirm it is unsigned (should print *"code object is not signed at all"*):

```bash
codesign -dv chromex-inspect/Payload/CHROMEX.app/CHROMEX
```

---

## 3. Decide the bundle identifier

Your profile decides this, not you. Rules:

- Profile `com.alice.chromex` â†’ app id must be **exactly** `com.alice.chromex`.
- Profile `com.alice.*` (wildcard) â†’ any id starting `com.alice.` works.
- Profile `*` (rare, usually macOS) â†’ anything works.

If the default does not match, rewrite it **before** signing:

```bash
bash Scripts/set_bundle_id.sh CHROMEX-unsigned.ipa com.alice.chromex
# â†’ CHROMEX-com-alice-chromex.ipa, still unsigned
```

The app has no nested bundles, so this is the only identifier you need to change. If you are
building from source instead, `gh workflow run ios-build.yml -f bundle_id=com.alice.chromex`
does the same thing at build time.

---

## 4. Choose a signing method

| Tool | Platform | Apple ID / certificate | Good for |
|---|---|---|---|
| **Sideloadly** | Windows, macOS | Either | Most Windows users; registers the device automatically with a free ID |
| **AltStore / SideStore** | Windows/macOS + iPhone app | Apple ID | Re-signing automatically before the 7-day expiry |
| **zsign** | Windows, macOS, Linux | `.p12` + `.mobileprovision` | Scripted or offline signing; no Apple ID handling |
| **ESign / Signulous** | iPhone (on-device) | Certificate or Apple ID | Signing without a computer (paid services) |
| **Xcode** | macOS only | Apple ID | Development and debugging |

All of them perform the same three steps: unpack, sign the app with a certificate that the
profile trusts, embed the profile, repack.

---

## 5. Method A â€” Sideloadly (Windows)

1. Install Sideloadly from <https://sideloadly.io>.
2. Connect the iPhone, tap **Trust** on the device.
3. Drag `CHROMEX-unsigned.ipa` into Sideloadly.
4. Enter your Apple ID in the **Apple account** field. Sideloadly creates a development
   certificate and a profile for the app automatically.
5. If Sideloadly reports an identifier mismatch, set the **Bundle ID** field to a value your
   team owns, or pre-rewrite the IPA with `Scripts/set_bundle_id.sh`.
6. Press **Start**. Enter the Apple ID password (and 2FA code) when prompted.
7. On the iPhone: **Settings â†’ General â†’ VPN & Device Management â†’ Developer App** â†’ trust
   your Apple ID.

The app installs and launches. With a free Apple ID it stops launching after 7 days; repeating
steps 3â€“6 re-signs it.

## 6. Method B â€” AltStore / SideStore

1. Install AltServer on your computer and AltStore on the iPhone (or use SideStore).
2. In AltStore, **My Apps â†’ +** and choose the IPA.
3. Sign in with your Apple ID when asked.
4. Keep AltServer reachable on the same network for automatic refresh, or refresh manually
   every 7 days.

This is the most comfortable path if you intend to keep the app long-term on a free account.

## 7. Method C â€” zsign (scripted, offline)

You need a `.p12` certificate and its password, plus a `.mobileprovision` whose App ID matches
the bundle identifier.

```bash
# 1. Match the identifier
bash Scripts/set_bundle_id.sh CHROMEX-unsigned.ipa com.alice.chromex

# 2. Sign
zsign \
  -k alice.p12 -p 'p12-password' \
  -m alice.mobileprovision \
  -o CHROMEX-signed.ipa \
  CHROMEX-com-alice-chromex.ipa
```

`zsign` signs the bundle, embeds the profile, and repacks it. Verify:

```bash
unzip -q CHROMEX-signed.ipa -d signed
codesign -dv --verbose=2 signed/Payload/CHROMEX.app
ls signed/Payload/CHROMEX.app/embedded.mobileprovision
```

## 8. Method D â€” manual signing with Xcode command-line tools (macOS)

Only if you already have a valid certificate and profile and prefer to control every step.

```bash
unzip -q CHROMEX-unsigned.ipa -d work
APP=work/Payload/CHROMEX.app

# The profile must contain the bundle id and your device UDID.
cp alice.mobileprovision "$APP/embedded.mobileprovision"

# Sign with the identity from your keychain. No entitlements file is needed: the
# profile's entitlements apply. --generate-entitlement-der is required on modern iOS.
codesign -f -s "Apple Development: alice@example.com (TEAMID)" \
         --generate-entitlement-der \
         "$APP"

# Repack
cd work && zip -qry ../CHROMEX-signed.ipa Payload
```

Do not sign only the executable and forget the bundle: `codesign` on the `.app` is what
produces `_CodeSignature/CodeResources`.

---

## 9. Nested bundles and frameworks

**This release has none.** `Payload/CHROMEX.app` contains no `Frameworks/`, no `PlugIns/`, and
no `AppExtensions/`. That is why one profile and one certificate are sufficient, and why
`Scripts/set_bundle_id.sh` only has to change one string.

If a future release adds nested code, the rule is **inside-out signing**:

```bash
# 1. frameworks first
find "$APP/Frameworks" -name '*.framework' -maxdepth 1 | while read -r fw; do
  codesign -f -s "$IDENTITY" "$fw"
done
# 2. app extensions next, each with its own matching profile
for ext in "$APP/PlugIns"/*.appex; do
  cp "$EXT_PROFILE" "$ext/embedded.mobileprovision"
  codesign -f -s "$IDENTITY" --generate-entitlement-der "$ext"
done
# 3. the app itself last
codesign -f -s "$IDENTITY" --generate-entitlement-der "$APP"
```

Signing the app before its nested code invalidates the outer signature. When this release adds
nested bundles, `UNSIGNED-IPA.md` will list them and this section will name each profile.

---

## 10. Entitlements

The unsigned app has none. After signing, the app's entitlements are the subset your profile
grants â€” typically `application-identifier`, `com.apple.developer.team-identifier`,
`get-task-allow` (development only), and `keychain-access-groups`.

CHROMEX needs nothing beyond a normal app: no push, no app groups, no associated domains, no
background modes. If a signing tool offers to add capabilities, decline â€” adding entitlements
your profile does not authorise produces an install that fails at launch.

To inspect what you actually signed:

```bash
codesign -d --entitlements :- signed/Payload/CHROMEX.app
```

---

## 11. Installing the signed IPA

| Route | Steps |
|---|---|
| Sideloadly | Install happens as part of signing |
| AltStore | Install happens as part of signing |
| Apple Configurator 2 (Mac) | Add â†’ Apps â†’ choose IPA; device must be supervised or profile-authorized |
| 3uTools (Windows) | Apps â†’ Import/Install local IPA |
| Xcode (Mac) | Window â†’ Devices and Simulators â†’ **+** under Installed Apps |

After installing with a free/personal certificate, trust it once:

**Settings â†’ General â†’ VPN & Device Management â†’ Developer App â†’ [your Apple ID] â†’ Trust.**

---

## 12. Diagnosing signing failures

| Error | Meaning | Fix |
|---|---|---|
| `Provisioning profile "..." doesn't match the bundle identifier` | Profile App ID â‰  `CFBundleIdentifier` | Rewrite the id to match, or use a wildcard profile |
| `Provisioning profile doesn't include signing certificate` | Certificate not in the profile | Regenerate the profile with that certificate |
| `This device is not included in the provisioning profile` | UDID missing | Add the device (paid account) or let Sideloadly register it |
| `ApplicationVerificationFailed` | Signature/profile mismatch, or profile expired | Re-sign with a fresh profile; check expiry |
| `Unable to Install "CHROMEX"` with no detail | Trust prompt declined, or iOS version below 17.0 | Trust the developer; check iOS â‰¥ 17 |
| `Untrusted Developer` after launch attempt | Certificate not trusted | Settings â†’ VPN & Device Management â†’ Trust |
| App launches then closes immediately | Entitlements not authorised by the profile | Remove added entitlements; re-sign with profile defaults |
| `The executable was signed with invalid entitlements` | Manual signing without `--generate-entitlement-der` | Re-sign with the flag |
| `A valid provisioning profile for this executable was not found` | `embedded.mobileprovision` missing from the `.app` | Copy the profile into the bundle **before** `codesign` |
| Free-account app stopped working after a week | 7-day certificate expired | Re-sign; consider AltStore auto-refresh |
| `The maximum number of apps for free development profiles has been reached` | 3-app free limit | Delete an unused sideloaded app |
| `Failed to register bundle identifier` | 10 app IDs per 7 days exhausted on a free account | Wait, or reuse an existing id |

If the IPA itself looks wrong, re-run `Scripts/verify_ipa.sh` â€” it catches structural problems
before a signing tool reports them as cryptic errors.

---

## 13. Security and legal notes

- **Never share your `.p12`, its password, or your Apple ID credentials.** A signing
  certificate identifies you; anyone holding it can sign software as you.
- Prefer a dedicated Apple ID for sideloading. Revoke certificates you no longer use in the
  Developer portal.
- Download the IPA from this repository's Releases. Verify the SHA-256 published in the
  release notes; a modified IPA can contain anything.
- Signing an app for your own device is one thing; redistributing a signed build is another.
  Apple's Developer Program License Agreement governs what you may distribute, and it is your
  responsibility to comply.
- CHROMEX itself collects no analytics and contains no third-party SDKs. Anything the app
  sends over the network is either a page you asked for or an extension you installed.

