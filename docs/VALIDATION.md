# Validation status

Updated 13 September 2026. Software checks and simulator captures do not certify
Glass hardware or firmware restoration. Glass now enumerates over direct USB,
but ADB remains unauthorized. No APK installation or firmware write has occurred.

## Automated checks

- Python protocol/media simulator: 26 tests pass, including actual encrypted
  socket transfers, opt-in withdrawal, backpressure, malformed payloads, source
  mutation and reconnects.
- Firmware builder and structural auditor: 14 tests pass, covering preservation,
  Android boot headers and SHA-1 IDs, bounded gzip/newc parsing, GNU tar names,
  traversal, link parents, CRC/MD5 damage and missing partitions.
- Glass JVM `CoreTest`, `TransportTest`, and `MediaTransferTest`: pass.
- Swift: 112 cases, zero failures, with the optional current firmware case enabled
  and exercising the production snapshot, flat extraction, and checksum path.
  Coverage includes bounded media schemas/vault recovery, backup inventory and
  executable revalidation, strict ZIP admission, timeouts, cancellation, and a
  valid raw-flash plan making zero runner calls.
- Six device-discovery cases cover independent ADB/Fastboot results and failures,
  cancellation and bounded diagnostics. Six Wi-Fi QR cases cover UTF-8 SSID and
  WPA limits, escaping, unsupported data and open networks.
- Five modular-update build tests pass. An isolated release APK build and signing
  with the retained development key completed; APK v2/0.1.1 verifies with the same
  certificate as base v1, minimum SDK 19 and v1/JAR signing. APK/base signatures,
  package identity and increasing version are required by the update builder.
- The 14 new Swift recovery fault methods cover 78 parameter scenarios, including
  serial loss/replacement, mount/storage drift, every upload slot, timeout,
  cancellation, partial transfers, publication failures and local FIFO rejection.
  Scenarios are not counted as separate XCTest test methods.
- Eight signed Shortcut presets pass workflow, token and binary-hash checks.
- The optional iPhone/Mac installer adds 9 recovery-host tests, 12 real-loopback
  server tests and 5 protocol tests. These cover serial binding, callback-time
  cancellation, stale/replayed requests, wrong keys, malformed/fragmented frames,
  the 8-second authentication and 20-second idle deadlines, backup receipt
  revocation and host reservation through cancellation. The 5 protocol tests also
  passed after final trailing-newline rejection was added.

The full Swift suite used Xcode beta's native SwiftPM build system:

```sh
cd apple
EXPLORER_RECOVERY_ARCHIVE="$PWD/../artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.zip" \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --build-system native --scratch-path .build \
  --cache-path .cache --disable-sandbox
```

The native flag works around this host's default SwiftBuild property-list error;
older Swift toolchains may not expose that flag. Logs remain local in `artifacts/`.

Independent review covered the Java sender, Swift receiver/storage/UI, Python
endpoint, and Mac recovery core/UI. Storage-failure, overflow, capability and
backup-revalidation findings were corrected and re-reviewed.

The deeper audit exposed and corrected loss of the verified Mac backup during
upload still reporting Prepared, cancellation at the final command response
still reporting success, and a possible blocking FIFO open during local-file
validation. Android observation expiration is now checked throughout preparation.
Independent review also covered the new fault tests and structural auditor.
The real archive test also caught and corrected rejection of CWM's three empty
split-tar marker checksums. Seven regression scenarios preserve the mandatory
payload/checksum checks and reject nonempty, duplicate or unknown marker entries.
See [FIRMWARE-AUDIT.md](FIRMWARE-AUDIT.md) for scope, commands and limits.

## Builds and device installation

The API 19 APK, iPhone Debug simulator app, signed iPhone Release build 7, and
universal Mac Release build 8 all build successfully. The Mac supports arm64 and
x86_64, with macOS 14 as its minimum; Intel runtime remains untested. The Qt 6
endpoint's previous build/offscreen smoke check remains valid; Qt was unchanged.

Explorer Link v0.1.0 build 7 installed successfully on Catphone on 13 September;
a separate, bundle-filtered installed-app query verified version 7. This build
includes local Wi-Fi QR setup. Physical iPhone launch, Photos export, radio
behavior and Glass interaction have not been verified by this update.

The final iPhone Wi-Fi screen was captured from the running simulator using
synthetic credentials. Mac UI inspection exposed a button contrast issue that
was corrected and independently reviewed; both final Mac configurations rebuild.
The native UI connector closed during restart, so a capture of that final Mac
button adjustment is still unavailable.

The new firmware screen was captured from the actual iPhone Simulator. The
optional Mac remote controls the existing preparation workflow; it does not
provide iPhone-only flashing. The USB research check is developer-only and sends
no PTP commands. No physical USB/PTP or direct firmware transfer was tested.

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

The separate modular update APK (version 2 / 0.1.1) has SHA-256
`98da1f8ac8f636d0f7359e48b9feca89453469e8b53f17e769785437af3c942c`.
Its signer certificate matches the bundled base. It has not been installed on
Glass, and it does not replace or modify the bundled firmware archive.

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

Direct iPhone USB-C flashing is not implemented, and no public generic iPhone USB
ADB/Fastboot route was found. This is not an absolute impossibility claim: the
boot ramdisk contains PTP camera-mode rules, and preconfigured TCP networking or
an external USB-host bridge are distinct possible research paths. None establishes
a direct USB firmware installer. See [IPHONE-FIRMWARE-OPTIONS.md](IPHONE-FIRMWARE-OPTIONS.md).
