# Explorer Tools for another Mac

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

## Included firmware

The personal transfer package can include original Public Beta 3 or the derived
`ExplorerOS-26PB3-ExplorerLink.zip`. The derived backup preinstalls the background
iPhone service, so everyday use does not require opening an APK. One-time pairing
is still required. Its build report records the original archive, APK, output
hashes and unchanged-payload checks. Both formats remain CWM recovery backups.

Use Firmware to verify the bundled archive and reveal it in Finder. The recorded
SHA-256 detects changed local bytes; the publisher did not provide a signature.
Do not feed this ZIP or its `*.tar.a` files to the raw-image flasher.

A full ExplorerOS installation still requires an appropriate working CWM
recovery and manual backup/restore steps on Glass. The recovery inside the ZIP
differs from the repository recovery. Neither has been tested on your Glass.
This app does not choose between them, unlock the bootloader, erase existing
backups, or automate recovery writes. See UPSTREAM-INSTALLER.md and HARDWARE.md
in the bundle before attempting a firmware installation. Keep a recoverable
backup of your current device. Firmware writes can brick Glass.

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
