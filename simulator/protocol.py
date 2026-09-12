"""Bounded Explorer Link v1 framing and authenticated message helpers."""

from __future__ import annotations

import base64
import binascii
import json
import secrets
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from .media import SCHEMAS as MEDIA_TYPES, MediaTransferError, validate_media

VERSION = 1
AAD = b"ExplorerLink/1"
MAX_LINE_BYTES = 32_768
MAX_SEQUENCE = (1 << 53) - 1
KNOWN_TYPES = frozenset({
    "capabilities", "card", "navigation", "navigation.stop", "input", "ping", "pong", "error", "phone.action", *MEDIA_TYPES
})
ENDPOINTS = frozenset({"glass", "ios", "simulator", "qt"})
GESTURES = frozenset({"tap", "doubleTap", "swipeLeft", "swipeRight", "swipeDown", "camera", "cameraLongPress"})
PHONE_ACTIONS = frozenset({"focus.on", "focus.off", "silent.on", "silent.off", "notes.create", "notes.browse"})


class ProtocolError(ValueError):
    """An invalid peer message; caller must close its transport session."""


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _strict_b64(value: Any, expected_len: int | None = None) -> bytes:
    if not isinstance(value, str):
        raise ProtocolError("base64 value must be a string")
    try:
        decoded = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error) as exc:
        raise ProtocolError("invalid base64") from exc
    if expected_len is not None and len(decoded) != expected_len:
        raise ProtocolError("invalid binary length")
    return decoded


def _hex_32(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdefABCDEF" for c in value):
        raise ProtocolError("challenge must be 64 hexadecimal digits")
    return value


def validate_key_hex(value: str) -> bytes:
    if not isinstance(value, str) or len(value) != 64:
        raise ValueError("pairing key must be exactly 64 hexadecimal digits")
    try:
        key = bytes.fromhex(value)
    except ValueError as exc:
        raise ValueError("pairing key must be hexadecimal") from exc
    if len(key) != 32:
        raise ValueError("pairing key must be 32 bytes")
    return key


def validate_payload(payload: Any) -> dict[str, str]:
    if not isinstance(payload, dict) or len(payload) > 32:
        raise ProtocolError("payload must be a flat dictionary of at most 32 entries")
    clean: dict[str, str] = {}
    for key, value in payload.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ProtocolError("payload entries must be strings")
        if not key or len(key.encode("utf-8")) > 64 or len(value.encode("utf-8")) > 4_096:
            raise ProtocolError("payload entry exceeds byte limit")
        clean[key] = value
    return clean


def validate_message(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"challenge", "seq", "type", "payload"}:
        raise ProtocolError("decrypted message has invalid shape")
    challenge = _hex_32(value["challenge"])
    sequence = value["seq"]
    if isinstance(sequence, bool) or not isinstance(sequence, int) or not 1 <= sequence <= MAX_SEQUENCE:
        raise ProtocolError("sequence is outside protocol range")
    message_type = value["type"]
    if not isinstance(message_type, str) or not message_type or len(message_type.encode("utf-8")) > 64:
        raise ProtocolError("message type is invalid")
    payload = validate_payload(value["payload"])
    _validate_type_payload(message_type, payload)
    return {"challenge": challenge, "seq": sequence, "type": message_type, "payload": payload}


def _validate_type_payload(message_type: str, payload: dict[str, str]) -> None:
    """Validate known message schemas; retain unknown types for an encrypted error reply."""
    if message_type.startswith("media."):
        try:
            validate_media(message_type, payload)
        except MediaTransferError as exc:
            raise ProtocolError(str(exc)) from exc
        return
    if message_type == "capabilities":
        if set(payload) != {"endpoint", "features"} or payload["endpoint"] not in ENDPOINTS:
            raise ProtocolError("invalid capabilities payload")
    elif message_type == "card":
        if set(payload) != {"title", "body", "source"} or payload["source"] not in {"companion", "appIntent", "speech"}:
            raise ProtocolError("invalid card payload")
    elif message_type == "navigation":
        if set(payload) != {"instruction", "distance", "destination", "step", "total", "source"} or payload["source"] not in {"mapkit", "demo"}:
            raise ProtocolError("invalid navigation payload")
    elif message_type == "navigation.stop":
        if payload:
            raise ProtocolError("navigation.stop payload must be empty")
    elif message_type == "input":
        if set(payload) != {"gesture"} or payload["gesture"] not in GESTURES:
            raise ProtocolError("invalid input payload")
    elif message_type == "phone.action":
        if set(payload) != {"action"} or payload["action"] not in PHONE_ACTIONS:
            raise ProtocolError("invalid phone action")
    elif message_type in {"ping", "pong"}:
        if set(payload) - {"id"}:
            raise ProtocolError("invalid ping payload")
    elif message_type == "error":
        if set(payload) != {"code", "message"}:
            raise ProtocolError("invalid error payload")


class LineDecoder:
    """Incremental strict UTF-8 NDJSON decoder with a protocol-sized buffer."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, chunk: bytes) -> list[dict[str, Any]]:
        self._buffer.extend(chunk)
        if len(self._buffer) > MAX_LINE_BYTES + 1 and b"\n" not in self._buffer:
            raise ProtocolError("line exceeds 32768 bytes")
        values: list[dict[str, Any]] = []
        while True:
            newline = self._buffer.find(b"\n")
            if newline < 0:
                break
            if newline > MAX_LINE_BYTES:
                raise ProtocolError("line exceeds 32768 bytes")
            line = bytes(self._buffer[:newline])
            del self._buffer[: newline + 1]
            if line.endswith(b"\r"):
                raise ProtocolError("CRLF is not valid Explorer Link framing")
            try:
                text = line.decode("utf-8")
                value = json.loads(text)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ProtocolError("invalid UTF-8 JSON line") from exc
            if not isinstance(value, dict):
                raise ProtocolError("line must contain a JSON object")
            values.append(value)
        if len(self._buffer) > MAX_LINE_BYTES:
            raise ProtocolError("line exceeds 32768 bytes")
        return values


@dataclass
class Session:
    """Per-connection protocol state. Transport owns closure on ProtocolError."""

    key: bytes
    hello: str
    peer_hello: str | None = None
    incoming_sequence: int = 0
    outgoing_sequence: int = 0
    authenticated: bool = False
    failed: bool = False

    @classmethod
    def create(cls, key: bytes) -> "Session":
        if len(key) != 32:
            raise ValueError("AES-256-GCM requires a 32-byte pairing key")
        return cls(key=key, hello=secrets.token_hex(32))

    def hello_line(self) -> bytes:
        return _json_bytes({"v": VERSION, "hello": self.hello}) + b"\n"

    def receive(self, frame: dict[str, Any]) -> dict[str, Any] | None:
        if self.failed:
            raise ProtocolError("session failed; reconnect required")
        try:
            return self._receive(frame)
        except (ValueError, UnicodeError, TypeError) as exc:
            self.failed = True
            self.authenticated = False
            raise ProtocolError(str(exc)) from exc

    def _receive(self, frame: dict[str, Any]) -> dict[str, Any] | None:
        if self.peer_hello is None:
            if set(frame) != {"v", "hello"} or type(frame.get("v")) is not int or frame.get("v") != VERSION:
                raise ProtocolError("expected one v1 hello")
            self.peer_hello = _hex_32(frame["hello"])
            return None
        if set(frame) != {"v", "nonce", "box"} or type(frame.get("v")) is not int or frame.get("v") != VERSION:
            raise ProtocolError("expected encrypted v1 frame")
        nonce = _strict_b64(frame["nonce"], 12)
        box = _strict_b64(frame["box"])
        if len(box) < 17:
            raise ProtocolError("encrypted frame lacks authentication tag")
        try:
            plaintext = AESGCM(self.key).decrypt(nonce, box, AAD)
            decoded = json.loads(plaintext.decode("utf-8"))
        except Exception as exc:
            raise ProtocolError("AES-GCM authentication failed") from exc
        message = validate_message(decoded)
        if message["challenge"] != self.hello:
            raise ProtocolError("challenge mismatch")
        if message["seq"] <= self.incoming_sequence:
            raise ProtocolError("replayed or out-of-order sequence")
        self.incoming_sequence = message["seq"]
        self.authenticated = True
        return message

    def encrypt(self, message_type: str, payload: dict[str, str]) -> bytes:
        if self.failed or self.peer_hello is None:
            raise ProtocolError("cannot encrypt before peer hello")
        sequence = self.outgoing_sequence + 1
        message = validate_message({
            "challenge": self.peer_hello,
            "seq": sequence,
            "type": message_type,
            "payload": payload,
        })
        plaintext = _json_bytes(message)
        nonce = secrets.token_bytes(12)
        box = AESGCM(self.key).encrypt(nonce, plaintext, AAD)
        frame = _json_bytes({
            "v": VERSION,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "box": base64.b64encode(box).decode("ascii"),
        })
        if len(frame) > MAX_LINE_BYTES:
            raise ProtocolError("line exceeds 32768 bytes")
        self.outgoing_sequence = sequence
        return frame + b"\n"
