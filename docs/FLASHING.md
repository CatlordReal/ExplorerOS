# Mac firmware safety boundary

Raw partition writing is disabled. `FlashExecutor.execute` always throws before
calling a subprocess, including for an otherwise valid plan. No manifest, serial,
acknowledgement, or UI setting can enable it. The Mac app has no firmware write
button. Normal APK installation remains available separately.

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

## CWM restoration

The bundled firmware remains a CWM recovery backup. A manual restore can rewrite
boot, system, data and cache, including replacement of personal data. Installing a
recovery is a separate firmware write. Preserving the original archive's entries
does not mean those device partitions stay untouched.

Firmware writes can brick Glass. The derived package has not been certified safe
to restore. Use the APK on an existing compatible system for initial testing.
Before considering a full restore, verify the exact unit and release, retain a
device-specific backup, and establish a working recovery path on real hardware.
