import gzip
import hashlib
import importlib.util
import io
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("audit", Path(__file__).parents[1] / "audit-firmware.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def cpio(records):
    result = bytearray()
    for name, body, mode in records + [("TRAILER!!!", b"", 0)]:
        name = name.encode() + b"\0"
        fields = (1, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name), 0)
        result.extend(b"070701" + b"".join(f"{value:08x}".encode() for value in fields) + name)
        result.extend(b"\0" * (-len(result) % 4))
        result.extend(body)
        result.extend(b"\0" * (-len(result) % 4))
    return bytes(result)


def boot_image(ramdisk=None):
    if ramdisk is None:
        ramdisk = cpio([("init", b"synthetic init", 0o100755)])
    compressed = gzip.compress(ramdisk, mtime=0)
    kernel = bytearray(128)
    kernel[36:40] = b"\x18\x28\x6f\x01"
    page = 2048
    image = bytearray(page)
    image[:8] = b"ANDROID!"
    struct.pack_into("<10I", image, 8, len(kernel), 0x80008000, len(compressed), 0x81000000, 0, 0x80f00000, 0x80000100, page, 0, 0)
    checksum = hashlib.sha1()
    for body in (kernel, compressed, b""):
        checksum.update(body)
        checksum.update(struct.pack("<I", len(body)))
        image.extend(body)
        image.extend(b"\0" * (-len(image) % page))
    image[576:596] = checksum.digest()
    return bytes(image)


def tar_bytes(records):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name, kind, body in records:
            entry = tarfile.TarInfo(name)
            entry.type, entry.mode = kind, 0o644
            if kind == tarfile.REGTYPE:
                entry.size = len(body)
            elif kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                entry.linkname = body.decode()
            archive.addfile(entry, io.BytesIO(body) if entry.isfile() else None)
    return output.getvalue()


def zip_bytes(payloads):
    payloads = dict(payloads)
    payloads["nandroid.md5"] = b"".join(hashlib.md5(payloads[name]).hexdigest().encode() + b"  " + name.encode() + b"\n" for name in sorted(audit.PAYLOADS | audit.MARKERS))
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, body in payloads.items():
            archive.writestr(name, body)
    return output.getvalue()


class FirmwareStructureTests(unittest.TestCase):
    def test_valid_boot_components_and_no_execution_claim(self):
        result = audit.inspect_boot(boot_image())
        self.assertTrue(result["headerIDVerified"])
        self.assertEqual(result["cpioMembers"], 1)
        self.assertFalse(result["bootExecuted"])

    def test_truncated_or_modified_boot_is_rejected(self):
        original = boot_image()
        for length in (0, 7, 48, 608, 2047, 2048, len(original) - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                audit.inspect_boot(original[:length])
        for offset in (0, 8, 16, 24, 36, 40, 576, 2048, 4096):
            changed = bytearray(original)
            changed[offset] ^= 0x55
            with self.subTest(offset=offset), self.assertRaises((ValueError, OSError)):
                audit.inspect_boot(changed)

    def test_bounded_gzip_expansion(self):
        with self.assertRaisesRegex(ValueError, "expansion limit"):
            audit.inspect_boot(boot_image(b"\0" * (64 * audit.MIB + 1)))

    def test_cpio_traversal_duplicates_and_trailing_data(self):
        for name in ("../escape", "/outside", "dir/../../escape", "a\0b"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                audit.parse_cpio(cpio([(name, b"x", 0o100644)]))
        duplicate = cpio([("init", b"x", 0o100644), ("./init", b"x", 0o100644)])
        with self.assertRaises(ValueError):
            audit.parse_cpio(duplicate)
        with self.assertRaises(ValueError):
            audit.parse_cpio(cpio([]) + b"hidden")
        valid = cpio([("init", b"x", 0o100644)])
        for length in (0, 109, 111, 116, len(valid) - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                audit.parse_cpio(valid[:length])

    def test_cpio_numeric_fields_are_unsigned_hex(self):
        valid = cpio([("init", b"x", 0o100644)])
        for field in (b"-0000001", b"+0000001", b" 0000001", b"0000001 "):
            changed = bytearray(valid)
            changed[54:62] = field
            with self.subTest(field=field), self.assertRaises(ValueError):
                audit.parse_cpio(changed)

    def test_extended_tar_metadata_is_rejected_before_body_read(self):
        for kind in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_SPARSE):
            header = tarfile.TarInfo("system/metadata")
            header.type, header.size = kind, 512 * audit.MIB
            stream = io.BytesIO(header.tobuf())
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "extended header"):
                audit.inspect_tar(stream, "system")
            self.assertEqual(stream.tell(), 512)

    def test_bounded_legacy_gnu_names(self):
        long_name = "system/" + "a" * 110
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w", format=tarfile.GNU_FORMAT) as archive:
            entry = tarfile.TarInfo(long_name)
            archive.addfile(entry)
        self.assertEqual(audit.inspect_tar(io.BytesIO(output.getvalue()), "system")["members"], 1)
        # Extension metadata must be followed by a real member and cannot make
        # an otherwise out-of-root member pass namespace validation.
        orphan = output.getvalue()[:1024] + bytes(1024)
        with self.assertRaisesRegex(ValueError, "Orphan"):
            audit.inspect_tar(io.BytesIO(orphan), "system")
        duplicate = output.getvalue()[:1024] + output.getvalue()
        with self.assertRaisesRegex(ValueError, "Duplicate GNU"):
            audit.inspect_tar(io.BytesIO(duplicate), "system")
        unsafe = output.getvalue().replace(long_name.encode(), ("../bad/" + "a" * 110).encode(), 1)
        with self.assertRaisesRegex(ValueError, "traversal"):
            audit.inspect_tar(io.BytesIO(unsafe), "system")

    def test_tar_rejects_paths_duplicates_and_link_parents(self):
        fixtures = [
            [("../escape", tarfile.REGTYPE, b"x")],
            [("data/file", tarfile.REGTYPE, b"x")],
            [("system/a", tarfile.REGTYPE, b"x"), ("system/a", tarfile.REGTYPE, b"y")],
            [("system/app", tarfile.SYMTYPE, b"/outside"), ("system/app/x", tarfile.REGTYPE, b"x")],
            [("system/app/x", tarfile.REGTYPE, b"x"), ("system/app", tarfile.SYMTYPE, b"/outside")],
        ]
        for records in fixtures:
            with self.subTest(records=records), self.assertRaises(ValueError):
                audit.inspect_tar(io.BytesIO(tar_bytes(records)), "system")

    def test_tar_fifo_is_only_inspected_and_capacity_is_not_certified(self):
        data = tar_bytes([("data/control", tarfile.FIFOTYPE, b""), ("data/file", tarfile.REGTYPE, b"abc")])
        result = audit.inspect_tar(io.BytesIO(data), "data")
        self.assertEqual(result["logicalFileBytes"], 3)
        self.assertEqual(result["fileBytesRoundedTo4096"], 4096)
        self.assertFalse(result["partitionCapacityVerified"])

    def test_current_zip_layout_crc_md5_and_partition_coverage(self):
        payloads = {name: b"fixture" for name in audit.NAMES - {"nandroid.md5"}}
        for marker in ("system.ext4.tar", "data.ext4.tar", "cache.ext4.tar"):
            payloads[marker] = b""
        valid = zip_bytes(payloads)
        with zipfile.ZipFile(io.BytesIO(valid)) as archive:
            self.assertEqual(set(audit.inspect_zip(archive)), audit.NAMES)
        changed = bytearray(valid)
        offset = changed.index(b"fixture")
        changed[offset] ^= 1
        with zipfile.ZipFile(io.BytesIO(changed)) as archive, self.assertRaises(zipfile.BadZipFile):
            audit.inspect_zip(archive)
        for change in ("missing", "extra", "md5", "marker"):
            with zipfile.ZipFile(io.BytesIO(valid)) as source:
                content = {name: source.read(name) for name in source.namelist()}
            if change == "missing":
                del content["boot.img"]
            elif change == "extra":
                content["../escape"] = b"x"
            elif change == "md5":
                content["nandroid.md5"] = b"0" * 32 + b"  boot.img\n"
            else:
                content["system.ext4.tar"] = b"not empty"
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                for name, body in content.items():
                    archive.writestr(name, body)
            with self.subTest(change=change), zipfile.ZipFile(io.BytesIO(output.getvalue())) as archive, self.assertRaises(ValueError):
                audit.inspect_zip(archive)

    def test_full_audit_preserves_base_and_rejects_substituted_apk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base, firmware, apk = root / "base.zip", root / "firmware.zip", root / "app.apk"
            apk.write_bytes(b"fixture APK")
            system = [("system/app", tarfile.DIRTYPE, b""), ("system/app/old.apk", tarfile.REGTYPE, b"old")]
            payloads = {"boot.img": boot_image(), "recovery.img": boot_image(), "recovery.log": b"fixture"}
            for partition, records in (("system", system), ("data", []), ("cache", [])):
                payloads[partition + ".ext4.tar"] = b""
                payloads[partition + ".ext4.tar.a"] = tar_bytes(records)
            base.write_bytes(zip_bytes(payloads))
            payloads["system.ext4.tar.a"] = tar_bytes(system + [(audit.APK_NAME, tarfile.REGTYPE, apk.read_bytes())])
            firmware.write_bytes(zip_bytes(payloads))
            with patch.object(audit, "BASE_SHA256", audit.file_digest(base)):
                result = audit.audit(base, firmware, apk)
                self.assertFalse(result["safeToFlashCertified"])
                self.assertFalse(result["hardwareValidated"])
                self.assertFalse(result["guestFilesExtractedOrExecuted"])
                self.assertEqual(result["originalSystemMembersPreserved"], 2)
                apk.write_bytes(b"replacement")
                with self.assertRaisesRegex(ValueError, "APK differs"):
                    audit.audit(base, firmware, apk)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["app.apk", "base.zip", "firmware.zip"])


if __name__ == "__main__":
    unittest.main()
