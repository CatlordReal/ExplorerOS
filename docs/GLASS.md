# Explorer Link Glass bridge

`glass-bridge` is a standalone Android APK for Google Glass Explorer Edition
XE24 (Android API 19). It is an app layered on the supplied firmware image. It
does not itself alter a boot image, launcher, Bluetooth stack, or recovery image.
A separate host packaging workflow may preinstall the APK into ExplorerOS;
Android boot/service integration then operates without a launcher replacement.

## Current capability boundary

The APK is an authenticated local Explorer Link endpoint. It listens for Wi-Fi
TCP on port `8765` and can act as a BLE central for the iPhone's Explorer Link
peripheral. Both paths use the frozen v1 wire contract in
[`protocol/PROTOCOL.md`](../protocol/PROTOCOL.md): strict UTF-8 NDJSON framing,
32 KiB maximum lines, fresh challenges, AES-256-GCM with a fresh 12-byte nonce,
the fixed `ExplorerLink/1` AAD, and monotonically increasing sequences.

Pairing is explicit. The QR payload is the documented JSON object containing a
unique 32-byte hexadecimal key. The Glass app stores it only in private app
storage. The Glass screen's **Revoke pairing** control removes the key and
saved BLE peer and closes active transports. No key, notification text, or media metadata is
written to logs.

BLE initial pairing uses a foreground scan. The user selects a discovered
iPhone address; it is saved only for reconnecting that selected peer. The
custom GATT service uses RX writes with response and TX notifications, split
into 20-byte chunks when necessary. The client serializes all GATT writes and
descriptor changes, has a bounded 2,048-operation queue, and closes on a
GATT/protocol failure.

ANCS and AMS are consumed directly from a bonded iPhone only after their
system GATT services and required characteristics have actually been
discovered. ANCS notification attributes are parsed across fragmented Data
Source notifications and are displayed only in memory. Positive/negative ANCS
actions are sent only when their individual Notification Source flags permit
them. AMS remote commands remain disabled until AMS reports their supported
command bytes; received metadata is not logged or persisted.

The API 19 service can request voice recognition through the exact stock Glass
HFP implementation, whether installed normally or preinstalled in the firmware.
**Siri requested** means a request was sent; **Bluetooth voice audio** means the
SCO route flag was observed during that request. Neither proves Siri listening
or audible output. See [stock HFP gates and limitations](FEASIBILITY-HFP.md).
"Hey Siri" wake-word detection is not implemented. AMS media support controls
playback and metadata; it does not transfer camera files. Separate opt-in Camera
sync can send selected camera-library captures only to an authenticated, capable,
foreground Wi-Fi iPhone receiver; see [MEDIA-SYNC.md](MEDIA-SYNC.md).

## Camera sync

**Setup > Camera sync** is off by default. When enabled, Glass scans a bounded
API 19 MediaStore page under `DCIM/Camera`, admits only regular JPEG, PNG, MP4,
or 3GPP files with matching headers and limits, and never deletes or edits a
source capture. It sends only after the iPhone advertises `media.receive.tcp.v1`
over authenticated TCP. One 3,072-byte chunk is outstanding at a time; source
metadata and streaming SHA-256 are checked before completion. A disable, path
loss, error, or timeout cancels the active transfer. Physical camera catalog,
storage permission, source stability, and Wi-Fi behavior remain hardware gates.

## Build and test

Use Java 17, Gradle 8.11.1, and Android SDK platform/build-tools 35. The app's
minimum SDK is 19; `targetSdkVersion` is 28 to preserve API19-compatible
Bluetooth behaviour.

```sh
cd glass-bridge
./scripts/test-core.sh
ANDROID_SDK_ROOT=/tmp/explorer-android-sdk GRADLE_BIN=/tmp/gradle-8.11.1/bin/gradle ./scripts/build-apk.sh
```

The resulting debug APK is
`app/build/outputs/apk/debug/app-debug.apk`. Building or installing it never
flashes, unlocks, erases, or otherwise changes Glass firmware. Installation and
physical-device validation remain deliberate user actions.

Use the [modular update procedure](MODULAR-UPDATES.md) for published replacements.
Debug builds made with a different signing key cannot update the bundled APK.

`test-core.sh` is dependency-free pure JVM coverage for protocol framing,
invalid UTF-8, strict Base64, deterministic shared AES-GCM fixture decrypt and
re-encrypt, challenge/replay rejection, fragmented ANCS attributes, action
flags, and touchpad gestures. The fixture is public test data only and is never
a provisioning key.

## UI and themes

The compact Glass screen displays cards/navigation, connection diagnostics,
BLE pairing choices, and touchpad/camera input. Swipe down clears the local
card while still reporting the input to a connected companion. Inside this
activity, Camera press requests/cancels stock HFP voice recognition. Holding
Camera requests it on long press; release cancels the owned request. These
camera events stay local and are not forwarded as iPhone Siri commands.

Theme control cycles Latte, Frappé, Macchiato, Mocha, Sand, Dawn Paper, Golden
Sand, Golden Paper, Sunset, Dusk, explicit Light/Dark/System, and local-time
schedule choices for time, sunrise, golden hour, sunset, and dusk. API19 has
no public automatic solar-location service, so the four solar labels use
conservative local-hour fallbacks until a consented location source is added.
All current palettes keep high contrast for the Glass display.

## Hardware gates

A successful APK build and JVM tests prove source-level and packaging paths;
they do not prove XE24's AES-GCM provider, BLE pairing, iPhone bonding, ANCS,
AMS, touchpad, camera key delivery, background behavior, or radio operation.
Pair with both apps foregrounded, verify the diagnostics screen, then exercise
Wi-Fi, custom BLE, ANCS, and AMS one at a time on a physical Glass/iPhone pair.

## Direct iPhone notification and media controls

The main 640×360 layout reserves the center for the current card. **Actions**,
**Media**, and **Setup** open separate panels. Setup contains provisioning,
scanning, peer selection, themes, and revocation. No setup buttons consume the
card body. On the touchpad, tap opens Actions; panel swipes select a control,
tap activates it, and swipe down returns to the card. Card swipes send the
documented companion input events. Camera uses the local stock HFP adapter.
Touchscreen swipes are observed before child views consume them; generic
motion events are handled for the Glass touchpad. Physical delivery still
requires the hardware checks below.

ANCS subscribes to Data Source before Notification Source. Notification
attribute requests are serialized, including across fragmented replies.
Added and modified notifications fetch title, message, and action labels;
removed notifications disappear immediately. A modified or removed UID cannot
use stale action flags. Actions displays only the positive/negative actions
advertised for that notification and uses the phone's action labels. The
session is bounded to 64 active notifications; old entries are evicted when the bound is reached. Malformed replies close
the BLE session. An absent attribute reply disables ANCS until explicit
reconnect while Explorer Link and AMS continue. A rejected Control Point
write generates no attribute reply, so its fetch is retired and the next
queued notification proceeds. Removed in-flight replies are drained and
discarded; their fragments cannot be mistaken for the next notification.

AMS subscribes to the actual Remote Command characteristic
`9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2`. Its notifications replace the supported
command set. Entity Update notifications are enabled before writing Player
`[0,0,1]` and Track `[2,0,2]` subscriptions. Media shows the player, title and
artist. Play, Pause, Play/Pause, Previous and Next are enabled individually
from the current command set; commands are rechecked when their GATT write
starts. A truncated metadata value is displayed with an ellipsis. This
bounded preview does not fetch extended Entity Attribute values.

Both transports publish `ancs.available` and `ams.available` only after bonded BLE
discovery and successful completion of their subscription/registration writes; disconnect removes them. These identify configured adapters,
not proof that a media command was acted on. Generic Attribute Service Changed
indications close the session and clear state; reconnect performs fresh
service discovery. When the characteristic is absent, reconnect manually to
rediscover services. ANCS/AMS attributes, UIDs, command flags, session crypto
state, and discovered candidates are cleared on BLE close/rekey/revocation.

Custom iPhone Explorer Link advertising and delivery must be tested with the
companion foregrounded. This app does not promise reliable iOS background
execution. OS authorization/bonding, service publication, and real radio
operation remain physical-device gates. No Glass installation, flashing,
unlocking, erasing, or rebooting was performed by the build/test workflow.

Protocol implementation references:
[Apple ANCS specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html),
[Apple AMS specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleMediaService_Reference/Specification/Specification.html), and
[AMS IDs and flags](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleMediaService_Reference/Appendix/Appendix.html).

JVM tests additionally cover ANCS burst serialization, in-flight removal and
modification, action labels, withdrawn actions, AMS subscription bytes,
metadata parsing, malformed UTF-8, command-set replacement and session reset.

ANCS/AMS require `BOND_BONDED`. Use **Setup > Bluetooth settings** to pair the
iPhone with Glass, then reconnect in Explorer Link for fresh discovery. The
custom encrypted link may run before bonding; ANCS/AMS remain unavailable.
JVM setup-barrier tests verify capabilities cannot become ready before all
earlier GATT callbacks succeed, or after a failed callback.


## Background integration

After initial setup on API 19, the installed app receives `BOOT_COMPLETED` and
`MY_PACKAGE_REPLACED`. It starts the foreground service only when a valid
pairing key exists and **Background: On** is selected. A paired enabled service
uses `START_STICKY` for OS restarts. Unpaired or disabled installs start no boot
activity, listener, scan, timer or wake lock. Use **Explorer Link setup** once to
provision the key and choose the iPhone; Setup remains in the app menu and the
service notification.

The saved BLE address reconnects directly. Failed connections have a 30-second
deadline and six non-waking retry delays: 1, 2, 5, 10, 30 and 60 seconds. The
budget resets after authentication or an explicit reconnect. After exhaustion,
**Setup > Reconnect** retries; no background scan is started. Explicit scans
stop after 30 seconds. Turning background integration off closes the service,
cancels retry/presentation state and prevents boot or sticky restart. Opening
Setup can still run a manually controlled session until the app leaves the
foreground.

An authenticated incoming card or route, or a newly added non-silent ANCS
notification, presents an isolated card Activity. Its intent contains only an
in-process token, never notification text. The Activity is not exported;
only the separate Setup launcher alias is exported. Foreground setup and
provisioning flows suppress automatic presentation. Pre-existing ANCS
notifications and modifications never open a new surface. Notifications remain
available in Actions while the service session exists.

Automatic surfaces return to the configured HOME launcher on swipe down,
Back, removal/disconnect, or a 30-second timeout. Switching to another app
finishes the automatic surface without redirecting that app. Entering Setup
converts to an explicit manual session. Dismissal suppresses fresh popups for
10 seconds; dismissing navigation suppresses its later steps until navigation
stops. Bursts cannot repeatedly launch new Activities. The surface is excluded
from Recents and does not replace or set the default launcher. No keyguard is
dismissed. Brief display wake/keep-on flags exist only on the bounded automatic
surface; the service owns no wake lock.

ExplorerOS Public Beta 3 launcher inspection found no supported card IPC.
Integration uses Android activities/services; there is no invented native
launcher hook. Global camera-button interception while another app is active
is not implemented. Camera gestures apply only to the visible card activity.
Android versions with newer background-activity restrictions are not claimed
as equivalent to the API 19 target.

## Phone actions and heartbeat

The Phone panel appears only after an authenticated iOS peer advertises
`phone.actions`. Its fixed requests are `focus.on`, `focus.off`, `silent.on`,
`silent.off`, `notes.create` and `notes.browse`. These are encrypted
`phone.action` messages with an `action` field. The iPhone owns confirmation
and execution; Glass does not silently change Focus or ringer state.
The sender selects one authenticated capable transport, preferring TCP. A
failed write is never retried on BLE because it may already have arrived.
Arbitrary action strings are rejected. Capability state clears on disconnect.

An ANCS action labelled Reply is displayed as **Open reply on iPhone**. Its
existing phone action is preserved; there is no Glass dictation or text-send
implementation. Full spoken replies remain unavailable without a supported
provider/HFP path and a known target conversation.

Both receiving transports answer authenticated `ping` with encrypted `pong`
on the same session, preserving the optional `id`. Heartbeats never become
cards or actions. A second TCP connection is rejected while a current client
exists, so an unauthenticated newcomer cannot evict an authenticated session.

Validation includes pure boot/opt-out/retry/presentation/suppression tests,
ANCS new-versus-modified flags, fixed phone-action schema tests, and a real
loopback JVM socket test for authentication, capabilities, phone-action gates,
matching-ID heartbeat replies, concurrent-client rejection and reauthentication.
No boot delivery, Glass display wake, HOME navigation, camera/touchpad input,
radio operation or firmware installation has been verified on physical Glass.

## Stock headset voice setup

After first pairing or a bridge restart, reconnect the headset in system Bluetooth
settings so the bridge observes a fresh, permission-filtered stock HFP connection.
An existing sticky connection alone is insufficient. The adapter requires the exact
audited stock Bluetooth APK, a bonded peer, no observed call, and no pre-existing
SCO route. It refuses other system versions or a different stock APK. It sends no
voice command at boot and never changes audio routing itself.

The stock HFP/SCO service owns phone playback and microphone audio. Requests end
on cancellation, a completed observed route, activity departure, or 30 seconds.
Calls withdraw request ownership without a stop command. Hardware validation of
Siri, microphone/playback, call races, headset reconnect, and physical Camera keys
remains required; no working-headset claim follows from the host build.
