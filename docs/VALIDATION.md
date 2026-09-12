# Validation status

Updated 12 September 2026. Software checks and simulator captures do not certify
Glass hardware or firmware restoration. No Glass was connected or written to.

## Automated checks

- Python protocol/media simulator: 26 tests pass, including actual encrypted
  socket transfers, opt-in withdrawal, backpressure, malformed payloads, source
  mutation and reconnects.
- Firmware builder: 3 tests pass for archive preservation and invalid inputs.
- Glass JVM `CoreTest`, `TransportTest`, and `MediaTransferTest`: pass.
- Swift: 59 cases, zero failures. One optional local archive case was skipped in
  the complete suite and then passed separately against the current firmware ZIP.
  Coverage includes bounded media schemas/vault recovery, backup inventory and
  executable revalidation, strict ZIP admission, timeouts, cancellation, and a
  valid raw-flash plan making zero runner calls.
- Eight signed Shortcut presets pass workflow, token and binary-hash checks.

The full Swift suite used Xcode beta's native SwiftPM build system:

```sh
cd apple
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --build-system native --scratch-path .build \
  --cache-path .cache --disable-sandbox
```

The native flag works around this host's default SwiftBuild property-list error;
older Swift toolchains may not expose that flag. Logs remain local in `artifacts/`.

Independent review covered the Java sender, Swift receiver/storage/UI, Python
endpoint, and Mac recovery core/UI. Storage-failure, overflow, capability and
backup-revalidation findings were corrected and re-reviewed.

## Builds and device installation

The API 19 APK, iPhone Debug simulator app, signed iPhone Release build 4, and
universal Mac Release build 5 all build successfully. The Mac supports arm64 and
x86_64, with macOS 14 as its minimum; Intel runtime remains untested. The Qt 6
endpoint's previous build/offscreen smoke check remains valid; Qt was unchanged.

Explorer Link v0.1.0 build 4 installed successfully on the paired iPhone with all
eight signed Shortcut presets and media sync. Remote launch was denied because
the phone was locked. Physical iPhone launch, Photos export, radio behavior and
Glass interaction have not been verified by this update.

## Actual simulator media transfer

The running Swift app connected to the Python Glass simulator using real
Keychain pairing and authenticated AES-GCM TCP. It received a synthetic 2,607-byte
PNG and a 116,635-byte MP4. Files read back from the actual app vault matched both
source hashes and byte counts; no partials remained. After restarting the app,
both captures deduplicated and no second copies appeared. Native Quick Look
opened the saved video offline. No Photos-library permission or import occurred.

`artifacts/iphone-media.png`, `iphone-media-preview.png`, and
`iphone-media-preview.mp4` are actual iPhone Simulator captures. Earlier
`iphone-shortcuts.png`, `iphone-phone.png`, and `iphone-input.gif` show synthetic
phone cards and controls. `qt-demo/` contains actual Qt widget renders of
synthetic Glass notifications/directions; these are not Android emulator or
physical Glass captures. Captures are excluded from public source control.

## Derived firmware

Current `ExplorerOS-26PB3-ExplorerLink.zip` SHA-256:

```text
330b53d237941e6273c71b0b44ef610e2d08ae83a53cde03168e506a2d0e847e
```

Its API 19 APK SHA-256:

```text
9070951fc3e7e6b6e977e08e6cc637c71e49ccfee4d513a801f042dd8132e0c6
```

Independent archive comparison verified all 1,373 original system members and
593,869,312 original tar bytes. The only added member is
`system/app/ExplorerLink.apk`; only its containing tar's CWM MD5 line changes.
Outer entry names, boot, recovery, data, cache and recovery-log payloads are
unchanged; ZIP CRC and strict installer ZIP admission pass. The original archive
is retained. This is preservation of input archive bytes, not device data.

## Remaining physical gates

Guided Mac setup checks identity/battery, an existing pinned CWM recovery, mounted
storage and space, copies a backup to the Mac and revalidates it, then stages a
new verified firmware folder. It returns **Prepared**. It never restores, erases,
unlocks, installs a recovery or writes raw partitions. Actual recovery, partition
capacity and restoring the backup still require the intended physical Glass.
A manual CWM restore can replace boot/system/data/cache and personal data.

Physical testing also remains for camera catalog access, media transfers and
Photos export, boot/service startup, API 19 cryptography, Bluetooth bonding,
ANCS/AMS actions, touchpad/camera input and HFP Siri invocation, microphone and
voice output. The voice indicator reports an observed Bluetooth voice route,
not Siri's precise listening state. Global Siri transcripts, Hey Siri detection,
generic dictated notification replies and readable Mail inbox integration are
not provided. See [HARDWARE.md](HARDWARE.md), [MEDIA-SYNC.md](MEDIA-SYNC.md),
[COMMUNITY-SAFETY.md](COMMUNITY-SAFETY.md), and [FEASIBILITY-HFP.md](FEASIBILITY-HFP.md).

Direct iPhone USB-C flashing is not implemented. Apple's USBDriverKit is available
on macOS and M-series iPads, not iPhone; External Accessory sessions require an
accessory protocol and do not expose generic ADB/Fastboot USB interfaces.
[USBDriverKit](https://developer.apple.com/documentation/usbdriverkit) ·
[External Accessory](https://developer.apple.com/documentation/externalaccessory)
