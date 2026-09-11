# ExplorerOS background iPhone service

The integrated firmware preinstalls Explorer Link in `system/app/ExplorerLink.apk`.
Pair once in its setup screen. A paired, enabled installation starts after boot
and app updates, reconnects to its saved iPhone, and presents incoming cards
without manually opening the app. The setup screen can disable background
integration or revoke pairing.

Cards use a private Android activity because the shipped Unity ExplorerLauncher
has no published card IPC. Dismissing an automatic card returns to the launcher.
Old ANCS notifications do not pop up during initial synchronization. A timeout,
cooldown and foreground-setup checks limit interruptions. Physical behavior still
requires a Glass test. Camera/touchpad handling applies while a card is visible;
this module does not replace global camera handling in other applications.

The foreground service, protocol, ANCS/AMS clients, and card UI remain an isolated
module suitable for upstream inclusion. Android can update the same signed
package separately, so future bridge fixes need not require another ROM restore.
Keep the signing key consistent between preinstall and later APK updates.

## Build the integrated recovery backup

```sh
glass-bridge/scripts/build-apk.sh
python3 scripts/build-firmware.py \
  --base-zip artifacts/firmware/ExplorerOS-26-0-PublicBeta3.zip \
  --apk glass-bridge/app/build/outputs/apk/debug/app-debug.apk \
  --output artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.zip
```

The builder accepts only the inspected original Public Beta 3 SHA-256. It adds
one root-owned, mode-0644 APK to the system tar, verifies every original tar
header/body byte before the end marker is unchanged, and verifies every other
ZIP payload by SHA-256. It updates only the system-tar checksum in `nandroid.md5`,
preserving the other checksum-file bytes. MD5 is required by CWM; the separate
build report uses SHA-256. Existing outputs are never overwritten.

The kernel, boot image, recovery image, bootloader, launcher and original data
backup are not modified. This is a derived CWM/Nandroid backup, not a rebuilt
Android platform or a fastboot `system.img`. No pairing key is embedded. The
original archive remains available beside the derived copy.

The accompanying `.build.json` records the input/output/APK hashes and preservation
checks. `hardwareValidated` remains false. Tests do not prove partition space,
CWM restore behavior, PackageManager scanning, boot delivery, Bluetooth bonding,
radio reliability, display wake behavior, or recovery safety on real Glass.

See PORTABLE-MAC.md for transferring the app and firmware to another Mac, and
HARDWARE.md before a physical installation. The builder never invokes ADB,
Fastboot, or recovery, and never flashes or modifies a connected device.
