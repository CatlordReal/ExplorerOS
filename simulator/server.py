"""TCP simulator and stdin control surface for a simulated Explorer Glass."""

from __future__ import annotations

import argparse
import json
import queue
import selectors
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

from .protocol import KNOWN_TYPES, PHONE_ACTIONS, LineDecoder, ProtocolError, Session, validate_key_hex
from .media import FixtureMediaSender, MediaTransferError

CONTROL_GESTURES = frozenset({"tap", "doubleTap", "swipeLeft", "swipeRight", "swipeDown", "camera", "cameraLongPress"})


class SimulatorServer:
    """One-client local TCP server. Its events are a small JSON stdout API for Qt."""

    def __init__(self, key: bytes, host: str = "127.0.0.1", port: int = 8765, synthetic_ui: bool = False,
                 event_sink: Callable[[dict[str, Any]], None] | None = None, handshake_timeout: float = 8.0,
                 media_fixtures: list[Path] | None = None) -> None:
        if handshake_timeout <= 0:
            raise ValueError("handshake timeout must be positive")
        self.key, self.host, self.port, self.synthetic_ui = key, host, port, synthetic_ui
        self.handshake_timeout = handshake_timeout
        self._media = FixtureMediaSender(media_fixtures or [])
        self._event_sink = event_sink or (lambda event: print(json.dumps(event, separators=(",", ":")), flush=True))
        self._selector = selectors.DefaultSelector()
        self._listener: socket.socket | None = None
        self._client: socket.socket | None = None
        self._decoder: LineDecoder | None = None
        self._session: Session | None = None
        self._handshake_deadline: float | None = None
        self._peer_phone_actions = False
        self._outgoing = bytearray()
        self._thread: threading.Thread | None = None
        self._stopped = threading.Event()
        self._controls: queue.Queue[tuple[str, threading.Event | None]] = queue.Queue(maxsize=64)
        self._state: dict[str, Any] = {"card": None, "navigation": None, "connected": False}

    @property
    def bound_port(self) -> int:
        if self._listener is None:
            raise RuntimeError("server is not running")
        return int(self._listener.getsockname()[1])

    def start(self) -> None:
        if self._thread is not None:
            return
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind((self.host, self.port))
        self._listener.listen(1)
        self._listener.setblocking(False)
        self._selector.register(self._listener, selectors.EVENT_READ, "listener")
        self._thread = threading.Thread(target=self._run, name="explorer-link-simulator", daemon=True)
        self._thread.start()
        self._emit("status", listening=True, host=self.host, port=self.bound_port, connected=False)

    def stop(self) -> None:
        self._stopped.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._close_client("stopped", emit=False)
        if self._listener is not None:
            try:
                self._selector.unregister(self._listener)
            except Exception:
                pass
            self._listener.close()
            self._listener = None
        self._selector.close()

    def handle_control(self, line: str) -> None:
        if self._stopped.is_set():
            return
        complete = threading.Event()
        try:
            self._controls.put_nowait((line.strip(), complete))
        except queue.Full:
            self._emit("error", code="control_queue_full")
            return
        complete.wait(timeout=1)

    def _run(self) -> None:
        while not self._stopped.is_set():
            self._drain_controls()
            for kind, payload in self._media.tick():
                self._send_message(kind, payload)
            if self._session is not None and not self._session.authenticated and self._handshake_deadline is not None and time.monotonic() >= self._handshake_deadline:
                self._close_client("handshake_timeout")
            for key, mask in self._selector.select(timeout=0.1):
                if key.data == "listener":
                    try:
                        client, _address = self._listener.accept()  # type: ignore[union-attr]
                    except BlockingIOError:
                        continue
                    client.setblocking(False)
                    if self._client is not None:
                        client.close()  # Explicit single-client policy.
                    else:
                        self._client, self._decoder, self._session = client, LineDecoder(), Session.create(self.key)
                        self._handshake_deadline = time.monotonic() + self.handshake_timeout
                        self._selector.register(client, selectors.EVENT_READ, "client")
                        try:
                            self._send_raw(self._session.hello_line())
                            self._emit("status", listening=True, host=self.host, port=self.bound_port, connected=False)
                        except (OSError, ProtocolError):
                            self._close_client("send_failed")
                else:
                    if key.fileobj is not self._client:
                        continue
                    if mask & selectors.EVENT_READ:
                        self._read_client()
                    if self._client is not None and mask & selectors.EVENT_WRITE:
                        try:
                            self._flush_outgoing()
                        except OSError:
                            self._close_client("send_failed")

    def _read_client(self) -> None:
        if self._client is None or self._decoder is None or self._session is None:
            return
        try:
            data = self._client.recv(4096)
            if not data:
                self._close_client("peer_closed")
                return
            for frame in self._decoder.feed(data):
                if self._session is None:
                    break
                message = self._session.receive(frame)
                if message is None:
                    features = "cards,navigation,input" + (",media.send.tcp.v1" if self._media.paths else "")
                    self._send_message("capabilities", {"endpoint": "simulator", "features": features})
                else:
                    self._receive_message(message)
        except BlockingIOError:
            pass
        except (OSError, ProtocolError, MediaTransferError):
            self._close_client("protocol_closed")

    def _receive_message(self, message: dict[str, Any]) -> None:
        if self._session is None:
            return
        if not self._state["connected"]:
            self._state["connected"] = True
            self._emit("status", listening=True, host=self.host, port=self.bound_port, connected=True)
        kind, payload = message["type"], message["payload"]
        if kind not in KNOWN_TYPES:
            self._send_message("error", {"code": "unsupported_type", "message": "Unsupported message type"})
            return
        if kind == "card":
            self._state["card"] = payload
            self._emit_view("card", payload)
        elif kind == "navigation":
            self._state["navigation"] = payload
            self._emit_view("navigation", payload)
        elif kind == "navigation.stop":
            self._state["navigation"] = None
            self._emit("navigation", active=False)
        elif kind == "ping":
            self._send_message("pong", {"id": payload.get("id", "")})
        elif kind == "capabilities":
            self._peer_phone_actions = payload.get("endpoint") == "ios" and "phone.actions" in {feature.strip() for feature in payload.get("features", "").split(",")}
            self._emit("capabilities", peer=payload.get("endpoint", "unknown"), features=payload.get("features", ""))
            enabled = payload.get("endpoint") == "ios" and "media.receive.tcp.v1" in payload.get("features", "").split(",")
            for response, fields in self._media.set_available(enabled):
                self._send_message(response, fields)
        elif kind.startswith("media."):
            for response, fields in self._media.receive(kind, payload):
                self._send_message(response, fields)
            if kind == "media.complete":
                self._emit("media", completed=True, state=payload["state"], bytes=payload["bytes"])

    def _drain_controls(self) -> None:
        for _ in range(64):
            try:
                line, complete = self._controls.get_nowait()
            except queue.Empty:
                return
            try:
                if line:
                    self._apply_control(line)
            finally:
                if complete is not None:
                    complete.set()

    def _apply_control(self, line: str) -> None:
        command, _, remainder = line.partition(" ")
        if command == "quit":
            self._stopped.set()
            return
        if command == "state":
            self._emit_view("state", self._state)
            return
        if command == "action":
            if remainder not in PHONE_ACTIONS:
                self._emit("error", code="invalid_phone_action")
            elif self._session is None or not self._session.authenticated:
                self._emit("error", code="not_connected")
            elif not self._peer_phone_actions:
                self._emit("error", code="phone_actions_unavailable")
            else:
                self._send_message("phone.action", {"action": remainder})
            return
        if command in CONTROL_GESTURES:
            self._send_message("input", {"gesture": command})
            self._emit("input", gesture=command)
            return
        if command == "card":
            fields = remainder.split("|")
            if len(fields) == 3:
                payload = dict(zip(("title", "body", "source"), fields))
                self._state["card"] = payload
                self._emit_view("card", payload)
                return
        if command == "navigation":
            fields = remainder.split("|")
            if len(fields) == 6:
                payload = dict(zip(("instruction", "distance", "destination", "step", "total", "source"), fields))
                self._state["navigation"] = payload
                self._emit_view("navigation", payload)
                return
        if command == "stop":
            self._state["navigation"] = None
            self._emit("navigation", active=False)
            return
        self._emit("error", code="invalid_control")

    def _send_message(self, message_type: str, payload: dict[str, str]) -> None:
        if self._session is not None and self._session.peer_hello is not None:
            try:
                self._send_raw(self._session.encrypt(message_type, payload))
            except (OSError, ProtocolError):
                self._close_client("send_failed")

    def _send_raw(self, data: bytes) -> None:
        if self._client is not None:
            if len(self._outgoing) + len(data) > 262_144:
                raise ProtocolError("send queue limit exceeded")
            self._outgoing.extend(data)
            self._flush_outgoing()

    def _flush_outgoing(self) -> None:
        if self._client is None:
            return
        if self._outgoing:
            try:
                count = self._client.send(self._outgoing)
                if count == 0:
                    raise ConnectionError("peer closed during send")
                del self._outgoing[:count]
            except BlockingIOError:
                pass
        events = selectors.EVENT_READ | (selectors.EVENT_WRITE if self._outgoing else 0)
        self._selector.modify(self._client, events, "client")

    def _close_client(self, reason: str, emit: bool = True) -> None:
        if self._client is not None:
            try:
                self._selector.unregister(self._client)
            except Exception:
                pass
            try:
                self._client.close()
            except OSError:
                pass
        self._client = self._decoder = self._session = None
        self._handshake_deadline = None
        self._peer_phone_actions = False
        self._media.reset()
        self._outgoing.clear()
        self._state["connected"] = False
        self._state["card"] = self._state["navigation"] = None
        if emit and self._listener is not None:
            self._emit("card", active=False)
            self._emit("navigation", active=False)
            self._emit("status", listening=True, host=self.host, port=self.bound_port, connected=False, reason=reason)

    def _emit_view(self, event: str, payload: dict[str, Any]) -> None:
        if self.synthetic_ui:
            self._emit(event, **payload)
        else:
            self._emit(event, present=bool(payload))

    def _emit(self, event: str, **fields: Any) -> None:
        self._event_sink({"event": event, **fields})


def _load_key(args: argparse.Namespace) -> tuple[bytes, str | None]:
    sources = [value is not None for value in (args.key, args.key_file)]
    if sum(sources) > 1:
        raise ValueError("use only one of --key or --key-file")
    if args.key_file:
        value = Path(args.key_file).read_text(encoding="utf-8").strip()
        return validate_key_hex(value), None
    if args.key:
        return validate_key_hex(args.key), None
    key = __import__("secrets").token_bytes(32)
    return key, key.hex()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Explorer Link simulated Glass endpoint")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--key", help="64 hexadecimal pairing key; avoid shell history")
    parser.add_argument("--key-file", help="file containing exactly one 64 hexadecimal pairing key")
    parser.add_argument("--synthetic-ui", action="store_true", help="emit synthetic card/navigation content to stdout")
    parser.add_argument("--media-fixture", action="append", type=Path, default=[], help="explicit synthetic JPEG/PNG/MP4/3GP test file to transfer; repeat up to 16 times")
    args = parser.parse_args(argv)
    try:
        key, generated = _load_key(args)
        server = SimulatorServer(key, args.host, args.port, args.synthetic_ui, media_fixtures=args.media_fixture)
        if generated:
            print(f"PAIRING_KEY={generated}", flush=True)
        server.start()
        for line in sys.stdin:
            server.handle_control(line)
            if line.strip() == "quit":
                break
        server.stop()
        return 0
    except (OSError, ValueError) as exc:
        print(f"simulator error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
