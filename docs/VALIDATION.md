# Validation status

Updated on 12 September 2026; iPhone and Qt captures below are from 11 September. Host tests and simulator captures do not establish
that Glass hardware, Bluetooth, or firmware restoration works.

## Automated checks

Run `scripts/test.sh`. The recorded local `artifacts/safety-tests.log` contains:

- Python simulator and protocol: 17 tests passed.
- Firmware builder: 3 tests passed, including preservation of an entire synthetic
  CWM backup, rejection of an incorrect base, and refusal to overwrite output.
- Glass pure-JVM `CoreTest` and real-socket `TransportTest`: passed. Socket tests
  cover authentication failure, phone-action capability gating, heartbeat replies,
  second-client rejection, and reconnects.
- Swift ExplorerLinkCore: 22 tests passed, including bounded Shortcut preview URLs,
  Calendar/Reminders formatting, and protected-note payload validation.
- Swift ExplorerFlashCore: 14 tests passed, including bounded process output,
  timeout handling, image validation, bundle relocation, changed-file rejection,
  and a valid raw-flash plan producing zero runner calls.
- Shortcut tests pass for generated workflows and UTF-16 token/output links,
  including a non-BMP character regression. All eight signed artifacts were
  decoded and reviewed; `fixtures/shortcut-artifacts.json` records binary and
  decoded-workflow hashes. Tests pin the reviewed signed files.

Build 3 succeeded for iPhone Simulator and signed Release iPhone device. Both
bundles contain all eight signed Shortcut files. The native Mac
Release build 4 contains both arm64 and x86_64 slices. Raw partition execution
is disabled; ordinary APK installation is retained. The API 19 bridge APK and
Qt 6 desktop endpoint build successfully. Qt also passed its offscreen smoke test.

An independent reviewer checked the protocol/security changes, phone-action
queue, protected note storage, Android lifecycle/transport, Mac preflight checks,
firmware preservation, and the final stock-HFP adapter. This is code and host
evidence, not hardware certification.

## Running iPhone simulator

The actual Swift app connected to the Python endpoint over authenticated,
AES-GCM-protected TCP. The iPhone advertised `phone.actions`; the endpoint
requested local note browsing and received the synthetic note. A `focus.on`
request appeared in the Phone tab for review; no Shortcut executed automatically.
These checks used a fixture key and synthetic text only.

Actual captures are retained locally in `artifacts/`: `iphone-connected.png`,
`iphone-phone.png`, `iphone-shortcuts.png`, `mac-apps.png`, and `qt-app.png`.
`qt-demo/` contains actual
Qt widget renders of synthetic notifications, notes, directions and disconnects;
these are not Android emulator or physical Glass captures. Build logs and captures
are excluded from the public source repository.

## iPhone device

The initial signed `org.exploreros.ExplorerLink` build installed successfully on
a physical iPhone. Its subsequent remote launch failed at CoreDevice XPC, so
launch, Bluetooth, and Glass interaction were not established.

The later update attempt failed because the iPhone was no longer reachable
(`CoreDeviceError 4016`). Only the initial build is confirmed installed; later
Phone integrations and bundled Shortcut presets are not claimed to be on it.

## Derived firmware

`scripts/build-firmware.py` produced `ExplorerOS-26PB3-ExplorerLink.zip` with SHA-256:

```text
833e0ebc783d5a50e199476b4f56f030f21bf5b4a5069e3ccdc1b20a18022170
```

Independent verification confirmed unchanged outer entry names and identical
boot, recovery, data, cache, and recovery-log payloads. The existing 1,373 system
members and their original tar bytes are preserved. The only added member is
`system/app/ExplorerLink.apk`; only its containing tar's CWM MD5 entry changes.
ZIP CRC verification passes. The APK SHA-256 is:

```text
bded3d86d0f48e292b410a4bd65eb3535b24dcce8ac22066f5c2c2217177612d
```

## Physical Glass gates

No Glass flash, unlock, erase, reboot, APK installation, or runtime test was
performed. Real Explorer Edition XE24 and iPhone checks remain mandatory for
boot/service startup, PackageManager acceptance, free system space, API 19 AES-GCM,
touchpad/camera events, Wi-Fi/BLE reconnection, ANCS/AMS actions, system-notification
authorization, battery/radio behavior, and every recovery operation.

The bundled firmware is a CWM backup requiring manual recovery restoration.
All Mac raw-partition execution is disabled. Read-only planning does not validate
image format, partition capacity, boot compatibility, or recovery. Manual CWM
restoration can still write boot, system, data and cache, including replacement
of personal data. Archive preservation does not certify a safe device restore. The stock HFP adapter is implemented
and host-tested, but actual Siri invocation, playback and microphone use remain
unverified. Its indicator distinguishes a request from an observed Bluetooth
voice route; neither establishes Siri's precise listening phase. The original
launcher's Camera binding remains unchanged. Generic dictated notification
replies, global Siri transcripts, "Hey Siri" wake-word detection, and photo/video
sync are not implemented. The guarded HFP adapter can now be tested through an
ordinary APK install on the audited API 19 system, without a ROM reflash. See [HARDWARE.md](HARDWARE.md),
[FIRMWARE-INTEGRATION.md](FIRMWARE-INTEGRATION.md), and
[FEASIBILITY-HFP.md](FEASIBILITY-HFP.md).

## Installation safety follow-up

The 12 September audit found that manifest checks did not establish a raw-image
format or safe write lifecycle. Raw execution now fails unconditionally before
any process invocation. The Mac firmware page only verifies the bundle or shows
read-only plans. The full host suite and universal Mac build passed; independent
review covered the execution block, APK-first HFP gate change, report scope and
updated safety copy. New report fields explicitly mark device compatibility,
partition capacity and recovery as unvalidated. No physical Glass was connected
and no hardware writes occurred.
