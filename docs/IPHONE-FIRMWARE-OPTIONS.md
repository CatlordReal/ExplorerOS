# iPhone firmware-install options

## Answer

It is not supportable to say that every imaginable iPhone-to-Glass installation
route is impossible. It is supportable to say that **this stock iPhone app has no
public, direct USB ADB or Fastboot route**, and current Apple public APIs do not
provide a general-purpose USB bulk/serial interface for an iPhone app. No direct
USB installer should be promised or added from this evidence.

The existing recovery workflow remains preparation only. Its raw-partition
executor is disabled, and CWM restore remains a manual on-device action. This
document does not change those safety boundaries.

## Direct USB on an iPhone

### USBDriverKit

Apple states that [USBDriverKit](https://developer.apple.com/documentation/usbdriverkit)
is available on macOS and on **M-series iPadOS** devices. Its
[DriverKit platform documentation](https://developer.apple.com/documentation/driverkit)
likewise names macOS and M-series iPadOS, not iPhone. The current iPhoneOS SDK
contains no `DriverKit.framework` or `USBDriverKit.framework`; it contains neither
a public iPhone driver-extension target nor an app API for claiming arbitrary USB
interfaces/endpoints. Entitlements do not turn an iPhone into an M-series iPad
DriverKit host.

An M-series iPad is a separate research path: Apple documents
[USBDriverKit on iPadOS](https://developer.apple.com/documentation/driverkit/creating-drivers-for-ipados),
requires M-series hardware, a DriverKit extension, and Apple-granted
entitlements. That could only be assessed after identifying the Glass USB
vendor/product/interface descriptors and writing a purpose-built driver. It is
not an iPhone solution and does not validate Fastboot flashing.

### ExternalAccessory and AccessorySetupKit

[ExternalAccessory](https://developer.apple.com/documentation/externalaccessory)
opens an `EASession` only for an MFi accessory and its declared protocol string.
[Apple’s Developer Program agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
requires the MFi licensee to authorize the app for an MFi accessory connected
through the relevant Apple connector. There
is no evidence that Explorer Edition Glass in ADB or Fastboot mode is an MFi
accessory exposing an ExternalAccessory protocol. A reverse-DNS string in an app
does not create that protocol.

[AccessorySetupKit](https://developer.apple.com/documentation/accessorysetupkit)
sets up Bluetooth or Wi-Fi accessories; after selection Apple directs the app to
use Core Bluetooth or Network framework. It neither grants USB interface access
nor transports ADB/Fastboot.

### ImageCaptureCore/PTP is a real but narrow exception

ImageCaptureCore is present in iOS. Apple documents discovery of connected
cameras, media reads, and PTP commands through
[`ICCameraDevice`](https://developer.apple.com/documentation/imagecapturecore/iccameradevice)
and says a PTP command is permitted only when the camera advertises
[`cameraDeviceCanAcceptPTPCommands`](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand%28_%3Aoutdata%3Asendcommanddelegate%3Adidsendcommand%3Acontextinfo%3A%29).
It also requires a camera-access explanation for iOS tethering.

This is **not** generic USB access. It is worth a future *read-only physical
eligibility probe* only if Glass presents as an `ICCameraDevice` under its active
USB configuration, the user grants the appropriate camera/contents control access, and
the device reports the PTP capability. ADB and Fastboot are different USB
protocols; no evidence shows XE24 Fastboot accepts PTP commands, exposes a PTP
vendor command for flashing, or is reachable through ImageCaptureCore. Do not
send a vendor PTP command or attempt a write based on this possibility.

There is relevant static evidence, but it stops short of that eligibility result.
The pinned `boot.img` ramdisk’s `default.prop` sets
`persist.sys.usb.config=adb`; its `init.omap4430.usb.rc` defines
`sys.usb.config=ptp` and `ptp,adb` rules, each configuring Google vendor ID
`18d1` and product ID `9001`. The same file comments that PTP and PTP+ADB need a
new PID. This proves the inspected boot image contains PTP configuration rules;
it does not prove that a running XE24 unit enumerates as an iOS-visible camera,
that iOS authorizes control, or that PTP can write firmware.

### Files, document providers, and WebKit

iPhone can mount supported external storage in Files, but Apple describes this
as file access to a formatted drive, not USB-interface control:
[external storage on iPhone](https://support.apple.com/en-ie/guide/iphone/-iph95baac91f/ios).
A document picker gives a security-scoped URL to user-selected file-provider
content, again not ADB/Fastboot endpoints. See
[Apple’s document-picker guidance](https://developer.apple.com/documentation/uikit/providing-access-to-directories).
These APIs can select a firmware archive; they cannot deliver it to a Glass
bootloader.

The current public `WKWebView` API is for web content and has no documented
WebUSB or raw USB-device API. Adding a web view cannot bypass the native USB
boundary. A private API, jailbreak, or unsanctioned entitlement would be outside
stock iOS and cannot support an App Store or ordinary signed-device claim.

## Network alternatives

An iPhone app may use public TCP networking. Apple’s
[Network framework](https://developer.apple.com/documentation/network) exposes
bidirectional connections, and Android documents ADB-over-TCP after an initial
USB setup for Android 10 and lower, including the `adb tcpip 5555` step:
[Android Debug Bridge](https://developer.android.com/tools/adb).

For XE24/API 19, that means a previously authorized USB-capable host must first
enable the device TCP listener. A future Swift ADB-over-TCP implementation would
also need to implement ADB protocol itself; iOS cannot execute the host `adb`
binary. This could conceivably support Android-side inspection, APK operations,
or staging for an already supported recovery/network-bootstrap workflow after
device-specific testing. A custom installed recovery or network bootstrap is
conceivable but unproven. TCP ADB still does not supply a Fastboot-over-TCP
protocol, establish that XE24 enables ADB TCP, or validate any firmware restore.

The practical public design is a **Mac or dedicated Linux USB-host bridge**. The
iPhone controls a local authenticated review service over TCP; that host owns the
USB cable and its ADB/Fastboot/recovery tools. Any future bridge must retain the
current fail-closed checks and stay within the user’s explicit authorization. The
iPhone may request, display, or cancel a reviewed operation, but must never claim
that it performed a direct USB flash.

## Evidence that is worth obtaining safely

1. Simulator-only: exercise an authenticated iPhone-to-Mac mock service with
   inventory and an explicit `not available` result. It proves UI and network
   framing only; it must not launch `adb`, Fastboot, or a firmware writer.
2. Physical read-only, only with explicit hardware authorization: observe whether
   normal-mode Glass appears to ImageCaptureCore as a camera, record advertised
   capability strings and IDs, then disconnect. This would establish PTP
   eligibility, not an ADB/Fastboot route.
3. Separate host test: on a sacrificial, recoverable unit, verify ADB TCP only
   after an authorized Mac USB setup and use non-mutating device queries. Do not
   infer Fastboot support from ADB TCP success.

No listed path proves a safe ExplorerOS installation on a physical unit. Exact
current firmware, recovery compatibility, storage/partition behavior, power,
USB stability, and successful restoration remain physical gates.
