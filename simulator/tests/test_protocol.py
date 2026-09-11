from __future__ import annotations

import base64
import json
import socket
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from simulator.protocol import AAD, MAX_SEQUENCE, LineDecoder, ProtocolError, Session, validate_key_hex
from simulator.server import SimulatorServer

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "fixtures" / "protocol-v1.json").read_text())


def wire_frame(key: bytes, challenge: str, sequence: int, message_type: str, payload: dict[str, str], nonce: bytes) -> bytes:
    plaintext = json.dumps({"challenge": challenge, "seq": sequence, "type": message_type, "payload": payload}, separators=(",", ":")).encode()
    box = AESGCM(key).encrypt(nonce, plaintext, AAD)
    return (json.dumps({"v": 1, "nonce": base64.b64encode(nonce).decode(), "box": base64.b64encode(box).decode()}, separators=(",", ":")) + "\n").encode()


class ProtocolTests(unittest.TestCase):
    def test_fixture_decrypts_and_reencrypts(self) -> None:
        key = validate_key_hex(FIXTURE["key_hex"])
        packet = FIXTURE["encrypted_packet"]
        plaintext = AESGCM(key).decrypt(base64.b64decode(packet["nonce"]), base64.b64decode(packet["box"]), FIXTURE["aad_utf8"].encode())
        self.assertEqual(json.loads(plaintext), FIXTURE["plaintext"])
        self.assertEqual(base64.b64encode(AESGCM(key).encrypt(base64.b64decode(packet["nonce"]), plaintext, AAD)).decode(), packet["box"])

    def test_fragmented_and_coalesced_lines(self) -> None:
        decoder = LineDecoder()
        first = b'{"v":1,"hello":"' + b"0" * 64 + b'"}\n'
        second = b'{"v":1,"hello":"' + b"1" * 64 + b'"}\n'
        self.assertEqual(decoder.feed(first[:19]), [])
        self.assertEqual(decoder.feed(first[19:] + second), [{"v": 1, "hello": "0" * 64}, {"v": 1, "hello": "1" * 64}])

    def test_wrong_key_and_replay_fail(self) -> None:
        key, wrong = bytes(range(32)), bytes(reversed(range(32)))
        server = Session.create(key)
        server.receive({"v": 1, "hello": "a" * 64})
        capabilities = {"endpoint": "ios", "features": "cards"}
        frame = json.loads(wire_frame(wrong, server.hello, 1, "capabilities", capabilities, bytes(12)))
        with self.assertRaises(ProtocolError):
            server.receive(frame)
        valid = json.loads(wire_frame(key, server.hello, 1, "capabilities", capabilities, bytes(12)))
        with self.assertRaises(ProtocolError):
            server.receive(valid)
        with self.assertRaises(ProtocolError):
            server.encrypt("ping", {})
        server = Session.create(key)
        server.receive({"v": 1, "hello": "a" * 64})
        valid = json.loads(wire_frame(key, server.hello, 1, "capabilities", capabilities, bytes(12)))
        server.receive(valid)
        with self.assertRaises(ProtocolError):
            server.receive(valid)
        self.assertFalse(server.authenticated)

    def test_invalid_payload_is_rejected_before_sequence_changes(self) -> None:
        key = bytes(range(32))
        session = Session.create(key)
        session.receive({"v": 1, "hello": "b" * 64})
        frame = json.loads(wire_frame(key, session.hello, 1, "card", {"title": 9}, bytes(12)))
        with self.assertRaises(ProtocolError):
            session.receive(frame)
        self.assertEqual(session.incoming_sequence, 0)

    def test_invalid_known_message_schema_is_rejected(self) -> None:
        key = bytes(range(32))
        session = Session.create(key)
        session.receive({"v": 1, "hello": "b" * 64})
        frame = json.loads(wire_frame(key, session.hello, 1, "input", {"gesture": "launchSiri"}, bytes(12)))
        with self.assertRaises(ProtocolError):
            session.receive(frame)
        self.assertEqual(session.incoming_sequence, 0)

    def test_hello_requires_hex_digits_and_integer_version(self) -> None:
        for hello in [" " + "a" * 63, "+" + "a" * 63, "g" * 64]:
            with self.subTest(hello=hello), self.assertRaises(ProtocolError):
                Session.create(bytes(32)).receive({"v": 1, "hello": hello})
        with self.assertRaises(ProtocolError):
            Session.create(bytes(32)).receive({"v": 1.0, "hello": "a" * 64})

    def test_sender_rejects_invalid_or_oversized_message_without_advancing(self) -> None:
        session = Session.create(bytes(32))
        session.receive({"v": 1, "hello": "A" * 64})
        for kind, payload in [("", {}), ("unknown", {"": "value"}), ("input", {"gesture": "launchSiri"}),
                              ("extension", {str(i): "x" * 4096 for i in range(10)})]:
            with self.subTest(kind=kind), self.assertRaises(ProtocolError):
                session.encrypt(kind, payload)
            self.assertEqual(session.outgoing_sequence, 0)
        frame = json.loads(session.encrypt("ping", {}))
        plain = json.loads(AESGCM(bytes(32)).decrypt(base64.b64decode(frame["nonce"]), base64.b64decode(frame["box"]), AAD))
        self.assertEqual(plain["challenge"], "A" * 64)
        session.outgoing_sequence = MAX_SEQUENCE
        with self.assertRaises(ProtocolError):
            session.encrypt("ping", {})
        self.assertEqual(session.outgoing_sequence, MAX_SEQUENCE)

    def test_partial_send_and_backpressure_preserve_bytes_in_bounded_queue(self) -> None:
        server = SimulatorServer(bytes(32), event_sink=lambda _event: None)
        server._selector.close()
        server._selector = Mock()
        server._client = Mock()
        server._client.send.side_effect = [2, BlockingIOError(), 4]
        server._send_raw(b"abcdef")
        self.assertEqual(server._outgoing, b"cdef")
        server._flush_outgoing()
        self.assertEqual(server._outgoing, b"cdef")
        server._flush_outgoing()
        self.assertEqual(server._outgoing, b"")
        with self.assertRaises(ProtocolError):
            server._send_raw(b"x" * 262_145)
        self.assertEqual(server._outgoing, b"")
        server.stop()


class SocketExchangeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events: list[dict[str, object]] = []
        self.server = SimulatorServer(bytes(range(32)), port=0, event_sink=self.events.append)
        self.server.start()
        self.sock = socket.create_connection(("127.0.0.1", self.server.bound_port), timeout=2)
        self.sock.settimeout(2)

    def tearDown(self) -> None:
        self.sock.close()
        self.server.stop()

    def _line(self) -> dict[str, object]:
        data = bytearray()
        while b"\n" not in data:
            data.extend(self.sock.recv(4096))
        return json.loads(bytes(data).split(b"\n", 1)[0])

    def _handshake(self) -> tuple[str, str]:
        hello = self._line()
        self.assertIn("hello", hello)
        peer_hello = "c" * 64
        self.sock.sendall((json.dumps({"v": 1, "hello": peer_hello}) + "\n").encode())
        caps = self._line()
        self.assertEqual(caps["v"], 1)
        return str(hello["hello"]), peer_hello

    def test_actual_socket_exchange_and_input(self) -> None:
        server_hello, _peer_hello = self._handshake()
        self.sock.sendall(wire_frame(bytes(range(32)), server_hello, 1, "capabilities", {"endpoint": "ios", "features": "cards"}, bytes.fromhex("0102030405060708090a0b0c")))
        time.sleep(0.05)
        self.server.handle_control("tap")
        packet = self._line()
        plaintext = AESGCM(bytes(range(32))).decrypt(base64.b64decode(packet["nonce"]), base64.b64decode(packet["box"]), AAD)
        self.assertEqual(json.loads(plaintext)["type"], "input")
        self.assertTrue(any(event.get("event") == "status" and event.get("connected") is True for event in self.events))

    def test_phone_action_requires_authentication_and_fixed_action(self) -> None:
        server_hello, _ = self._handshake()
        self.server.handle_control("action focus.on")
        self.assertTrue(any(event.get("code") == "not_connected" for event in self.events))
        self.sock.sendall(wire_frame(bytes(range(32)), server_hello, 1, "capabilities", {"endpoint": "ios", "features": "phone.actions"}, bytes(12)))
        deadline = time.monotonic() + 2
        while not any(event.get("connected") is True for event in self.events):
            self.assertLess(time.monotonic(), deadline); time.sleep(0.01)
        self.server.handle_control("action silent.on")
        packet = self._line()
        plaintext = AESGCM(bytes(range(32))).decrypt(base64.b64decode(packet["nonce"]), base64.b64decode(packet["box"]), AAD)
        self.assertEqual(json.loads(plaintext)["payload"], {"action": "silent.on"})
        self.server.handle_control("action arbitrary-shortcut-name")
        self.assertTrue(any(event.get("code") == "invalid_phone_action" for event in self.events))

    def test_phone_action_requires_current_ios_capability(self) -> None:
        server_hello, _ = self._handshake()
        capabilities = [("ios", "cards"), ("ios", "phone.actions.fake"),
                        ("simulator", "phone.actions"), ("ios", "cards, phone.actions"),
                        ("ios", "cards")]
        for sequence, (endpoint, features) in enumerate(capabilities, 1):
            self.sock.sendall(wire_frame(bytes(range(32)), server_hello, sequence, "capabilities",
                                         {"endpoint": endpoint, "features": features}, sequence.to_bytes(12, "big")))
            deadline = time.monotonic() + 2
            while sum(event.get("event") == "capabilities" for event in self.events) < sequence:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.events[:] = [event for event in self.events if event.get("event") != "error"]
            self.server.handle_control("action notes.browse")
            if sequence == 4:
                packet = self._line()
                plain = AESGCM(bytes(range(32))).decrypt(base64.b64decode(packet["nonce"]), base64.b64decode(packet["box"]), AAD)
                self.assertEqual(json.loads(plain)["payload"], {"action": "notes.browse"})
            else:
                self.assertTrue(any(event.get("code") == "phone_actions_unavailable" for event in self.events))

    def test_removed_mail_action_rejected(self) -> None:
        server_hello, _ = self._handshake()
        self.server.handle_control("action mail.open")
        self.assertTrue(any(event.get("code") == "invalid_phone_action" for event in self.events))
        self.sock.sendall(wire_frame(bytes(range(32)), server_hello, 1, "phone.action", {"action": "mail.open"}, bytes(12)))
        self.assertEqual(self.sock.recv(1), b"")

    def test_reconnect_requires_fresh_challenge(self) -> None:
        old_hello, _ = self._handshake()
        self.sock.close()
        time.sleep(0.05)
        self.sock = socket.create_connection(("127.0.0.1", self.server.bound_port), timeout=2)
        self.sock.settimeout(2)
        new_hello = str(self._line()["hello"])
        self.assertNotEqual(old_hello, new_hello)
        self.sock.sendall((json.dumps({"v": 1, "hello": "d" * 64}) + "\n").encode())
        self._line()

    def test_second_client_is_rejected_while_session_active(self) -> None:
        self._handshake()
        second = socket.create_connection(("127.0.0.1", self.server.bound_port), timeout=2)
        second.settimeout(2)
        self.assertEqual(second.recv(1), b"")
        second.close()

    def test_hello_timeout_closes_session(self) -> None:
        timed = SimulatorServer(bytes(range(32)), port=0, event_sink=lambda _event: None, handshake_timeout=0.05)
        timed.start()
        client = socket.create_connection(("127.0.0.1", timed.bound_port), timeout=2)
        client.settimeout(2)
        try:
            client.recv(4096)  # Server hello is expected, but peer sends no hello.
            time.sleep(0.15)
            self.assertEqual(client.recv(1), b"")
        finally:
            client.close()
            timed.stop()

    def test_invalid_payload_closes_session(self) -> None:
        server_hello, _ = self._handshake()
        self.sock.sendall(wire_frame(bytes(range(32)), server_hello, 1, "card", {"title": "x" * 4097}, bytes(12)))
        self.assertEqual(self.sock.recv(1), b"")

    def test_disconnect_clears_card_and_route_before_next_client(self) -> None:
        self.server.synthetic_ui = True
        server_hello, _ = self._handshake()
        self.sock.sendall(wire_frame(bytes(range(32)), server_hello, 1, "card",
                                     {"title": "Private", "body": "Ephemeral", "source": "companion"}, bytes(12)))
        deadline = time.monotonic() + 2
        while not any(event.get("event") == "card" and event.get("title") == "Private" for event in self.events):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        self.server.handle_control("navigation Turn left|120 m|Local|1|3|demo")
        self.sock.close()
        deadline = time.monotonic() + 2
        while not any(event.get("reason") == "peer_closed" for event in self.events):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        self.server.handle_control("state")
        state = next(event for event in reversed(self.events) if event.get("event") == "state")
        self.assertEqual(state, {"event": "state", "connected": False, "card": None, "navigation": None})


if __name__ == "__main__":
    unittest.main(verbosity=2)
