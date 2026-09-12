"""Opt-in, explicit-file camera fixtures for the authenticated TCP simulator."""
from __future__ import annotations

import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import stat
import time
from typing import BinaryIO
import uuid

CHUNK_BYTES = 3072
SESSION_BYTES = 500 * 1024 * 1024
MIMES = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.mp4': 'video/mp4', '.3gp': 'video/3gpp'}
CODES = {'disabled', 'unsupported', 'quota', 'storage', 'state', 'integrity', 'timeout'}
SCHEMAS = {
    'media.begin': {'id', 'sha256', 'bytes', 'chunks', 'chunk_bytes', 'mime', 'captured_ms'},
    'media.accept': {'id'}, 'media.chunk': {'id', 'index', 'data'},
    'media.ack': {'id', 'next'}, 'media.finish': {'id'},
    'media.complete': {'id', 'sha256', 'bytes', 'state'}, 'media.cancel': {'id', 'code'},
}


class MediaTransferError(ValueError):
    pass


def open_fixture(path: Path) -> BinaryIO:
    """Bind reads to a regular no-follow file descriptor, including across path swaps."""
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        actual, named = os.fstat(descriptor), path.lstat()
        if not stat.S_ISREG(actual.st_mode) or not stat.S_ISREG(named.st_mode) or (actual.st_dev, actual.st_ino) != (named.st_dev, named.st_ino):
            raise MediaTransferError('media fixture is not a stable regular file')
        return os.fdopen(descriptor, 'rb')
    except BaseException:
        os.close(descriptor)
        raise


def fingerprint(value: os.stat_result) -> tuple[int, int, int, int]:
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def integer(value: str, maximum: int = (1 << 53) - 1) -> int:
    if not re.fullmatch(r'0|[1-9][0-9]{0,15}', value) or int(value) > maximum:
        raise MediaTransferError('invalid media integer')
    return int(value)


def validate_media(kind: str, payload: dict[str, str]) -> None:
    if kind not in SCHEMAS or set(payload) != SCHEMAS[kind]:
        raise MediaTransferError('invalid media schema')
    if not re.fullmatch(r'[0-9a-f]{32}', payload['id']):
        raise MediaTransferError('invalid media id')
    if 'sha256' in payload and not re.fullmatch(r'[0-9a-f]{64}', payload['sha256']):
        raise MediaTransferError('invalid media digest')
    if kind == 'media.begin':
        mime = payload['mime']
        if mime not in MIMES.values() or payload['chunk_bytes'] != str(CHUNK_BYTES):
            raise MediaTransferError('unsupported media format')
        size = integer(payload['bytes'], (50 if mime.startswith('image/') else 250) * 1024 * 1024)
        if size == 0 or integer(payload['chunks']) != (size + CHUNK_BYTES - 1) // CHUNK_BYTES:
            raise MediaTransferError('invalid media size')
        integer(payload['captured_ms'])
    elif kind == 'media.chunk':
        integer(payload['index'])
        try:
            data = base64.b64decode(payload['data'], validate=True)
        except (ValueError, binascii.Error) as exc:
            raise MediaTransferError('invalid media base64') from exc
        if not 0 < len(data) <= CHUNK_BYTES or base64.b64encode(data).decode() != payload['data']:
            raise MediaTransferError('invalid media chunk')
    elif kind == 'media.ack':
        integer(payload['next'])
    elif kind == 'media.complete':
        if not 0 < integer(payload['bytes']) <= 250 * 1024 * 1024 or payload['state'] not in {'staged', 'deduplicated'}:
            raise MediaTransferError('invalid media completion')
    elif kind == 'media.cancel' and payload['code'] not in CODES:
        raise MediaTransferError('invalid media cancellation')


class FixtureMediaSender:
    """Streams only explicitly selected test files; never scans or modifies a device."""
    def __init__(self, paths: list[Path]) -> None:
        if len(paths) > 16:
            raise ValueError('at most 16 explicit media fixtures')
        self.paths = paths
        for path in paths:
            if path.is_symlink() or not path.is_file() or path.suffix.lower() not in MIMES:
                raise ValueError('media fixture must be a regular JPEG, PNG, MP4 or 3GP file')
        self.stream: BinaryIO | None = None
        self.reset()

    def reset(self) -> None:
        if self.stream:
            self.stream.close()
        self.stream = None
        self.cursor = 0
        self.available = False
        self.active: dict[str, str] | None = None
        self.phase = ''
        self.next_index = 0
        self.deadline = 0.0
        self.total_bytes = 0
        self.paused = False

    def set_available(self, available: bool) -> list[tuple[str, dict[str, str]]]:
        changed = available != self.available
        self.available = available
        if not available:
            return self.cancel('disabled') if self.active else []
        if changed:
            self.paused = False
        return self.begin() if self.active is None and not self.paused else []

    def begin(self) -> list[tuple[str, dict[str, str]]]:
        if not self.available or self.cursor >= len(self.paths):
            return []
        path = self.paths[self.cursor]
        if path.is_symlink() or not path.is_file():
            self.paused = True
            return []
        self.source_stat = path.lstat()
        size = self.source_stat.st_size
        mime = MIMES[path.suffix.lower()]
        limit = (50 if mime.startswith('image/') else 250) * 1024 * 1024
        if not 0 < size <= limit or self.total_bytes + size > SESSION_BYTES:
            self.paused = True
            return []
        with open_fixture(path) as stream:
            if fingerprint(os.fstat(stream.fileno())) != fingerprint(self.source_stat):
                raise MediaTransferError('media fixture changed before hashing')
            header = stream.read(16)
            valid = (mime == 'image/jpeg' and header.startswith(b'\xff\xd8\xff') or
                     mime == 'image/png' and header.startswith(b'\x89PNG\r\n\x1a\n') or
                     mime.startswith('video/') and header[4:8] == b'ftyp')
            if not valid:
                raise MediaTransferError('media fixture signature mismatch')
            stream.seek(0)
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.active = dict(id=uuid.uuid4().hex, sha256=digest, bytes=str(size),
                           chunks=str((size + CHUNK_BYTES - 1) // CHUNK_BYTES), chunk_bytes=str(CHUNK_BYTES),
                           mime=mime, captured_ms=str(max(0, int(self.source_stat.st_mtime * 1000))))
        validate_media('media.begin', self.active)
        self.phase = 'accept'
        self.next_index = 0
        self.deadline = time.monotonic() + 30
        return [('media.begin', dict(self.active))]

    def receive(self, kind: str, payload: dict[str, str]) -> list[tuple[str, dict[str, str]]]:
        validate_media(kind, payload)
        if self.active is None or payload['id'] != self.active['id']:
            raise MediaTransferError('media response does not match active transfer')
        if kind == 'media.cancel':
            self.cancel(payload['code'])
            return []
        if kind == 'media.complete':
            expected_phase = 'accept' if payload['state'] == 'deduplicated' else 'complete'
            if self.phase != expected_phase or any(payload[field] != self.active[field] for field in ('sha256', 'bytes')):
                raise MediaTransferError('premature or mismatched media completion')
            self.total_bytes += int(self.active['bytes'])
            if self.stream:
                self.stream.close()
                self.stream = None
            self.active = None
            self.cursor += 1
            return self.begin()
        if kind == 'media.accept' and self.phase == 'accept':
            self.stream = open_fixture(self.paths[self.cursor])
            if fingerprint(os.fstat(self.stream.fileno())) != fingerprint(self.source_stat):
                return self.cancel('integrity')
            self.sent_digest = hashlib.sha256()
        elif kind == 'media.ack' and self.phase == 'ack' and integer(payload['next']) == self.next_index:
            pass
        else:
            raise MediaTransferError('invalid media response order')
        self.deadline = time.monotonic() + 30
        return self.send_next()

    def send_next(self) -> list[tuple[str, dict[str, str]]]:
        assert self.active is not None and self.stream is not None
        if self.next_index == int(self.active['chunks']):
            current = self.paths[self.cursor].lstat()
            if not stat.S_ISREG(current.st_mode) or fingerprint(current) != fingerprint(self.source_stat) or fingerprint(os.fstat(self.stream.fileno())) != fingerprint(self.source_stat) or self.sent_digest.hexdigest() != self.active['sha256']:
                return self.cancel('integrity')
            self.phase = 'complete'
            return [('media.finish', {'id': self.active['id']})]
        expected = min(CHUNK_BYTES, int(self.active['bytes']) - self.next_index * CHUNK_BYTES)
        data = self.stream.read(expected)
        if len(data) != expected:
            return self.cancel('integrity')
        self.sent_digest.update(data)
        packet = ('media.chunk', {'id': self.active['id'], 'index': str(self.next_index), 'data': base64.b64encode(data).decode()})
        self.next_index += 1
        self.phase = 'ack'
        return [packet]

    def cancel(self, code: str) -> list[tuple[str, dict[str, str]]]:
        packet = [('media.cancel', {'id': self.active['id'], 'code': code})] if self.active else []
        if self.stream:
            self.stream.close()
            self.stream = None
        self.active = None
        self.phase = ''
        self.paused = True
        return packet

    def tick(self) -> list[tuple[str, dict[str, str]]]:
        return self.cancel('timeout') if self.active and time.monotonic() >= self.deadline else []
