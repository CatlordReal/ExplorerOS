# Explorer Link protocol v1

Transport-independent, local-only application messages. Default TCP port: **8765**. Glass and simulator listen; iPhone connects. BLE: iPhone is the peripheral/GATT server, Glass is central/GATT client (API 19 has no public peripheral API). Pair initially with both apps foregrounded.

## BLE service

- Service: `D973F2E0-B19E-11EE-A506-0242AC120002`
- RX (Glass writes to iPhone, write with response): `D973F2E1-B19E-11EE-A506-0242AC120002`
- TX (iPhone notifies Glass): `D973F2E2-B19E-11EE-A506-0242AC120002`
- CCCD: `00002902-0000-1000-8000-00805F9B34FB`

One session per transport connection/subscription. Data is UTF-8 JSON lines, including a final LF. Lines may span any number of reads or GATT values; several lines may share a read. Max line: 32,768 bytes excluding LF. Reject invalid UTF-8, oversized input, malformed objects, unsupported versions, and protocol failures by closing the session. BLE sends at negotiated capacity (20-byte chunks are valid); serialize writes, retain pending notification chunks under backpressure. No unbounded receive/send queues.

## Pairing and authentication

Pairing key: 32 cryptographically random bytes, encoded as exactly 64 hexadecimal digits. Never embed a production key in code, logs, source control, or samples. QR provisioning payload: `{"service":"explorerlink","v":1,"key":"<64 hex>"}`. Key transfer is an explicit local trust action. iPhone stores it in Keychain; Glass stores it in application-private storage. Revocation deletes the key and closes connections. Use a separate random key for each Glass. ANCS/AMS Bluetooth bonding is separate from this application pairing.

At each connection, each endpoint generates a fresh 32-byte random challenge and sends exactly one plaintext line:

```json
{"v":1,"hello":"<64 hex challenge>"}
```

After receiving the peer's hello, encrypted application lines use AES-256-GCM, a fresh random **12-byte nonce for every frame**, a 16-byte authentication tag appended to ciphertext, and constant additional authenticated data `ExplorerLink/1` (ASCII):

```json
{"v":1,"nonce":"<base64 nonce>","box":"<base64 ciphertext followed by tag>"}
```

The decrypted JSON object is:

```json
{"challenge":"<peer hello challenge>","seq":1,"type":"card","payload":{"title":"Hello","body":"From iPhone","source":"companion"}}
```

Receiver verifies the challenge equals its own fresh challenge, and sequence is a positive integer strictly greater than the last accepted sequence (maximum 2^53-1). Only update sequence after authenticated decryption and full message validation. Sequence starts at 1 per direction. Duplicate hello, encrypted data before hello, authentication/replay errors close the session; reconnect requires new challenges. A hello alone never marks a peer authenticated. Send encrypted `capabilities` after hello; mark connected only after decrypting an authenticated frame. Challenges prevent replay across reconnects. Both TLS-free TCP and BLE carry encrypted content; an unauthenticated observer can see frame timing/length. Bluetooth ANCS/AMS use their own encrypted bonded link and are not tunneled through the companion.

## Messages

`payload` is a flat dictionary of strings. Max 32 entries, keys 64 UTF-8 bytes, values 4,096 UTF-8 bytes. Unknown message types receive `error` and never execute device actions. All strings displayed as text, never HTML/commands.

| Type | Payload | Direction |
| --- | --- | --- |
| `capabilities` | `endpoint`: `glass`, `ios`, `simulator`, or `qt`; `features`: comma-separated implemented feature IDs | Both |
| `card` | `title`, `body`, `source`: `companion`, `appIntent`, or `speech` | iPhone to Glass |
| `navigation` | `instruction`, `distance`, `destination`, `step`, `total`; `source`: `mapkit` or `demo` | iPhone to Glass |
| `navigation.stop` | empty | iPhone to Glass |
| `input` | `gesture`: `tap`, `doubleTap`, `swipeLeft`, `swipeRight`, `swipeDown`, `camera`, `cameraLongPress` | Glass to iPhone |
| `phone.action` | `action`: `focus.on`, `focus.off`, `silent.on`, `silent.off`, `notes.create`, or `notes.browse` | Glass to iPhone |
| `ping` / `pong` | `id` (optional) | Both |
| `error` | `code`, `message` | Both |

`swipeRight`/`swipeLeft` advance/revisit companion route steps when routing; `swipeDown` exits the local card. Simulator camera controls send generic input events. Inside the physical bridge's active card surface, Camera is handled locally by the guarded stock HFP voice adapter and is not forwarded to iOS. The ExplorerOS launcher's camera binding is unchanged. ANCS actions and AMS commands execute directly on Glass only when their service/command/action flags were discovered. The separate HFP adapter defaults unavailable until its stock-module and connection checks pass; no wire input invokes system Siri through an iOS app API.

Session buffers, counters, attributes, and capabilities are cleared on disconnect. No notification contents are logged or persisted by default. Wi-Fi background execution on iOS is not guaranteed; reconnection requires an active supported execution context. Unsupported features are shown as unavailable, never simulated as hardware success.

## Optional phone actions

Only send `phone.action` after authentication and when the iPhone advertises
`phone.actions`. The fixed IDs select a user-configured local action; arbitrary
shortcut names, URLs, recipients, and commands never cross this interface.
The iPhone queues a request for explicit foreground review. Requests do not prove
Focus/silent state changed, a shortcut completed, or a message was sent. A regular
card can explain the pending request on Glass. Disconnect clears pending requests.
Use only one authenticated transport per request, preferring TCP if both exist.

ANCS actions are separate: their positive/negative action IDs carry no text reply
payload. A Reply label must not enable an invented dictation/send capability.

## Optional camera capture transfer

This extension uses the existing authenticated envelope and **TCP only**. Glass
advertises `media.send.tcp.v1` only when Camera sync is enabled; iPhone advertises
`media.receive.tcp.v1` only when receiving is enabled over Wi-Fi in the foreground.
Both capabilities are required. BLE notification/media playback support is separate.
No transfer accepts a peer-supplied filename or filesystem path.

All fields below remain strings under the existing 4,096-byte value bound. `id`
is 32 lowercase hexadecimal characters; `sha256` is 64 lowercase hexadecimal
characters. Counts/offsets use canonical unsigned decimal strings. MIME types are
`image/jpeg`, `image/png`, `video/mp4`, and `video/3gpp`.

| Type | Exact payload fields | Direction |
| --- | --- | --- |
| `media.begin` | `id`, `sha256`, `bytes`, `chunks`, `chunk_bytes` = `3072`, `mime`, `captured_ms` | Glass to iPhone |
| `media.accept` | `id` | iPhone to Glass |
| `media.chunk` | `id`, `index`, `data` (strict Base64) | Glass to iPhone |
| `media.ack` | `id`, `next` | iPhone to Glass |
| `media.finish` | `id` | Glass to iPhone |
| `media.complete` | `id`, `sha256`, `bytes`, `state` = `staged` or `deduplicated` | iPhone to Glass |
| `media.cancel` | `id`, `code` | Either |

Cancellation codes are `disabled`, `unsupported`, `quota`, `storage`, `state`,
`integrity`, or `timeout`. Unknown keys, invalid directions and malformed values
cannot change transfer state. An endpoint must not acknowledge a different transfer.

Only one transfer and one unacknowledged chunk may exist per session. Raw chunks
are exactly 3,072 bytes except the final remainder; Base64 is at most 4,096 bytes.
The receiver accepts only the next zero-based index and acknowledges only after a
successful file write. The sender sends `media.finish` after the final chunk ack.
The receiver checks total bytes and streaming SHA-256, synchronizes/closes the file,
and commits private library metadata before reporting `staged`. A previously
verified capture may receive `deduplicated` directly after `media.begin`, with its
matching hash and size; no `media.accept` or chunk is then needed.

Limits: images 50 MiB, videos 250 MiB, 500 MiB per authenticated session, one active
transfer, and a 30-second idle timeout. iPhone additionally reserves space within a
1 GiB/1,000-capture private library and checks available storage before accepting.
Zero-length files are rejected. The sender verifies stable source metadata and
streamed content; a file still being recorded is deferred. Camera discovery uses
bounded scans and never deletes or edits source captures.

Disabling sync, leaving the foreground, disconnecting, or an integrity failure
closes the transfer and removes only the receiver's unfinished private staging file.
There is no partial resume in this version; a later connection starts afresh and
completed hashes deduplicate. Glass records delivery only after a matching
`media.complete`, scoped to the current pairing. Original Glass captures remain.
Saving a received file into iPhone Photos is a separate explicit action, requesting
add-only Photos permission on use; reception itself needs no Photos-library access.
