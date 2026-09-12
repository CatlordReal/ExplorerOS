# Real Glass verification

No Glass flash, unlock, erase, reboot, or APK installation was performed during development. Host builds and simulators do not establish that a firmware write is safe.

## Start with the APK

Keep a working Glass firmware installation. Confirm the physical device is Explorer Edition, record its current firmware version, and verify USB debugging/ADB authorization. Install only the bridge APK through explicit serial selection. This avoids changing boot, system, recovery, or bootloader partitions while testing iPhone integration.

Test and record:

- API 19 application launch, 640×360 layout, focus/touchpad gestures, camera short/long press, and navigation between setup/media/notification panels.
- AES-GCM provider support on actual XE24. Desktop Java cryptography success does not prove Android's provider.
- Wi-Fi pairing, wrong-key rejection, range loss, reconnect, idle timeout, revocation, and duplicate connection behavior.
- BLE controller support, central scan/discovery, pairing/encryption, ATT fragmentation, queued writes, permission denial, and reconnect when iPhone is locked/backgrounded/force-quit.
- ANCS service discovery and system notification authorization; fragmented title/body attributes; multiple notifications; modification/removal; no action when its flag is absent; no stale content after disconnect.
- AMS supported command notifications, track title/artist, play/pause/next/previous only when offered, command changes, and service disappearance/re-discovery.
- Both direct system GATT services and the custom companion service on one iPhone connection, including Service Changed handling.
- Camera sync opt-in on Glass and Receive media opt-in on iPhone; authenticated Wi-Fi-only capability exchange, JPEG/PNG/MP4/3GPP catalog admission, source stability, chunk/ack loss, timeout, cancel, deduplication, private vault quota, and explicit Save to Photos. Verify originals remain on Glass and that no media transfers while either opt-in, Wi-Fi, or foreground state is absent.
- Battery draw, radio coexistence, sound/microphone routing and thermal behavior over sustained sessions.

## Headset Siri research gate

The installed bridge can request voice recognition from the audited stock HFP Hands-Free service; see [FEASIBILITY-HFP.md](FEASIBILITY-HFP.md). On real Glass, verify pairing with iPhone as Audio Gateway, service-level negotiation, `AT+BVRA=1`, audible Siri playback, microphone capture, `AT+BVRA=0`, call interruption, timeout, and cleanup. Reconnect system Bluetooth once after bridge startup so its observer receives a fresh trusted connection event. The indicator reflects the observed Bluetooth audio route, not Siri's exact listening phase. Camera control applies inside the active bridge surface, not the unchanged ExplorerOS launcher. Obtain platform source and a reproducible recovery path before modifying the underlying Bluetooth/audio implementation.

No always-listening "Hey Siri" detector is implemented. Global Siri transcripts are unavailable through the public iOS APIs used here. App dictation is a separate user-started feature and must be tested as such. The guarded HFP adapter can be tested using an ordinary APK installation when the audited stock Bluetooth package is present; no ROM flash is required.

## Before firmware work

Read [UPSTREAM-INSTALLER.md](UPSTREAM-INSTALLER.md) and [FLASHING.md](FLASHING.md). Verify the exact release files and hashes, supported current bootloader/firmware, actual installation sequence, power/cable stability, and working restoration procedure. Do not assume the bundled recovery image is suitable merely because it exists. No valid ExplorerOS flash manifest is supplied while those facts remain unverified.

Raw partition execution is disabled in the Mac app. Its read-only checksum, serial, product and partition checks do not validate image format, partition capacity, boot compatibility, or recovery. A CWM restore can overwrite boot, system, data and cache, including personal data. The build report's preservation checks compare archives only; they do not guarantee unchanged device partitions or a safe restore.
