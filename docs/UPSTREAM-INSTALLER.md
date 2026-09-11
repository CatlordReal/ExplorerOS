# Upstream ExplorerFlasher static inspection

This records a **read-only** extraction of `ExplorerFlasher.exe`. The executable
was not launched and no ADB, Fastboot, recovery, or device command was run.

## Evidence

- File: `ExplorerFlasher.exe`
- SHA-256: `06f7cdd34378161642bd5ce6fd9741a921cf9412f400d52d592191bf7c75bc92`
- File identification: PE32+ Windows x86-64 console executable
- PyInstaller cookie: `MEI\x0c\x0b\x0a\x0b\x0e`, package length `9,059,494`,
  TOC offset `9,058,302`, TOC length `1,104`, Python `3.14`.
- The extracted `install.py` CArchive script has a compressed size of `5,786`
  bytes and uncompressed size of `14,325` bytes.

`tools-cache/extract_pyinstaller_static.py` parses the CArchive metadata,
decompresses the script, marshal-loads it, and prints constants/disassembly.
It does not import or execute extracted code.

## Observed installer flow

The static script rejects macOS, checks that `adb` and `fastboot` exist, then
loops on `adb devices` until it sees a device. It asks whether the device is in
Android with USB debugging enabled.

It scans `builds/` for entries containing `ExplorerOS` while excluding entries
containing `.zip`, presents a selected entry, and requires
`<selected>/data.ext4.tar.a` to exist. It then constructs an ADB push from the
selected build path to `/sdcard/`.

Next it executes `adb reboot bootloader`, polls `fastboot devices`, checks that
`recovery/recovery.img` exists, flashes recovery, and executes `fastboot
reboot`. It waits for ADB again and executes `adb reboot recovery`.

The script prompts the operator to use CWM Recovery menus, then executes these
device mutations:

```text
adb shell rm -rf /sdcard/clockworkmod/
adb shell mkdir /sdcard/clockworkmod/
adb shell mkdir /sdcard/clockworkmod/backup/
adb shell mv /sdcard/0/<selected> /sdcard/clockworkmod/backup/
adb reboot
```

It instructs the operator to mount `/data`, then restore the selected CWM
backup through Recovery's `backup and restore` UI. After the restore, its
activation section disables automatic time, sets device date/language/country,
creates local activation files containing user-supplied service keys, and runs
`adb push . /sdcard/ExplorerOS/` from that activation directory.

## Safety and implementation notes

This upstream flow is destructive to the device's
`/sdcard/clockworkmod/` directory and changes recovery and system state. A Mac
utility should never reproduce it automatically. It should surface a reviewed
plan, validate required files and selected device, and require explicit
confirmation for each device-mutating command.

The extracted Windows command construction deserves review before any future
manual use: the visible fastboot branch concatenates `fastboot flash recovery`
with the selected build path, despite separately testing for
`recovery/recovery.img`. Static inspection establishes that this is how the
upstream script is written; it does not establish a safe or successful flash
result.

No physical device, firmware image, recovery operation, or credentials were
accessed during this inspection.
