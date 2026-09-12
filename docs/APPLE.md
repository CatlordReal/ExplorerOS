# Apple apps

## Components

- `apple/iOS`: SwiftUI iOS 17+ companion. Wi-Fi, iPhone BLE peripheral, Keychain pairing, App Intents, MapKit route steps, optional on-device app dictation, and opt-in Glass media staging.
- `apple/macOS`: macOS 14+ utility for explicit ADB APK installation and reviewable fastboot image plans.
- `apple/Sources/ExplorerLinkCore`: authenticated wire protocol, local endpoint policy, route/input state, and solar theme scheduling.
- `apple/Sources/ExplorerFlashCore`: path/hash validation, device selection, argument-only command planning, bounded APK subprocess execution, and disabled raw-partition execution.

Both apps provide the ten requested themes and Light/Dark/System chrome. Apple theme scheduling can use local coordinates or explicit fallback times. Location coordinates entered for themes stay local. Keychain supports one selected Glass pairing at a time.

## Build

Open `apple/ExplorerLink.xcodeproj` in Xcode and select `ExplorerLink` (iPhone) or `ExplorerTools` (Mac). Choose your own development team for physical-device installation. The project is checked in; XcodeGen is only needed after changing `apple/project.yml`.

```sh
cd apple
swift test
xcodebuild -project ExplorerLink.xcodeproj -scheme ExplorerLink \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
xcodebuild -project ExplorerLink.xcodeproj -scheme ExplorerTools \
  -destination 'platform=macOS' -derivedDataPath build/MacDerivedData \
  CODE_SIGN_IDENTITY=- build
```

Use the installed full Xcode as `DEVELOPER_DIR` if the system default is Command Line Tools. Keep simulator signing enabled: Keychain pairing requires the simulated application identity. Turning off signing made pairing fail during development. The app has no insecure storage fallback.

For sandboxed SwiftPM runs, `scripts/test.sh` routes module caches into the checkout. Development builds are not App Store submissions or notarized Mac distributions. Free Apple development profiles have device/app limits and expire; provisioning is controlled by Apple.

## Pair and connect

1. Install the bridge APK through the Mac app on an existing supported Glass system. Follow [GLASS.md](GLASS.md). No ROM flash is needed for this initial test.
2. In iPhone Settings, create a pairing key. On Glass, open pairing and scan the QR code. Do not share the QR or a screenshot containing it.
3. For Wi-Fi, enter Glass's private IP address in the iPhone app and connect. Both devices need local connectivity to TCP port 8765. Internet hostnames and public IPs are rejected. Use `127.0.0.1` only with the iOS Simulator and a Mac-hosted simulator; a physical iPhone needs the Mac/Glass LAN address.
4. For Bluetooth, select Bluetooth on iPhone, start it, then scan and choose that iPhone on Glass. Keep both apps foregrounded for initial discovery. Complete OS pairing/notification authorization when offered. ANCS/AMS bonding is separate from the app's QR pairing.

The connection becomes connected only after decrypting a valid peer frame. Errors close the session. Reconnect starts new challenges/counters. Pairing keys remain in iPhone Keychain and Glass app-private storage; message contents are not logged by default.

## What works through public APIs

- Send text to a Glass card over either implemented transport.
- Shortcuts actions: Connect Glass, Send text to Glass, Next Glass direction, Create quick note, and Show quick notes on Glass. Siri can invoke these app actions. The app opens to establish its connection.
- MapKit calculates route steps from a fresh, user-authorized location and destination. Glass swipes advance/revisit steps. This is manual step sharing, not live Apple Maps navigation mirroring, background tracking, or automatic rerouting. The Apple Maps button opens a separate Maps route.
- The microphone button transcribes this app's input using on-device Speech recognition when available. This is labeled app dictation, not a Siri transcript. It stops when the app leaves the foreground, disconnects, or reaches its time limit.
- Glass consumes ANCS/AMS directly for notifications, available notification actions, metadata, and supported media commands. The companion reports discovery only when the peer advertises it.
- With **Camera sync** enabled on Glass and **Receive media from Glass** enabled in its Gallery, the foreground iPhone app can receive authenticated JPEG, PNG, MP4, or 3GPP captures over Wi-Fi. It stages them in its protected private vault. **Save to Photos** is a separate explicit add-only Photos action.

## Limits

Media transfer needs both explicit opt-ins, authenticated TCP, observed Wi-Fi, and an active iPhone app. It has no background delivery or resume. It retains the original Glass capture, limits one transfer at a time, and deduplicates verified captures. Staging and host tests do not prove camera discovery, Android media-library access, Wi-Fi delivery, or Photos export on physical hardware. AMS media support is for playback controls and track metadata. "Hey Siri" wake-word detection is not implemented.

Wi-Fi can be suspended by iOS. Initial BLE advertising is foreground-dependent for Android discovery; background iOS advertising has different UUID rules. Automatic process restoration is not implemented; reopen/reconnect after termination. ANCS/AMS service availability, permissions, and actual XE24 Bluetooth support need physical verification.

Neither App Intents nor this companion can capture global Siri transcripts, invoke system Siri on demand from an arbitrary incoming BLE message, or control unrelated Phone.app calls. The installed Glass service has a guarded adapter to the stock HFP Hands-Free/SCO service; actual Siri playback and microphone operation still require hardware testing. See [FEASIBILITY-HFP.md](FEASIBILITY-HFP.md). Notification actions execute only when iOS supplies the corresponding action flag. No private iOS APIs are used.

## Simulator-only integration hook

Debug builds support `--integration-test` plus `EXPLORERLINK_TEST_KEY` in the process environment. The hook performs real Keychain storage and protocol connection to `127.0.0.1`, sends synthetic text, and writes a content-free `Documents/integration-result.json`. It never marks an unconnected peer connected. The public deterministic fixture is test-only and must never provision real Glass.

For captures, `--notes-fixture` creates one synthetic local note, `--phone-preview`
selects the Phone tab, and `--shortcuts-preview` scrolls that tab to its real
Shortcuts section. These hooks are compiled out of Release builds and do not
import or run Shortcuts, grant permissions, or change phone settings.
