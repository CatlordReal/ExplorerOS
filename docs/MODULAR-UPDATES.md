# Updates without reflashing

Explorer Link is the updatable part of this fork. The initial firmware can
preinstall `system/app/ExplorerLink.apk`; Android accepts compatible updates in
`/data/app` while retaining that built-in copy. The service can also be installed
normally on compatible XE24, without installing the derived firmware first.

| Change | Delivery | Firmware restore? |
| --- | --- | --- |
| Cards, directions, notification content and media | Authenticated companion connection | No |
| Pairing and preferences | Private app storage | No |
| Bridge logic, card UI and ordinary app features | Same-package, same-signer APK update | No |
| iPhone or Mac features | Update that native app | No |
| Kernel, drivers, recovery or stock services | Separately reviewed firmware change | May be needed |

The service implements startup after boot and package replacement when paired
and background integration is enabled. Routine use does not require reopening
Setup. Physical boot, upgrade and reconnect behavior remains unverified on Glass.

## Install an update

In **Explorer Tools > Install apps**, choose the new APK, refresh and select the
authorized Glass serial, then review and install. The installer uses
`adb -s <serial> install -r <apk>`. Android checks the signature and retains app
data for compatible replacements. No downgrade, uninstall, erase, unlock or
firmware restore is requested. Do not uninstall to work around an update error.

Application updates still need adequate battery, storage, a stable connection
and compatible code. Avoiding firmware writes reduces that exposure; it cannot
guarantee an update will not fail or crash.

## Signing and data compatibility

Retain the exact private key used for the preinstalled or installed APK. The
bundled version 1 uses a development certificate. Another Mac's debug key can
differ; copying source does not preserve signing identity. Transfer the verified
APK, or supply the retained key separately to the update build. Never include
private keys or passwords in source, firmware or the portable package.

Each published update needs a higher `versionCode` than the latest release.
Keep old preference names and types readable. Pairing, peer selection, background
opt-out and camera-sync settings must survive replacement; this update does not
change their storage. New permissions cannot be assumed to grant privileges
absent from the original system APK.

### Build a compatible update

Set `EXPLORER_KEYSTORE_PASSWORD` and `EXPLORER_KEY_PASSWORD` privately in the build
environment. Supply the existing keystore outside this repository, its alias,
the original shipped APK and the latest released APK. For the first update, the
base and previous APK are the same file. Keep these release artifacts separate
from mutable debug-build output.

```sh
python3 glass-bridge/scripts/build-update.py \
  --base-apk /saved/ExplorerLink-v1.apk \
  --previous-apk /saved/ExplorerLink-latest.apk \
  --keystore /private/signing/explorerlink.keystore \
  --alias your-existing-alias \
  --expected-signer-sha256 e06b0409ad02e201572e7fe977569dea030e375f53366ae6e637c4c44faa1e39 \
  --output /existing/output/ExplorerLink-update.apk
```

That public certificate fingerprint belongs to the current bundled development
APK; it is not a private key. The script uses the existing Android SDK/Gradle
installation (`--sdk` and `--gradle` can override their paths). It builds in a
temporary directory, verifies package, minimum SDK 19, v1 signature, signer and
increasing version, then publishes a new output without replacing an existing
file. It does not install anything or alter the shipped APK. Increment
`glass-bridge/version.properties` before each later release. The caller must
provide the actual latest APK; this offline command cannot query the installed
device version or prove that its private data remains compatible.

## Recovery from an app failure

If Setup opens, **Background integration > Off** stops the bridge. Keep known-good
source and the signing key. A corrective update should rebuild known-good code
with a higher version number and data-compatible readers.

Do not treat **Uninstall updates** as data-preserving rollback: KitKat can erase
private data when restoring the older built-in APK. The app has
`allowBackup=false`; ordinary ADB backup is not a pairing-data backup guarantee.
A full firmware restore needs its own partition and personal-data review.

## Remaining physical checks

Host tests cover the install command and build-time signature/version gates.
They cannot establish installed device state. Real Glass testing must verify
version 1 to update installation, retained pairing and opt-out, background
restart, stock HFP/ANCS/AMS behavior, and a corrective update. No physical APK or
firmware installation has yet completed.

References: [Android APK installation](https://developer.android.com/tools/adb),
[Android signing](https://developer.android.com/studio/publish/app-signing), and
[KitKat package replacement and system-app rollback](https://android.googlesource.com/platform/frameworks/base/+/android-4.4.2_r1/services/java/com/android/server/pm/PackageManagerService.java).
