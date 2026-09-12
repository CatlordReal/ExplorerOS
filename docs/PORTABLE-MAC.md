# Explorer Tools for another Mac

Explorer Tools v0.1.0 (build 5) is an offline personal transfer package.
Copy `Explorer-Tools-Portable.zip` to your other Mac and unzip it. Move
`Explorer Tools.app` to Applications, then open it. macOS 14 or later is required.
The universal application and bundled USB tools support Apple silicon and Intel;
Intel runtime testing has not been performed. Xcode, Homebrew, Python, and an
internet connection are not needed to run this package.

This is an ad-hoc signed developer build, not a notarized release. Another Mac
may require approval through System Settings > Privacy & Security > Open Anyway.
Keep normal macOS security settings enabled.

## Install the Glass companion

1. For an existing Glass installation, enable USB debugging and connect by USB.
2. Open Install apps. The bundled ADB/Fastboot tools and bridge APK are selected.
3. Refresh devices, authorize the Mac on Glass if prompted, and choose its serial.
4. Validate the preview, then install the reviewed APK. Open setup once to pair.
5. Open Explorer Link on iPhone. Pair using a new private key, then connect by
   Wi-Fi or Bluetooth. See the bundled GLASS.md for pairing and hardware checks.

Nothing installs or flashes on application launch. You can choose another APK
to install your own compatible apps. The bridge is built for Android API 19.
An ordinary APK installation also enables the guarded stock-HFP test path when
the exact audited Bluetooth package is present. The bridge implements background
startup after one-time pairing and opt-in; real boot/startup behavior remains
untested. Neither implementation requires reflashing the ROM.

## Included firmware

The personal transfer package can include original Public Beta 3 or the derived
`ExplorerOS-26PB3-ExplorerLink.zip`. The derived backup preinstalls the background
iPhone service, so everyday use does not require opening an APK. One-time pairing
is still required. Its build report records the original archive, APK, output
hashes and unchanged-payload checks. Both formats remain CWM recovery backups.
Guided preparation supports the derived archive’s strict ZIP layout; the untouched
original archive is not accepted by that automated staging path.

Use Firmware to verify the bundled archive and reveal it in Finder. The recorded
SHA-256 detects changed local bytes; the publisher did not provide a signature.
Raw partition writing is disabled. Advanced image review is read-only; neither
this ZIP nor its `*.tar.a` files should be flashed as raw images.

## Prepare firmware with the Mac app

1. In Firmware, select the bundled tools, refresh devices, and select Glass by
   serial while it is running Android. Choose **Check Glass**. Only Explorer
   Edition `Glass 1`, `glass-1`, API 19, XE24 is accepted. Battery readings must
   report healthy, at least 70%, and 0–45°C.
2. Choose **Restart in recovery**, then **Check recovery** when Glass is ready.
   The audited CWM recovery must already be installed. Unknown or missing recovery
   stops preparation; the app does not write or temporarily boot a recovery image.
3. On Glass, choose `backup and restore > backup`. Wait for completion. On the Mac,
   choose **Refresh backups**, select that current backup, then **Copy backup to
   Mac**. Choose a destination with enough space. The app creates a new directory
   and verifies its copied files, including split tar parts. Keep this backup; its
   exact inventory, file identities and hashes are checked again before staging.
4. Choose **Copy firmware to Glass**, then confirm. The app verifies the bundled
   ZIP, uses a new recovery folder, and checks every copied file before publishing
   it. Existing backups stay in place. **Stop current step** cancels the copy;
   partial files remain and must not be selected for restoration.
5. The app reports **Prepared**, with an exact folder. It has not installed
   firmware. The final `backup and restore > restore > <prepared folder>` action
   remains on Glass and must wait until physical compatibility and recovery checks
   are complete. After a successful restore and restart, open setup once to pair.

The identity and battery observation expires after 30 minutes; expiration requires
checking Glass in Android again. Staging requires remaining upload space plus a
256 MiB reserve, which does not establish target partition capacity. Backup copy
verification does not prove that a future restore will work.

A manual CWM restore can rewrite boot, system, data and cache and replace personal
data. The recovery inside the ZIP differs from the repository recovery; the app
does not install either one. Neither has been tested on your Glass. Unchanged
files in the build report refer to the input archive, not device partitions.
Firmware writes can brick Glass. No zero-brick guarantee or validated physical
recovery is supplied. Read [FLASHING.md](FLASHING.md),
[COMMUNITY-SAFETY.md](COMMUNITY-SAFETY.md), [UPSTREAM-INSTALLER.md](UPSTREAM-INSTALLER.md)
and [HARDWARE.md](HARDWARE.md) in the bundle before restoration. Manufacturer
warnings and community reports are distinct evidence, not compatibility approval.

This package is for the owner's local transfer. Public redistribution rights for
all original firmware components have not been established; firmware binaries
are excluded from the source repository. Bundled USB tool notices and project
source are included.

## Rebuild the portable package

Build ExplorerTools in Release with `ARCHS="arm64 x86_64"` and
`ONLY_ACTIVE_ARCH=NO`, then run from the repository root:

```sh
python3 scripts/package-mac.py \
  --app apple/build/PortableDerivedData/Build/Products/Release/ExplorerTools.app \
  --platform-tools /path/to/platform-tools \
  --apk glass-bridge/app/build/outputs/apk/debug/app-debug.apk \
  --firmware artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.zip \
  --firmware-report artifacts/firmware/ExplorerOS-26PB3-ExplorerLink.build.json \
  --output artifacts/portable-mac
```

The output directory must not already exist. Build the derived backup first using
`scripts/build-firmware.py` (see FIRMWARE-INTEGRATION.md). Omit `--firmware-report`
only when packaging the untouched original archive. The script validates the
firmware hash, matching bridge APK and archive, preserves notices, signs the app, and
creates a ZIP with checksums. It never invokes ADB/Fastboot or accesses Glass.
