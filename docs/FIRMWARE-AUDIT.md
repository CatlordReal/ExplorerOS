# Firmware audit — 12 September 2026

The software checks pass for the recorded archive. They do not prove that a
physical Glass will boot or recover, and they do not certify a zero-brick risk.
No Glass command, firmware write, unlock, erase, or restore ran in this audit.

## What was tested

- 74 Swift test methods passed. Fourteen new recovery methods exercise 78
  parameter scenarios using injected device responses and strict command
  allowlists. The scenarios cover lost/replaced/unauthorized devices, mount and
  space changes, timeouts and cancellation at each transfer/mutation boundary,
  partial uploads, failed/corrupt publication, local backup changes, executable
  replacement, malformed archives, battery bounds and FIFO/symlink rejection.
- The actual derived ZIP passed the production installer's private
  snapshot, strict ZIP admission, flat extraction and MD5/SHA checks. This runs
  local archive utilities, never ADB or Fastboot. This caught and corrected a
  compatibility bug: CWM includes MD5 entries for three empty split-tar markers.
  A seven-case regression preserves required payload checks while accepting only
  those known empty markers and rejecting malformed alternatives.
- Fourteen Python builder/auditor methods passed. They cover corrupt/truncated
  Android headers, gzip expansion limits, invalid newc fields and paths, GNU long
  names, dangerous tar parent paths, oversized extension headers, checksum
  failures and preservation. These are format tests, not hardware emulation.
- The unchanged protocol/media simulator's previous 26 cases, JVM checks and
  eight signed Shortcut checks remain applicable. The iPhone app and Glass APK
  did not change in this audit. Universal Mac build 6 contains the safety fixes.

The new fault tests initially reproduced two false-success bugs: a verified Mac
backup disappearing during upload, and cancellation arriving with the final
command response. Both now prevent Prepared. File validation now opens with
`O_NONBLOCK` before rejecting a substituted FIFO, so it cannot hang in that open.
Android observation expiration is rechecked during preparation. All corrections
and the independent structural auditor were reviewed by a different agent.

Local cancellation cannot establish the outcome of an already submitted remote
command. In particular, a staging-folder rename may finish after cancellation or
a USB error. The app requests cancellation; the user must recheck Glass and
uncertain folders before any later manual restore. The app cannot enforce that
step inside CWM. It does not delete uncertain folders or retry partition writes.

## Actual archive findings

Firmware SHA-256:

```text
330b53d237941e6273c71b0b44ef610e2d08ae83a53cde03168e506a2d0e847e
```

The audit compared the pinned original and derived ZIPs. All 1,373 original
system members and 593,869,312 original system-tar bytes remain unchanged.
Only `system/app/ExplorerLink.apk` is added, as root/root mode 0644. Boot, recovery,
data, cache and recovery-log payloads are unchanged. Every ZIP CRC and CWM MD5
passes. These are input-archive preservation claims, not device-data promises.

Both 8,388,608-byte Android boot images have valid legacy headers, component
bounds, matching Android SHA-1 IDs, ARM zImage magic, and bounded gzip/newc
ramdisks. Boot contains 39 ramdisk members; recovery contains 255. The recovery
binary and fstab hashes match the installer's pinned observations. No kernel,
init program, recovery binary or other guest file was executed by this audit.
The original boot image contains nonzero bytes beyond its declared components;
the derived archive preserves that tail exactly. It was not trimmed or rewritten.

System file contents total 592,999,708 bytes, or 595,345,408 bytes when each file
is rounded to 4 KiB. Those figures exclude filesystem metadata and do not prove
partition fit. The source data archive contains its original FIFO; the auditor
only reads its tar header and never creates that FIFO on the host.

The actual added APK reports package `com.exploreros.glass`, minimum SDK 19 and
target SDK 28. Android `apksigner` verifies v1/JAR and v2 signatures with API 19 as
the minimum. The development certificate SHA-256 is
`e06b0409ad02e201572e7fe977569dea030e375f53366ae6e637c4c44faa1e39`.
The tool warns that Gradle's `META-INF` metadata entry is not protected by the
v1 signature; the firmware's separate SHA-256 pins the entire APK. This does not
establish production signing or real PackageManager/boot behavior.

## Reproduce without hardware

From the repository root:

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/audit-firmware.py \
  --base-zip artifacts/firmware/ExplorerOS-26-0-PublicBeta3.zip \
  --firmware artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.zip \
  --apk glass-bridge/app/build/outputs/apk/debug/app-debug.apk
cd apple
EXPLORER_RECOVERY_ARCHIVE="$PWD/../artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.zip" \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --build-system native --scratch-path .build \
  --cache-path .cache --disable-sandbox
```

The Python auditor's ZIP pass checks inventory, CRC and CWM checksums; the Swift
case separately checks the installer's stricter ZIP metadata rules. Original
firmware and private results are excluded from public source control. Local
evidence is in `artifacts/deep-audit/`, including `firmware-structure.json`,
`swift-tests.log`, `python-structure-tests.log`,
`apk-signature.txt` and `mac-build6.log`.

## What emulation cannot establish here

macOS blocked the installed legacy Android Emulator during a read-only AVD
inventory check. The block was not bypassed. The available AVD is a Pixel Fold
API 35 device, not Glass. Current QEMU documentation explains that ARM firmware
requires its matching board model; a generic virtual board does not reproduce
Glass's OMAP board, bootloader, flash controller or recovery behavior.
[QEMU ARM system documentation](https://www.qemu.org/docs/master/system/target-arm)

The fault suite simulates the host/recovery command interface. It does not execute
CWM formatting, simulate NAND wear or power failure, or prove a restore can recover
the intended Glass. Exact partition capacities, successful backup restoration,
boot/service startup, battery/power behavior and USB reliability remain physical
gates. Manufacturer downgrade warnings and community reports are recorded in
[COMMUNITY-SAFETY.md](COMMUNITY-SAFETY.md).

iPhone installation was re-investigated independently. Public direct USB
ADB/Fastboot support was not found, but an absolute impossibility claim would be
too broad. PTP camera configuration, previously configured network access and
external USB-host bridges are different possibilities; none is a tested firmware
installer. See [IPHONE-FIRMWARE-OPTIONS.md](IPHONE-FIRMWARE-OPTIONS.md).
