# Recovery preparation and known failure reports

The Mac app can check an existing XE24 Explorer installation, identify the audited
CWM recovery, copy an existing backup to the Mac, and stage the bundled backup in
a new recovery folder. **Prepared does not mean installed.** No restore, recovery
image write, unlock, erase, or bootloader modification is available in this flow.
No physical Glass installation or recovery test has been performed.

## Required steps

1. Select the Glass serial while Android is running. The check requires `Glass 1`,
   device `glass-1`, API 19, and XE24. Enterprise devices, unknown states, and older
   firmware are rejected. Recovery's own Android properties cannot substitute for
   this check.
2. The reported battery must be healthy, at least 70%, and between 0 and 45°C.
   This is a conservative preparation threshold, not a battery-health guarantee.
   The Android observation expires after 30 minutes. Keep power and USB stable.
   Expiration is checked again during uploads, before publication and before a
   Prepared result. Recovery does not provide a fresh Android battery reading.
3. Choose the explicit reboot-to-recovery step. Identity and battery are checked
   again before the reboot. If no compatible CWM exists, stop; the app does not
   install or temporarily boot a replacement image.
4. In CWM, create a current backup using its backup menu. The Mac app lists safe
   backup folder names and copies the selected flat tar backup into a **new** local
   directory. It checks all listed payloads against `nandroid.md5`, supports split
   `.tar.a`, `.tar.b`, etc., and compares remote/local SHA-256 while copying.
   Deduplicated backups, unknown files, links, incomplete partition coverage, and
   unsafe names are rejected. Copy verification does not prove restoration works.
5. Keep this off-device backup. The firmware preparation step verifies the bundled
   ZIP, requires the exact ten-file layout, and extracts only regular flat files.
   It checks CWM MD5 values and stages a fresh ASCII UUID folder. Each copied file
   is checked by SHA-256; only a complete verified folder is published for recovery.
   Existing backups are never deleted. Unfinished uploads remain partial.
   The verified Mac backup is rechecked before publication and success; loss or
   alteration of that copy prevents a Prepared result. A cancellation or transport
   error can leave an already submitted remote rename completed; inspect Glass
   before any restore and do not treat a folder name as a completion guarantee.
6. The app shows the final folder for CWM's restore menu. Restoring remains an
   on-device operation and can overwrite boot, system, data, and cache, including
   personal data. Do not proceed without a working recovery procedure for the
   actual unit. Never mistake archive preservation for unchanged device partitions.

The app checks the running recovery binary and partition table before staging and
again before each copy. It resolves `/sdcard` to the mounted data-media path rather
than assuming that `/sdcard` and `/sdcard/0` are interchangeable. It requires space
for the remaining upload plus a 256 MiB reserve. That reserve does not establish
that the restored system fits its partition; partition capacity and restore
behavior remain separate physical gates.

## Exact recovery evidence

Read-only inspection of the original Public Beta 3 `recovery.img` found:

- CWM-based Recovery `6.0.4.8`; build `11-20140613-UNOFFICIAL-glass_1`.
- `/sbin/recovery`: 992,600 bytes; SHA-256
  `c5f2c522a5c8f2569828470bb8d67c6ae6082ca91964713b0904df1df991315c`.
- `/etc/recovery.fstab`: SHA-256
  `f735746b62e92ad2c98824319e230e32a290910f7385dec6eece94d39de3703c`.
- `nandroid` links to `recovery`; `sha256sum`, `md5sum`, `stat`, and the filesystem
  tools used for preparation are present in its ramdisk.

[Era-matched CWM source](https://github.com/CyanogenMod/android_bootable_recovery/blob/dcd63504eac1d0826a9a4abb7fed2dab65ca1aa5/nandroid.c)
contains a restore CLI, MD5 checking, and filesystem formatting. Its restore CLI
selects boot, system, data, cache, and sd-ext by default. It also interpolates the
backup directory into an unquoted shell command, so generated ASCII paths are
necessary even if the host uses argument arrays. This source predates the bundled
build; it is supporting implementation evidence, not proof of reproducible
binary provenance or hardware compatibility. The app does not invoke that CLI or
write persistent recovery scripts.

## Manufacturer warnings and community reports

These sources describe distinct devices and software revisions. Firsthand reports
are useful failure evidence, not certified causes or instructions to bypass gates.

- **Manufacturer-confirmed incompatibility:** Google's documentation says flashing
  XE9 or earlier onto a device running XE10 or later will brick it. Unlocking also
  erases personal data. The preparation flow accepts XE24 and exposes no unlock or
  downgrade operation. [Google system downloads](https://developers.google.com/glass/tools-downloads/system)
- **Maintainer path warning:** ExplorerOS warns that spaces in firmware paths can
  cause incorrect folder transfer. Preparation uses fixed filenames and generated
  remote UUID paths. [ExplorerOS README](https://github.com/Zer0xDev/ExplorerOS)
- **Firsthand transport failures:** Users report hours at “Writing system,” timeouts,
  and lost USB links in the AOSP discussion. Maintainer jtxdriggers did not establish
  one reproducible cause. These reports do not prove that all USB 3 ports or Macs
  fail. The app stops after errors and never retries a partition write.
  [Glass AOSP discussion](https://www.reddit.com/r/googleglass/comments/kabh6o/glass_aosp_files/)
- **Firsthand recovery loss after a downgrade:** A user reports an XE12 downgrade
  followed by recovery failure with USB debugging disabled. This is an anecdote,
  not proof of a universal XE12 defect. It reinforces the need to establish a
  recovery route before changing firmware.
  [XE12 report](https://www.reddit.com/r/googleglass/comments/1tqxb7v/google_glass_xe12_bug/)
- **Device families differ:** In the Glassy maintainer discussion, Enterprise Edition
  support was untested and an EE1 user reported failure. Explorer checks must not be
  relaxed for an Enterprise device.
  [Glassy discussion](https://www.reddit.com/r/googleglass/comments/1rn6bhz/glassy_an_allinone_utility_for_google_glass/)
- **Temporary boot is not a blanket workaround:** postmarketOS contributors report
  temporary boot working on some Explorer units while flashing remained problematic.
  That does not validate this CWM image, an unknown bootloader, or this physical unit.
  The app does not substitute temporary boot for a missing compatible recovery.
  [postmarketOS device page](https://wiki.postmarketos.org/wiki/Google_Glass_%28Explorer_Edition%29_%28google-glass%29)

No source establishes a zero-brick guarantee. Exact model/current firmware,
partition capacity, recovery compatibility, tested restoration, and power/USB
stability remain necessary hardware checks. Host tests exercise synthetic files
and injected device responses only.
