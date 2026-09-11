# Public Beta 3 firmware bundle assessment

## Result

The original upstream archive has been acquired locally for inspection. The
user has authorized a private, local personal package for transfer between
their own Macs. That package may carry this unchanged local copy, together
with its provenance and hashes. It must not be published, rehosted, or offered
as a general downloader: public redistribution rights are not established by
public download access.

This is an unmodified original upstream download, not a rebuilt or repacked
custom ROM. Its SHA-256 identifies the exact local bytes. Preserve it unchanged
in the private local package and verify the hash before use.

## Provenance and local artifact

| Field | Value |
| --- | --- |
| Upstream release | ExplorerOS 26.0 Public Beta 3, version `26.0 (26PB8)` |
| Upstream repository listing | [Zer0xDev/ExplorerOS README](https://github.com/Zer0xDev/ExplorerOS) |
| Upstream Drive folder | [Public builds folder](https://drive.google.com/drive/folders/1sthRXSZ63CTTSfoUvg8625V3FmW4pmbe?usp=sharing) |
| Google Drive file ID | `1Y6JeQiSHetOuX7c_LSAqespGjnVa1Gty` |
| Local path | `artifacts/firmware/ExplorerOS-26-0-PublicBeta3.zip` |
| ZIP size | `514,795,860` bytes |
| ZIP SHA-256 | `a9997605089820b0bb23be90a126ed58cc2b853243af4ce4cc96c738d567a17d` |

The publisher supplied no detached signature or SHA-256 checksum in the
release listing. The SHA-256 above was computed after download and is a local
integrity record, not publisher authentication.

## Safe archive inspection

The archive is a ZIP with ten relative-path entries. `unzip -t` completed with
no errors. Its entries total `801,147,703` uncompressed bytes:

```text
boot.img
cache.ext4.tar
cache.ext4.tar.a
data.ext4.tar
data.ext4.tar.a
nandroid.md5
recovery.img
recovery.log
system.ext4.tar
system.ext4.tar.a
```

This is a CWM/Nandroid-style backup layout, consistent with the statically
inspected upstream Windows flow that moves a selected backup into
`/sdcard/clockworkmod/backup/` for manual Recovery UI restore. It is not an
approved raw-partition flashing manifest. No archive scripts were executed,
and no device command was run.

`nandroid.md5` records these MD5 values for non-empty payload entries:

```text
0d0c14cbcd9973207232317a697b3ebb  boot.img
75e2700996ec5d10539025870dab904e  cache.ext4.tar.a
3aaf955a07ed2f9b390097c3c88e0b9b  data.ext4.tar.a
bf23a3f7d888f228e2bd6e039e3eaefa  recovery.img
a9bdbb7a3c28b4d60f8ce83a664dc1b1  system.ext4.tar.a
```

The archive recovery image has SHA-256
`6a555ff943111b4a3c997a9a0157302afb2a2a930b6decfe7170ffeaf4c774f2`.
It differs from this repository's pre-existing `recovery/recovery.img`, whose
SHA-256 is
`514baecdbd301379a719d6aaf92a82c814ffb12b3169225815498cc0596effd0`.
Neither image is validated for any particular physical Glass state.

## Private package and licensing boundary

The archive has no `LICENSE`, `COPYING`, or `NOTICE` file. This repository's
GPL-3.0 license does not by itself grant redistribution rights for the original
firmware, recovery image, Google components, or CWM payloads. The authorized
private personal transfer is distinct from public distribution. Do not describe
the local package as publicly redistributable or upload its firmware payload.

Android Platform-Tools is separate software. The supplied
`sdk-repo-darwin-platform-tools.zip` NOTICE identifies its Platform-Tools
content as Apache License 2.0. Keep that NOTICE, Apache 2.0 text, and every
included component notice with an unchanged private package. The Android SDK
3.5 terms leave open-source components under their own licenses; preserve those
component terms rather than replacing them with this project's GPL-3.0 text.
The upstream reference is [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools).

## Release identity and modular-app evidence

Read-only inspection of `system/build.prop` identifies the system base as:

```text
ro.product.model=Glass 1
ro.product.device=glass-1
ro.build.version.sdk=19
ro.build.version.release=4.4.4
ro.build.fingerprint=Google/glass_1/glass-1:4.4.4/XRH35/5585826:user/release-keys
ro.build.version.glass=XE24
ro.build.version.minor.glass=RC01
```

The CWM data payload also includes two user-package APKs under `data/app/`:

```text
com.zeroxdev.ExplorerLauncher-1.apk  38,693,836 bytes
com.mikedg.android.glass.launchy-1.apk  117,677 bytes
```

This is static evidence that this release carries ordinary installed APKs in
addition to its privileged system packages. It supports the bridge design as a
non-privileged API 19 APK overlay; it does not prove a particular physical
Glass currently has USB debugging, accepts an APK, or grants a bridge any
privileged Bluetooth role.

## Existing Hands-Free implementation evidence

`system/priv-app/GlassBluetooth.apk` is present with static SHA-256
`b621f843709abff9f9dc90a0913f1b13d2893548bb86800d5e422fe56750e9e5`.
Its read-only DEX string table contains a proprietary Hands-Free client:

```text
com.google.glass.bluetooth.handsfree.HandsFree
com.google.glass.bluetooth.handsfree.HandsFreeProfile
com.google.glass.bluetooth.handsfree.ScoConnection
com.google.glass.bluetooth.handsfree.PhoneCallManager
BLUETOOTH_HANDSFREE_AUDIO_GATEWAY_UUID
AT+BRSF=
AT+BVRA=
AT+CMER=3,0,0,1
```

It also contains SCO audio reader/writer classes. The release audio policy
declares `AUDIO_DEVICE_OUT_ALL_SCO` plus
`AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET`. Together these are static evidence of
an existing privileged Glass HFP Hands-Free/SCO implementation, not a generic
public Android `Headset` role exposed to the bridge APK. They do not prove it
starts on this release, interoperates with a modern iPhone, supports Siri, or
is controllable by a third-party app. No call, pairing, or audio session was
attempted.

## Permitted next work

Keep this original archive unchanged, preserve the Platform-Tools notices,
record any future publisher-provided checksum or signature, and verify the ZIP
SHA-256 before use. Keep recovery or hardware writes outside automated
application behavior. This assessment provides no safe-flash claim and no
physical Glass validation.

See [UPSTREAM-INSTALLER.md](UPSTREAM-INSTALLER.md) for the separate static
inspection of the original Windows installer.
