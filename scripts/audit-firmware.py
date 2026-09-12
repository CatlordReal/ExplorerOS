#!/usr/bin/env python3
"""Inspect the pinned ExplorerOS backup without extracting or executing guest files.

This is a structural audit, not a boot emulator or a safe-to-flash certificate.
Android v0 header/hash layout follows AOSP system/core/mkbootimg (Android 4.4).
"""

import argparse
from collections import Counter
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tarfile
import zipfile

BASE_SHA256 = "a9997605089820b0bb23be90a126ed58cc2b853243af4ce4cc96c738d567a17d"
APK_NAME = "system/app/ExplorerLink.apk"
PAYLOADS = {"boot.img", "recovery.img", "system.ext4.tar.a", "data.ext4.tar.a", "cache.ext4.tar.a"}
MARKERS = {"system.ext4.tar", "data.ext4.tar", "cache.ext4.tar"}
NAMES = PAYLOADS | MARKERS | {"nandroid.md5", "recovery.log"}
MIB = 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(stream, algorithm="sha256", count=None):
    value = hashlib.new(algorithm)
    while count is None or count:
        part = stream.read(MIB if count is None else min(MIB, count))
        if not part:
            require(count in (None, 0), "Truncated stream")
            break
        value.update(part)
        if count is not None:
            count -= len(part)
    return value.hexdigest()


def file_digest(path):
    with path.open("rb") as stream:
        return digest(stream)


def identity(path, limit):
    value = path.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_size <= limit, "Unsupported input file")
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


def zero_tail(stream, minimum):
    count = 0
    for block in iter(lambda: stream.read(MIB), b""):
        require(not any(block), "Nonzero archive tail")
        count += len(block)
    require(count >= minimum, "Missing archive end marker")


def rounded(size, alignment):
    return (size + alignment - 1) // alignment * alignment


def safe_name(name):
    require(bool(name) and "\0" not in name and not name.startswith("/"), "Unsafe member path")
    if name.startswith("./"):
        name = name[2:]
    require(".." not in PurePosixPath(name).parts, "Parent traversal")
    return str(PurePosixPath(name))


def parse_cpio(data):
    """Bounded newc inspection; no guest path is ever opened on the host."""
    require(len(data) <= 64 * MIB, "Ramdisk expansion limit")
    offset, entries = 0, {}
    while True:
        require(offset + 110 <= len(data) and data[offset:offset + 6] == b"070701", "Invalid newc header")
        numeric = data[offset + 6:offset + 110]
        require(re.fullmatch(b"[0-9a-fA-F]{104}", numeric) is not None, "Invalid newc numeric field")
        fields = [int(numeric[n * 8:n * 8 + 8], 16) for n in range(13)]
        mode, size, name_size = fields[1], fields[6], fields[11]
        require(1 <= name_size <= 4096 and size <= 32 * MIB and fields[12] == 0, "Invalid newc bounds")
        end = offset + 110 + name_size
        require(end <= len(data) and data[end - 1] == 0, "Truncated newc name")
        raw = data[offset + 110:end - 1]
        require(b"\0" not in raw, "Ambiguous newc name")
        name = raw.decode("utf-8")
        offset = rounded(end, 4)
        require(offset + size <= len(data), "Truncated newc body")
        body = data[offset:offset + size]
        offset = rounded(offset + size, 4)
        require(offset <= len(data), "Truncated newc padding")
        if name == "TRAILER!!!":
            require(size == 0 and not any(data[offset:]), "Unexpected newc tail")
            return entries
        name = safe_name(name)
        require(name not in entries and len(entries) < 16384, "Duplicate or excessive newc members")
        entries[name] = (mode, body)


def inspect_boot(data):
    require(608 <= len(data) <= 16 * MIB and data[:8] == b"ANDROID!", "Invalid Android boot image")
    kernel_size, kernel_address, ramdisk_size, ramdisk_address, second_size, second_address, tags, page, dt, unused = struct.unpack_from("<10I", data, 8)
    require(page in (2048, 4096, 8192, 16384) and dt == 0 and unused == 0, "Unsupported legacy boot layout")
    require(kernel_size >= 48 and ramdisk_size > 0 and second_size == 0, "Unsupported boot components")
    offset, components, checksum = page, [], hashlib.sha1()
    for size in (kernel_size, ramdisk_size, second_size):
        require(offset + rounded(size, page) <= len(data), "Boot component exceeds image")
        body = data[offset:offset + size]
        checksum.update(body)
        checksum.update(struct.pack("<I", size))
        components.append(body)
        offset += rounded(size, page)
    require(checksum.digest() == data[576:596], "Boot image SHA-1 ID mismatch")
    require(components[0][36:40] == b"\x18\x28\x6f\x01", "Missing ARM zImage header")
    with gzip.GzipFile(fileobj=io.BytesIO(components[1])) as compressed:
        ramdisk = compressed.read(64 * MIB + 1)
        require(len(ramdisk) <= 64 * MIB, "Ramdisk expansion limit")
    entries = parse_cpio(ramdisk)
    require("init" in entries and stat.S_ISREG(entries["init"][0]), "Missing ramdisk init")
    selected = {}
    for name in ("etc/recovery.fstab", "default.prop", "init.omap4430.usb.rc", "sbin/recovery"):
        if name in entries:
            mode, body = entries[name]
            selected[name] = {"sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body), "mode": oct(mode)}
    usb = entries.get("init.omap4430.usb.rc", (0, b""))[1]
    return {"imageBytes": len(data), "headerIDVerified": True, "pageBytes": page,
            "kernelBytes": kernel_size, "ramdiskBytes": ramdisk_size,
            "kernelAddress": hex(kernel_address), "ramdiskAddress": hex(ramdisk_address),
            "tagsAddress": hex(tags), "secondAddress": hex(second_address),
            "cpioMembers": len(entries), "ramdiskExpandedBytes": len(ramdisk),
            "selectedRamdiskEntries": selected,
            "ptpConfigurationPresent": b"on property:sys.usb.config=ptp\n" in usb,
            "imageTailBytes": len(data) - offset,
            "imageTailNonzeroBytes": sum(byte != 0 for byte in data[offset:]),
            "bootExecuted": False}


def inspect_tar(stream, partition):
    members, kinds, logical, allocated, prefix, apk = {}, Counter(), 0, 0, 0, None
    pending_name, pending_link = None, None
    while True:
        header = stream.read(512)
        require(len(header) == 512, "Truncated tar header")
        if not any(header):
            require(pending_name is None and pending_link is None, "Orphan GNU name header")
            zero_tail(stream, minimum=512)
            break
        try:
            # Decode one fixed header only. Do not let tarfile allocate PAX/GNU
            # extension bodies before our bounds and type checks.
            member = tarfile.TarInfo.frombuf(header, "utf-8", "strict")
        except tarfile.HeaderError as error:
            raise ValueError("Invalid tar header") from error
        if member.type in (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
            require(member.name == "././@LongLink" and 1 <= member.size <= 4096, "Unsupported extended header")
            body = stream.read(member.size)
            require(len(body) == member.size and body[-1:] == b"\0" and b"\0" not in body[:-1], "Invalid GNU name body")
            value = body[:-1].decode("utf-8")
            if member.type == tarfile.GNUTYPE_LONGNAME:
                require(pending_name is None, "Duplicate GNU name header")
                pending_name = value
            else:
                require(pending_link is None, "Duplicate GNU link header")
                pending_link = value
            padding = rounded(member.size, 512) - member.size
            require(stream.read(padding) == b"\0" * padding, "Invalid GNU name padding")
            prefix += 512 + rounded(member.size, 512)
            continue
        if pending_name is not None:
            member.name = pending_name
        if pending_link is not None:
            require(member.issym() or member.islnk(), "GNU link header precedes a nonlink")
            member.linkname = pending_link
        pending_name = pending_link = None
        name = safe_name(member.name)
        require(name == partition or name.startswith(partition + "/"), "Wrong partition namespace")
        require(name not in members and len(members) < 65536, "Duplicate or excessive tar members")
        require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE), "Unsupported tar node or extended header")
        require(0 <= member.size <= 1024 * MIB and (member.isfile() or member.size == 0), "Tar member exceeds bound")
        members[name] = member.type
        kinds[member.type.decode("ascii")] += 1
        logical += member.size
        allocated += rounded(member.size, 4096)
        require(logical <= 2 * 1024 * MIB, "Tar expansion limit")
        prefix += 512 + rounded(member.size, 512)
        body_hash = digest(stream, count=member.size)
        padding = rounded(member.size, 512) - member.size
        require(stream.read(padding) == b"\0" * padding, "Invalid tar padding")
        if name == APK_NAME:
            require(member.isfile() and (member.uid, member.gid, member.mode) == (0, 0, 0o644), "Wrong APK type or metadata")
            apk = body_hash
    for name in members:
        for parent in PurePosixPath(name).parents:
            if str(parent) in members:
                require(members[str(parent)] == tarfile.DIRTYPE, "Tar member below a nondirectory")
    return {"members": len(members), "types": dict(kinds), "logicalFileBytes": logical,
            "fileBytesRoundedTo4096": allocated, "tarContentBytes": prefix,
            "apkSHA256": apk, "partitionCapacityVerified": False}


def inspect_zip(archive):
    names = archive.namelist()
    require(len(names) == len(NAMES) and set(names) == NAMES, "Unexpected CWM ZIP inventory")
    require(sum(entry.file_size for entry in archive.infolist()) <= 2 * 1024 * MIB, "ZIP expansion limit")
    hashes, md5s = {}, {}
    for entry in archive.infolist():
        require(entry.file_size <= 1024 * MIB and not entry.flag_bits & 1, "Unsupported ZIP member")
        require(entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "Unsupported ZIP compression")
        with archive.open(entry) as stream:
            sha, md5 = hashlib.sha256(), hashlib.md5()
            for block in iter(lambda: stream.read(MIB), b""):
                sha.update(block); md5.update(block)
            hashes[entry.filename], md5s[entry.filename] = sha.hexdigest(), md5.hexdigest()
    require(archive.getinfo("nandroid.md5").file_size <= 16384, "Checksum file exceeds bound")
    checked = set()
    for line in archive.read("nandroid.md5").decode("ascii").splitlines():
        fields = line.split()
        require(len(fields) == 2 and re.fullmatch("[a-fA-F0-9]{32}", fields[0]) is not None, "Malformed CWM MD5")
        checksum, name = fields
        require(name in PAYLOADS | MARKERS and name not in checked and checksum.lower() == md5s[name], "Invalid CWM MD5")
        checked.add(name)
    require(PAYLOADS.issubset(checked), "Missing partition checksum")
    for marker in ("system.ext4.tar", "data.ext4.tar", "cache.ext4.tar"):
        require(archive.getinfo(marker).file_size == 0, "Split tar marker is not empty")
    return hashes


def audit(base, derived, apk):
    limits = {base: 1024 * MIB, derived: 1024 * MIB, apk: 32 * MIB}
    identities = {path: identity(path, limit) for path, limit in limits.items()}
    input_hashes = {path: file_digest(path) for path in limits}
    require(input_hashes[base] == BASE_SHA256, "Base is not the pinned original")
    with zipfile.ZipFile(base) as original, zipfile.ZipFile(derived) as changed:
        before, after = inspect_zip(original), inspect_zip(changed)
        for name in NAMES - {"system.ext4.tar.a", "nandroid.md5"}:
            require(before[name] == after[name], "Unrelated payload changed: " + name)
        partitions = {}
        for name in ("system", "data", "cache"):
            with changed.open(name + ".ext4.tar.a") as stream:
                partitions[name] = inspect_tar(stream, name)
        with original.open("system.ext4.tar.a") as stream:
            old_system = inspect_tar(stream, "system")
        prefix = old_system["tarContentBytes"]
        with original.open("system.ext4.tar.a") as left, changed.open("system.ext4.tar.a") as right:
            require(digest(left, count=prefix) == digest(right, count=prefix), "Original system bytes changed")
            zero_tail(left, minimum=1024)
        require(partitions["system"]["members"] == old_system["members"] + 1, "Unexpected added tar members")
        require(partitions["system"]["apkSHA256"] == input_hashes[apk], "Integrated APK differs")
        for name in ("boot.img", "recovery.img"):
            require(changed.getinfo(name).file_size <= 16 * MIB, "Boot image exceeds bound")
        boot = {name: inspect_boot(changed.read(name)) for name in ("boot.img", "recovery.img")}
        for path, limit in limits.items():
            require(identity(path, limit) == identities[path] and file_digest(path) == input_hashes[path], "Input changed during audit")
        return {"version": 1, "baseSHA256": BASE_SHA256, "firmwareSHA256": input_hashes[derived],
                "apkSHA256": input_hashes[apk], "zipCRCAndCWMChecksumsVerified": True,
                "originalSystemMembersPreserved": old_system["members"],
                "originalSystemBytesPreserved": prefix, "unchangedOtherPayloads": True,
                "partitions": partitions, "bootImages": boot,
                "guestFilesExtractedOrExecuted": False, "hardwareValidated": False,
                "safeToFlashCertified": False,
                "limitations": ["No Glass boot, flash or restore was executed.",
                                "Rounded file bytes exclude filesystem metadata and are not a partition fit guarantee.",
                                "Power loss, worn flash, bootloader and device-specific restore behavior remain untested."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-zip", type=Path, required=True)
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--apk", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(audit(args.base_zip, args.firmware, args.apk), indent=2))
