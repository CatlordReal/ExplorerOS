# Mac firmware safety boundary

Raw partition writing is disabled. `FlashExecutor.execute` always throws before
calling a subprocess, including for an otherwise valid plan. No manifest, serial,
acknowledgement, or UI setting can enable it. The Mac app can copy verified backup files into a new recovery folder, but cannot
restore partitions. Normal APK installation remains available separately.

Static inspection of `ExplorerFlasher.exe` establishes an upstream CWM-backup
restore flow; see [UPSTREAM-INSTALLER.md](UPSTREAM-INSTALLER.md). It does not establish
a safe hardware result, a compatible device state, or approved raw-partition
images. No physical Glass installation or recovery test has validated this utility.

## Read-only image review

`ExplorerFlashCore` can prepare argument arrays for review. A selected manifest
must live beside its images. Only `boot`, `system`, and `recovery` partition names
are permitted. Each file needs an exact size and SHA-256. Paths must remain under
the manifest directory and reference regular non-symlink files. Review also checks
explicit device selection and matching product metadata.

These checks establish file integrity and selection only. They do not inspect
the image format, prove partition capacity, establish boot compatibility, or
validate recovery. A ZIP or tar with matching metadata could pass those checks;
the execution block still prevents it from being written. Never copy a generated
command into a terminal as an installation instruction.

Enabling writes in a future release requires a validated device and image profile,
format and partition-capacity checks, a tested recovery procedure, and a process
lifecycle that cannot kill an active partition write on a generic timeout or quit.
The existing bounded process runner must not be reused for raw flashing.

## APK installation

The separate installer uses `adb -s SERIAL install -r /absolute/ExplorerLink.apk`.
It requires an explicitly selected authorized device and a regular non-symlink
APK, and revalidates the selected device and file before execution. It does not
flash boot, system, recovery, radio, or bootloader partitions.

## Guided recovery preparation

Explorer Tools v0.1.0 (build 5) provides five explicit steps:

1. **Check Glass.** Connect while Android is running, enable USB debugging, and
   select its serial. The check requires Explorer Edition `Glass 1`, `glass-1`,
   API 19, XE24, and a reported healthy battery of at least 70% at 0–45°C.
2. **Open recovery.** Choose the separate restart action, then check recovery.
   The app requires the audited CWM binary and partition table already installed,
   root ADB, and the expected mounted storage. Unknown or missing recovery stops
   the flow; the app does not install or temporarily boot a replacement.
3. **Save a recovery backup.** On Glass, use `backup and restore > backup`. After
   it finishes, refresh the Mac list, select the current backup, and choose a Mac
   destination. The app creates a new directory, checks the backup manifest and
   split tar files, and compares copied bytes using MD5 and SHA-256. Verification
   proves the copy's integrity, not that restoration will succeed. The copied
   directory, file identities and hashes are rechecked before staging.
4. **Prepare firmware.** Confirm copying the bundled CWM ZIP. The app verifies
   its SHA-256 and strict ten-file layout, then stages files in a new hidden partial
   folder under the resolved `clockworkmod/backup` directory. It checks recovery,
   serial, path and free storage repeatedly and verifies every copied file before
   publishing the final folder. Existing backups are never removed.
5. **Restore on Glass.** The app displays **Prepared**, with the exact folder for
   `backup and restore > restore`. It does not execute this menu action. Do not
   confirm restoration until the physical unit's compatibility and recovery path
   have been established.

Stop current step cancels preparation work; copied files remain for diagnosis.
Do not select partial folders in recovery. The Android identity/battery observation
expires after 30 minutes; an expired observation requires a new Android check.
Device staging requires space for the remaining copy plus a 256 MiB reserve;
this does not prove that restored contents fit their target partitions.

## CWM restoration risks

The bundled firmware remains a CWM recovery backup. A manual restore can rewrite
boot, system, data and cache, including replacement of personal data. Installing a
recovery is a separate firmware write. Preserving the original archive's entries
does not mean those device partitions stay untouched. Neither the ZIP nor its
`*.tar.a` files are raw partition images.

Firmware writes can brick Glass. The derived package has not been certified safe
to restore. Use the APK on an existing compatible system for initial testing.
Before considering a full restore, verify the exact unit and release, retain a
device-specific off-device backup, and establish a working recovery path on real
hardware. [COMMUNITY-SAFETY.md](COMMUNITY-SAFETY.md) separates manufacturer-confirmed
downgrade hazards from firsthand USB, recovery and model-compatibility reports.
No host check or successful file copy supplies a zero-brick guarantee.
