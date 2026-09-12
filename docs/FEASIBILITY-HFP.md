# Stock HFP voice adapter in Public Beta 3

## Implemented boundary

The installed API 19 bridge has a narrow adapter for the unchanged stock
Glass Hands-Free client. Camera press inside the bridge requests voice recognition;
a second press cancels. Holding Camera requests it on long press and cancels on
release. Leaving the bridge also cancels its own request. Camera events are not
intercepted while another application or the ExplorerOS launcher has focus.

The bridge sends the audited, package-targeted stock voice-recognition broadcast.
It does not bind a guessed service, open another RFCOMM/SCO connection, change audio
routing, or modify the stock Bluetooth APK. The existing service sends `AT+BVRA=1`
and `AT+BVRA=0`; its SCO path already contains phone playback and microphone input.
Actual modern-iPhone Siri, audible playback, microphone quality, and Glass hardware
operation remain untested. A successful local broadcast is not a Siri acknowledgement.
There is no always-listening microphone service or "Hey Siri" wake-word detector.
The implemented trigger is the Camera button while the bridge surface is active.

The display initially says **Siri requested**. It changes to **Bluetooth voice audio**
only while an owned request has an observed `AudioManager.isBluetoothScoOn()` route.
This is an audio-routing flag, not proof of sound or a Siri listening-versus-speaking
state. The stock parser exposes no `+BVRA` recognition-state callback. There is no
invented Listening indicator, transcript, or text reply implementation.

## Runtime gates and cleanup

`StockVoiceAdapter` requires all of these:

- API 19. Either an ordinary APK installation or the preinstalled bridge can use
  this path; root and a ROM reflash are not required.
- The enabled stock `com.google.glass.bluetooth` system package with the exact
  SHA-256 below. Hashing happens on a worker at startup and immediately before
  every outbound start/stop broadcast. Path, size, timestamp, call and bond gates
  are rechecked before dispatch and while monitoring the route. Cancellation
  invalidates queued starts; teardown permits only its already-owned stop.
- A fresh stock `HEADSET_STATE` connected broadcast naming a bonded Bluetooth device.
  Its receiver requires the sender to hold the stock `COMPANION` permission. Initial
  sticky connection broadcasts are ignored because their original sender cannot be
  authenticated retrospectively. Reconnect the headset in system Bluetooth settings
  after initial bridge setup or a bridge restart if no fresh connection was observed.
- No observed call and no pre-existing SCO route. The bridge never takes ownership
  of an already-running phone audio session.

Stock call-state broadcasts update a call veto. A sticky true call state is also
checked immediately before start/cancel; sticky false never clears that veto.
An incoming/active call drops request ownership without sending a stop command.
Only the bridge's own request may be cancelled. Release, leaving the activity,
revocation, opt-out/service teardown, and a 30-second timeout clear monitoring;
stop is sent only while the stock connection remains valid and no call is observed.
A route that turns off after being observed on completes the local request.
Cross-process call-state delivery and audio timing still require physical testing.

## Audited artifact and exact endpoints

| Item | Value |
| --- | --- |
| Original firmware | `artifacts/firmware/ExplorerOS-26-0-PublicBeta3.zip` |
| Archive SHA-256 | `a9997605089820b0bb23be90a126ed58cc2b853243af4ce4cc96c738d567a17d` |
| APK path | `system/priv-app/GlassBluetooth.apk` |
| APK SHA-256 | `b621f843709abff9f9dc90a0913f1b13d2893548bb86800d5e422fe56750e9e5` |
| Package/version | `com.google.glass.bluetooth`, `XE22.0`, code `2200` |
| Voice action | `com.google.glass.action.BLUETOOTH_VOICE_RECOGNITION` |
| Boolean extra | `com.google.glass.extra.ENABLE_VOICE_RECOGNITION` |
| Connection action / state extra | `com.google.glass.action.HEADSET_STATE` / `com.google.glass.extra.STATE` |
| Connected / disconnected values | `1` / `0` |
| Device extra | `android.bluetooth.device.extra.DEVICE` |
| Call action / boolean extra | `com.google.glass.action.PHONE_CALL_STATE_CHANGED` / `call_state` |

`XE22.0` is the APK's own version; the surrounding system is XE24 RC01.
Read-only APK/DEX inspection established:

1. `HandsFree.startServiceConnection` registers `CallActionBroadcastReceiver`.
   Its `SafeBroadcastReceiver` constructor supplies a null sender permission;
   registration uses the ordinary two-argument `registerReceiver` overload.
2. `CallActionBroadcastReceiver.onReceiveInternal` checks an existing running
   service connection, reads the boolean extra, and calls
   `ServiceConnection.startVoiceRecognition`, which enqueues `AT+BVRA=1/0`.
3. `HandsFree.onConnected/onDisconnected` call
   `BluetoothHeadset.broadcastHeadsetState`. Stock code sends the call-state
   boolean through `PhoneCallHelper.setInCall` during call setup/state changes.
4. `ServiceConnection.ReaderThread` routes `OK/ERROR` to its command queue,
   processes call indicators, and retains the in-band-ring bit from `+BRSF`.
   It has no voice-recognition-state callback and does not export AG voice support.
5. `ScoConnection.handleNewConnection` enables SCO routing and `hf_bt`; its
   optional audio pump has reader/writer threads. `PhoneCallManager.shouldHandleAudio`
   permits non-call audio while Glass is worn. These are stock responsibilities.

## Permission correction

The exported `GlassBluetoothService` service requires
`com.google.glass.bluetooth.permission.COMPANION` (`signatureOrSystem`). Its only
accepted binding action, `com.google.glass.bluetooth.COMPANION_SERVICE`, returns the
companion socket Binder, not an HFP control Binder. This adapter does not bind it.

The actual PB3 `services.jar` `PackageManagerService.grantSignaturePermission`
checks `isPrivilegedApp` for this grant. Installation under `/system/app` alone
does not grant that permission; the dedicated privileged directory is distinct.
This matches the [Android permission model](https://developer.android.com/guide/topics/manifest/permission-element).
The adapter uses that permission only as a sender filter on its observer, relying
on the stock Bluetooth package's declared use of it, and requests no new permission.
The stock voice receiver does not require a sender permission. Removing the bridge's
own system-app requirement therefore permits APK-first testing without relaxing
the exact stock-package hash, system-package, bond, call, or audio-ownership gates.

No proprietary code is copied into project source. No device commands, installation,
flash, reboot, or live Bluetooth/audio test was performed for this adapter. JVM
policy tests cover unavailable, call, existing-route, ownership, timeout, route-end,
disconnect and trust-loss behavior. APK compilation proves API availability only.
