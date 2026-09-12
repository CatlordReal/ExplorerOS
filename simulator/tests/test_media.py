from __future__ import annotations
import base64
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import time
import unittest

from simulator.media import CHUNK_BYTES, FixtureMediaSender, MediaTransferError, validate_media
from simulator.protocol import ProtocolError, Session
from simulator.server import SimulatorServer


class MediaFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'synthetic.png'
        self.data = b'\x89PNG\r\n\x1a\n' + bytes(range(256)) * 31
        self.path.write_bytes(self.data)
        self.sender = FixtureMediaSender([self.path])
        self.addCleanup(self.sender.reset)

    def begin(self):
        kind, self.offer = self.sender.set_available(True)[0]
        self.assertEqual(kind, 'media.begin')
        return self.offer['id']

    def test_opt_in_and_single_chunk_backpressure(self):
        self.assertEqual(self.sender.set_available(False), [])
        transfer = self.begin()
        self.assertEqual(self.sender.set_available(True), [])
        packet = self.sender.receive('media.accept', {'id': transfer})[0]
        received = bytearray()
        while packet[0] == 'media.chunk':
            validate_media(*packet)
            received.extend(base64.b64decode(packet[1]['data']))
            self.assertLessEqual(len(packet[1]['data']), 4096)
            index = int(packet[1]['index'])
            packet = self.sender.receive('media.ack', {'id': transfer, 'next': str(index + 1)})[0]
        self.assertEqual(packet, ('media.finish', {'id': transfer}))
        self.assertEqual(received, self.data)
        complete = {'id': transfer, 'sha256': hashlib.sha256(received).hexdigest(), 'bytes': str(len(received)), 'state': 'staged'}
        self.assertEqual(self.sender.receive('media.complete', complete), [])
        self.assertIsNone(self.sender.active)
        self.assertEqual(self.path.read_bytes(), self.data)

    def test_dedup_is_allowed_before_accept_only_for_matching_bytes(self):
        transfer = self.begin()
        complete = {k: self.offer[k] for k in ('id', 'sha256', 'bytes')}
        complete['state'] = 'deduplicated'
        invalid = dict(complete, bytes=str(len(self.data) - 1))
        with self.assertRaises(MediaTransferError):
            self.sender.receive('media.complete', invalid)
        self.assertEqual(self.sender.receive('media.complete', complete), [])
        self.assertEqual(self.sender.total_bytes, len(self.data))

    def test_early_completion_wrong_id_and_out_of_order_ack(self):
        transfer = self.begin()
        complete = {k: self.offer[k] for k in ('id', 'sha256', 'bytes')}
        with self.assertRaises(MediaTransferError):
            self.sender.receive('media.complete', dict(complete, state='staged'))
        with self.assertRaises(MediaTransferError):
            self.sender.receive('media.accept', {'id': '0' * 32})
        self.sender.receive('media.accept', {'id': transfer})
        for next_index in ['0', '2', '01']:
            with self.subTest(next_index=next_index), self.assertRaises(MediaTransferError):
                self.sender.receive('media.ack', {'id': transfer, 'next': next_index})
        self.assertEqual(self.sender.next_index, 1)

    def test_timeout_cancel_disconnect_and_reenable(self):
        transfer = self.begin()
        self.sender.deadline = time.monotonic() - 1
        self.assertEqual(self.sender.tick(), [('media.cancel', {'id': transfer, 'code': 'timeout'})])
        self.assertEqual(self.sender.set_available(True), [])
        self.sender.set_available(False)
        replacement = self.begin()
        self.assertNotEqual(replacement, transfer)
        self.sender.receive('media.accept', {'id': replacement})
        self.sender.reset()
        self.assertIsNone(self.sender.stream)
        self.assertIsNone(self.sender.active)
        self.assertEqual(self.path.read_bytes(), self.data)

    def test_source_change_prevents_finish(self):
        transfer = self.begin()
        self.sender.receive('media.accept', {'id': transfer})
        self.path.write_bytes(self.data[:-1])
        packets = self.sender.receive('media.ack', {'id': transfer, 'next': '1'})
        while packets[0][0] == 'media.chunk':
            packets = self.sender.receive('media.ack', {'id': transfer, 'next': str(self.sender.next_index)})
        self.assertEqual(packets, [('media.cancel', {'id': transfer, 'code': 'integrity'})])
        self.assertEqual(self.sender.cursor, 0)

    def test_path_replaced_by_symlink_is_never_read(self):
        transfer = self.begin()
        other = self.path.parent / 'other.png'
        other.write_bytes(self.data)
        self.path.unlink()
        self.path.symlink_to(other)
        with self.assertRaises((OSError, MediaTransferError)):
            self.sender.receive('media.accept', {'id': transfer})
        self.assertEqual(self.sender.next_index, 0)

    def test_size_format_symlink_and_wire_validation(self):
        self.path.write_bytes(b'not a PNG')
        with self.assertRaises(MediaTransferError):
            self.sender.set_available(True)
        link = self.path.parent / 'link.png'
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            FixtureMediaSender([link])
        session = Session.create(bytes(32))
        session.receive({'v': 1, 'hello': 'a' * 64})
        for payload in [dict(id='a'*32, index='00', data='AA=='),
                        dict(id='a'*32, index='0', data='AB=='),
                        dict(id='a'*32, index='0', data=base64.b64encode(b'a'*(CHUNK_BYTES+1)).decode()),
                        dict(id='a'*32, index='0', data='AA==', path='../capture.png')]:
            with self.subTest(payload=payload.keys()), self.assertRaises(ProtocolError):
                session.encrypt('media.chunk', payload)
        self.assertEqual(session.outgoing_sequence, 0)


class MediaSocketTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'synthetic.png'
        self.data = b'\x89PNG\r\n\x1a\n' + bytes(range(256)) * 40
        self.path.write_bytes(self.data)
        self.events = []
        self.server = SimulatorServer(bytes(range(32)), port=0, media_fixtures=[self.path], event_sink=self.events.append)
        self.server.start()
        self.addCleanup(self.server.stop)
        self.socket = socket.create_connection(('127.0.0.1', self.server.bound_port), timeout=2)
        self.addCleanup(self.socket.close)
        self.reader = self.socket.makefile('rb')
        self.addCleanup(self.reader.close)
        self.session = Session.create(bytes(range(32)))
        self.session.receive(json.loads(self.reader.readline()))
        self.socket.sendall((json.dumps({'v': 1, 'hello': self.session.hello}) + '\n').encode())
        capabilities = self.receive()
        self.assertIn('media.send.tcp.v1', capabilities['payload']['features'])

    def receive(self):
        return self.session.receive(json.loads(self.reader.readline()))

    def send(self, kind, fields):
        self.socket.sendall(self.session.encrypt(kind, fields))

    def offer(self):
        self.send('capabilities', {'endpoint': 'ios', 'features': 'cards'})
        self.send('ping', {'id': 'opt-in-check'})
        self.assertEqual(self.receive()['type'], 'pong')
        self.send('capabilities', {'endpoint': 'ios', 'features': 'cards,media.receive.tcp.v1'})
        offer = self.receive()
        self.assertEqual(offer['type'], 'media.begin')
        return offer['payload']

    def test_encrypted_transfer_requires_opt_in_and_preserves_source(self):
        offer = self.offer()
        self.send('media.accept', {'id': offer['id']})
        received = bytearray()
        while True:
            packet = self.receive()
            if packet['type'] == 'media.finish':
                break
            self.assertEqual(packet['type'], 'media.chunk')
            received.extend(base64.b64decode(packet['payload']['data']))
            self.send('media.ack', {'id': offer['id'], 'next': str(int(packet['payload']['index']) + 1)})
        self.assertEqual(bytes(received), self.data)
        self.assertEqual(hashlib.sha256(received).hexdigest(), offer['sha256'])
        self.send('media.complete', {**{k: offer[k] for k in ('id', 'sha256', 'bytes')}, 'state': 'staged'})
        self.send('ping', {'id': 'complete-check'})
        self.assertEqual(self.receive()['type'], 'pong')
        self.assertTrue(any(event.get('completed') for event in self.events))
        self.assertEqual(self.path.read_bytes(), self.data)

    def test_withdrawn_receive_capability_cancels_inflight_transfer(self):
        offer = self.offer()
        self.send('media.accept', {'id': offer['id']})
        self.assertEqual(self.receive()['type'], 'media.chunk')
        self.send('capabilities', {'endpoint': 'ios', 'features': 'cards'})
        cancelled = self.receive()
        self.assertEqual((cancelled['type'], cancelled['payload']), ('media.cancel', {'id': offer['id'], 'code': 'disabled'}))
        self.send('ping', {'id': 'cancel-check'})
        self.assertEqual(self.receive()['type'], 'pong')
        self.assertEqual(self.path.read_bytes(), self.data)


if __name__ == '__main__':
    unittest.main()
