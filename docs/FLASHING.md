# Safe Mac flashing boundary

`ExplorerFlashCore` prepares reviewable `fastboot`/`adb` argument arrays. It does not use a shell, unlock a bootloader, erase partitions, flash a bootloader/radio, discover a device automatically, or run during tests.

Static inspection of `ExplorerFlasher.exe` establishes an upstream CWM-backup recovery restore flow; see [UPSTREAM-INSTALLER.md](UPSTREAM-INSTALLER.md). It does not establish a safe hardware result, exact compatible device state, or a raw-partition image layout. Consequently, this project remains a generic image flasher. It cannot install an ExplorerOS CWM backup tar, infer the required recovery state, or derive an approved raw-partition manifest. No real-Glass flash has validated this utility.

## Manifest

The selected JSON manifest lives beside its images. Only `boot`, `system`, and `recovery` partitions are permitted. Each image needs an exact byte size and lower/upper-case hexadecimal SHA-256. Paths are relative, must remain under the manifest directory, and must reference regular non-symlink files.

```json
{
  "product": "glass_1",
  "images": [
    {"partition":"boot","file":"boot.img","sha256":"<64 hex characters>","size":123456},
    {"partition":"system","file":"system.img","sha256":"<64 hex characters>","size":123456}
  ]
}
```

`glass_1` is an example only. Confirm exact output of `fastboot getvar product` for the connected unit before creating a manifest. Flash planning refuses unsafe paths, links, bad hashes/sizes, duplicate or unsupported partitions, ambiguous/unrecognized devices, unauthorised ADB devices, and mismatched product.

## Required review and physical procedure

1. Select explicit `fastboot` and `adb` executable paths, one serial, a manifest, and optionally an APK.
2. Review generated arrays, for example: `fastboot -s SERIAL getvar product`, then `fastboot -s SERIAL flash boot /absolute/boot.img`. Spaces stay inside one argument; no shell quoting is used.
3. Read product, partition names, hashes, sizes, and device serial in review screen. Type the exact serial to authorize flashing.
4. Immediately before first image, re-enumerate selected device and revalidate every image hash/size/path. Read product. Revalidate device and images again before every partition.
5. Stop at first failed command. Never continue after an error. Reconnect/review from the beginning before another attempt.

APK installation remains separate: `adb -s SERIAL install -r /absolute/Explorer Link.apk`. It targets an explicitly selected authorised ADB device and accepts only a regular non-symlink `.apk`.

Physical flashing can brick a Glass. Static/unit checks and simulator output do not prove XE24 bootloader state, USB cable stability, battery level, image compatibility, or recovery path. Keep a known-good recovery method available; do not flash until actual upstream release layout and device product have been verified.
