# iPhone control through a Mac

This optional workflow still requires a Mac connected to Glass by USB. It is not
the requested iPhone-only flasher. No direct iPhone flashing implementation is
available; see [the evaluated alternatives](IPHONE-FIRMWARE-OPTIONS.md).

1. Open the complete portable Explorer Tools app on the Mac. On **Firmware**,
   refresh devices and select the exact Glass serial in normal Android mode.
2. Open **iPhone installer** and choose **Enable iPhone control**. Keep both
   devices on the same private Wi-Fi network. No device is automatically selected.
3. Copy the private connection code. In Explorer Link on iPhone, open
   **Glass > Firmware**, paste the code and connect. Keep both apps open.
4. Follow **Check Glass**, **Restart in recovery**, and **Check recovery**. The
   existing Android identity, battery, temperature and pinned CWM checks apply.
5. Make a fresh CWM backup on Glass. Find it from iPhone and copy it to the Mac.
   The host verifies the backup before allowing firmware preparation.
6. Review the displayed serial and firmware, then choose **Copy firmware**.
   The Mac validates its bundled archive and copies a new verified recovery
   folder to Glass. **Prepared** means copied, not installed.
7. If proceeding with restoration, use the CWM controls on Glass as described in
   [FLASHING.md](FLASHING.md). Restore can overwrite boot, system, data and cache.
   Software checks do not establish physical compatibility or guarantee recovery.

The Mac retains backups in its application support folder under
`org.exploreros.ExplorerTools/Backups`. Keep that backup available during
preparation and afterwards for recovery. The phone cannot choose arbitrary Mac
paths, run shell commands, erase, unlock, write raw partitions or trigger a restore.

Connections use the existing authenticated AES-GCM protocol with a fresh private
key for each enabled host. The code expires when the host stops. Replayed or stale
mutating requests are rejected. The host cancels on peer loss or after 20 seconds
without a valid authenticated request. The phone separately disconnects after
20 seconds without an authenticated host response. Cancellation cannot undo a
completed device command. Reconnect and recheck Glass before restoring. If Glass is already
in recovery, returning to normal Android may be required to repeat the checks.

Local Mac controls remain reserved until a canceled operation finishes. Closing
the host window cancels it; app termination waits for that cancellation. No
listener or device command starts merely by opening the application.

## Validation boundary

Automated tests run the actual TCP listener against simulated hosts and exercise
the recovery host through fake ADB runners. They cover authentication, malformed
messages, replay, deadlines, serial binding, backup corruption, cancellation and
state transitions. They do not prove physical USB, CWM restore or iPhone-to-Glass
firmware installation. The release UI contains no direct USB flash control.

A developer-only `--usb-probe-debug` screen performs an explicitly started,
read-only ImageCaptureCore camera-discovery check. It never opens a camera
session, sends PTP commands, uploads files or changes USB mode. It is excluded
from the release UI because it cannot install firmware.
