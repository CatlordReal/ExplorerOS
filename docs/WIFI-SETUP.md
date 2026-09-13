# Set up Glass Wi-Fi without MyGlass

Explorer Link on iPhone and Explorer Tools on Mac can create a Wi-Fi QR code
offline. Use Glass's existing Wi-Fi scanner; USB, a Google account, the retired
MyGlass website, and a new Glass APK are not needed for this setup path.

1. On iPhone, open **Set up Glass Wi-Fi** from Glass or Settings. On Mac, open
   **Wi-Fi setup**.
2. Enter the network name exactly, choose **WPA / WPA2 Personal** or **Open**,
   enter the password if required, and choose **Show Wi-Fi code**.
3. On Glass, open **Settings > Wi-Fi > Add Wi-Fi network > Use a Wi-Fi access
   QR code**. Scan the displayed code and check the connection on Glass.

Code creation does not confirm that Glass scanned it or joined the network.
The software path is implemented and tested; scanning and joining with the
owner's physical Glass still need verification. No factory reset is required.

## Credentials and compatibility

The apps do not save, upload, log, or copy these credentials to the clipboard.
The QR code contains the network name and, for WPA, its password. Only display
it where trusted devices can see it. Editing hides the code; leaving the screen
or app clears the entered credentials and code from view state. This is not a
claim of secure memory erasure.

- Network names must contain 1–32 UTF-8 bytes, without control characters.
  Leading and trailing spaces are preserved.
- WPA passphrases must contain 8–63 printable ASCII characters. A raw 64-digit
  hexadecimal PSK is not supported by the inspected Glass configuration path.
- WPA3-only, enterprise/EAP, and WEP setup are not offered. A captive portal
  still needs its own sign-in flow; this generator does not supply one.
- No hidden-network toggle is offered. The inspected Glass implementation
  enables active SSID probing for every QR-created network, independently of
  any QR hidden-network field.

## Evidence

Read-only inspection used `system/priv-app/GlassSettings.apk` from the pinned
XE24-based ExplorerOS Public Beta 3 archive. Its SHA-256 is
`85cc5247b1ee32b59fa737b1b19e0787798c292a2f9a4fecf14f4471f8e15113`.
`WifiSelectorActivity.onBarcodeScanned` accepts Wi-Fi QR values and maps WPA,
WEP, and open security to `WifiHelper.connect`. `WifiHelper` quotes WPA keys,
which is why the app does not accept a raw 64-digit PSK.

The encoder emits `WIFI:T:WPA;S:<ssid>;P:<password>;;` or
`WIFI:T:nopass;S:<ssid>;;`, escaping backslash, semicolon, comma, quote, and colon.
It omits `H:`. The field grammar is documented in the primary
[ZXing Wi-Fi parser](https://github.com/zxing/zxing/blob/master/core/src/main/java/com/google/zxing/client/result/WifiResultParser.java).
The on-device scanner and subsequent radio connection have not been exercised.

See [VALIDATION.md](VALIDATION.md) for host and simulator checks.
