# CHROMEX — Build Guide (xtool)

xtool is the primary build system. It compiles `Package.swift` into an iOS app and
`xtool dev build --ipa` produces the IPA. No Mac, no Xcode application, no `.xcodeproj`.

---

## 1. What you need

| Requirement | Check |
|---|---|
| Windows 11 + WSL2 (Ubuntu) | `wsl -d Ubuntu` |
| Swift 6.4 toolchain in WSL | `swift --version` |
| xtool 1.24+ in WSL | `xtool --version` |
| **xtool Darwin Swift SDK** | `swift sdk list` prints `darwin` |

Run the gate:

```bash
bash Scripts/xtool-check.sh
```

It prints the host, Swift and xtool versions, the SDK status, and whether `Package.swift`
and `xtool.yml` parse. It exits non-zero if anything is missing.

### The one blocker on this machine

```
$ xtool sdk status
Not installed

$ xtool dev build -c release --ipa
Now generating the Darwin SDK.
Error: Could not read file or directory at path ''.
```

xtool builds its Darwin SDK from `Xcode.xip`, `Xcode.app`, or a prebuilt `darwin.xtoolsdk`
(`xtool sdk install --help`). None of those exist here, and xtool's GitHub releases ship only
the CLI. Fix it once:

1. Download Xcode from <https://developer.apple.com/download/all/?q=Xcode> (any Apple ID
   works; no paid programme needed).
2. `xtool sdk install /mnt/c/Users/<you>/Downloads/Xcode.xip --slim`
3. `swift sdk list` prints `darwin`; `bash Scripts/xtool-check.sh` then exits 0.

Full detail: [Documentation/XTOOL.md](Documentation/XTOOL.md).

---

## 2. Build

```bash
xtool dev build -c release --ipa      # the primary command, unsigned IPA
bash Scripts/xtool-build.sh           # build + verify + SHA-256 into dist/
```

`xtool dev build --help` (xtool 1.24.0):

```
USAGE: xtool dev build [--configuration <configuration>] [--sign] [--ipa] [--triple <triple>]
  -c, --configuration   debug or release
  -s, --sign            Codesign the built app
  -i, --ipa             Output a .ipa file instead of a .app
```

We never pass `--sign`. The archive then contains no signature, no provisioning profile and
no developer identity. `Scripts/xtool-build.sh` runs `Scripts/verify_ipa.sh`, which fails on
`_CodeSignature`, `embedded.mobileprovision`, `CodeResources`, `.p12` or `.cer`, and writes
`dist/CHROMEX-unsigned.ipa.sha256`.

---

## 3. Project layout

```
Package.swift          library product "CHROMEX" (xtool's template shape)
xtool.yml              version: 1, bundleID, product, resources
Sources/CHROMEX/
  App/                 @main entry point
  Browser/             WKWebView tabs, app model, content blocker
  Core/                URL logic, models, manifest, package formats, filter rules
  Extensions/          Chromex Extensions specification types
  ExtensionRuntime/    shim, scheme handler, background pages, bridge
  UI/                  design system and screens
  Resources/           privacy manifest (asset catalogue excluded from SwiftPM)
Tests/CHROMEXTests/    XCTest suite (optional CI lane)
Scripts/               xtool check, build, IPA verification, bundle-id rewrite
Documentation/         xtool-specific notes
```

The target is a **library**, not an executable, because that is xtool's own template; `@main`
lives inside the target.

---

## 4. iPhone testing

1. Connect the iPhone, unlock, tap **Trust**.
2. WSL2 USB passthrough: install `usbipd-win`, then `usbipd bind --busid <id>` and
   `usbipd attach --wsl --busid <id>`.
3. `usbmuxd` must be running (xtool talks to the device through it).
4. `xtool devices` lists connected devices.
5. Installing requires a build signed for your device: `xtool dev build -c release --sign`.
   For independent signing of the unsigned IPA, follow [SIGNING-GUIDE.md](SIGNING-GUIDE.md),
   then install with `xtool install <file.ipa>` or another signing/install tool.

Developer Mode must be enabled on the iPhone for development-signed builds.
Building and exporting the IPA does **not** require the iPhone to be connected.

---

## 5. Optional CI lane

`.github/workflows/ios-build.yml` is not the primary build system. It exists so the sources
are compiled, tested and packaged on every change while the local xtool SDK is unavailable,
and so a verified unsigned IPA remains downloadable. Its output is not proof that the xtool
path works; that proof requires the SDK.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Could not read file or directory at path ''` | Darwin SDK missing | `xtool sdk install /path/to/Xcode.xip --slim` |
| `No such module 'UIKit'` | Built with the Linux toolchain | use `xtool dev build`, not `swift build` |
| `AFCClient.Error.muxError` when installing | usbmuxd / USB passthrough | xtool installation docs, USBIPD section |
| Signing fails on device | certificate/profile mismatch | [SIGNING-GUIDE.md](SIGNING-GUIDE.md) |
| CI lane fails after a move | stale paths | update `project.yml` source paths |
