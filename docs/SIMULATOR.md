# Explorer Link simulator

`simulator` is a local, simulated Glass endpoint for the frozen Explorer Link v1 contract. It listens on `127.0.0.1:8765` by default. It is not Glass firmware and does not imply hardware, Bluetooth, ANCS, AMS, HFP, camera, or APK success.

## Install and start

```sh
python3 -m venv .venv
.venv/bin/pip install -r simulator/requirements.txt
.venv/bin/python -m simulator.server
```

Without a supplied key, startup prints one `PAIRING_KEY=<64 hex>` onboarding line. Copy that key only through an explicit local trust action; it is not persisted or logged by the simulator. For repeatable local development, use a protected file:

```sh
chmod 600 /path/to/explorerlink.key
.venv/bin/python -m simulator.server --key-file /path/to/explorerlink.key
```

`--key` accepts the same 64-hex value but can expose it through shell history or process inspection, so `--key-file` is preferred. Do not add production keys, `pairing.json`, or key files to source control.

## TCP and session behavior

Only one TCP client is accepted at a time. A second connection is closed while an active client exists. Each new connection receives a fresh challenge and must complete the plaintext hello plus authenticated encrypted capabilities exchange within eight seconds before the simulator reports connected. Invalid UTF-8, malformed NDJSON, a line over 32,768 bytes, bad AES-GCM authentication, replay, sequence rollback, duplicate hello, or encrypted data before hello closes that session. A reconnect always starts from new challenges and sequence counters.

Messages are bounded NDJSON as specified in [`protocol/PROTOCOL.md`](../protocol/PROTOCOL.md). There is no content logging or persistence. The event output only reports presence of cards/navigation by default.

## stdin controls and event API

The simulator reads one command per stdin line:

```text
state
tap | doubleTap | swipeLeft | swipeRight | swipeDown | camera | cameraLongPress
card <title>|<body>|<companion|appIntent|speech>
navigation <instruction>|<distance>|<destination>|<step>|<total>|<mapkit|demo>
stop
quit
```

Gestures send an authenticated `input` message if a peer hello exists. `card` and `navigation` set synthetic local display state; they never claim Glass hardware behavior. `stop` clears navigation.

stdout emits one compact JSON object per event for a local controller such as the Qt viewer. It never emits keys after explicit onboarding. Add `--synthetic-ui` only when a local viewer needs synthetic card/direction text; this intentionally exposes that synthetic text on stdout. Do not use that mode with private notification content.

## Fixture and tests

[`fixtures/protocol-v1.json`](../fixtures/protocol-v1.json) is a public, deterministic **TEST-ONLY** AES-256-GCM vector. Its fixed all-zero-to-`1f` key must never be provisioned to a device. The fixture verifies canonical compact UTF-8 JSON, AAD `ExplorerLink/1`, nonce encoding, and ciphertext-plus-tag layout for Swift/Java implementations.

```sh
.venv/bin/python -m unittest discover -s simulator/tests -v
```

The suite checks fragmentation, coalescing, wrong-key authentication failure, replay detection, invalid payload/session rules, fresh reconnect challenges, and an actual localhost socket exchange.
