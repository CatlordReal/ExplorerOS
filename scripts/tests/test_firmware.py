import importlib.util
import io
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("firmware", Path(__file__).parents[1] / "build-firmware.py")
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)


class FirmwarePreservationTests(unittest.TestCase):
    def test_append_preserves_original_headers_content_and_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            base, output, apk = root / "base.tar", root / "integrated.tar", root / "bridge.apk"
            apk.write_bytes(b"synthetic apk")
            with tarfile.open(base, "w") as archive:
                directory = tarfile.TarInfo("system/app"); directory.type = tarfile.DIRTYPE; directory.mode = 0o755
                archive.addfile(directory)
                old = tarfile.TarInfo("system/app/Original.apk"); old.size = 4; old.mode = 0o640; old.uid = 123; old.mtime = 123456
                archive.addfile(old, io.BytesIO(b"keep"))
            report = firmware.append_service(base, output, apk)
            length = report["existingSystemBytesPreserved"]
            self.assertEqual(base.read_bytes()[:length], output.read_bytes()[:length])
            with tarfile.open(output) as archive:
                self.assertEqual(archive.extractfile("system/app/Original.apk").read(), b"keep")
                old = archive.getmember("system/app/Original.apk")
                self.assertEqual((old.uid, old.mode, old.mtime), (123, 0o640, 123456))
                added = archive.getmember(firmware.APK_PATH)
                self.assertEqual((added.uid, added.gid, added.mode), (0, 0, 0o644))
                self.assertEqual(archive.extractfile(added).read(), apk.read_bytes())
            with self.assertRaises(ValueError):
                firmware.append_service(base, output, apk)
            with self.assertRaises(ValueError):
                firmware.append_service(output, root / "again.tar", apk)

    def test_rejects_wrong_base_before_creating_output(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); base, apk, output = root / "wrong.zip", root / "bridge.apk", root / "result.zip"
            base.write_bytes(b"wrong firmware"); apk.write_bytes(b"apk")
            with self.assertRaises(ValueError):
                firmware.build(base, apk, output)
            self.assertFalse(output.exists())

    def test_full_build_preserves_unrelated_payloads_and_md5_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); base, apk, output = root / "base.zip", root / "bridge.apk", root / "result.zip"
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w") as archive:
                entry = tarfile.TarInfo("system/app"); entry.type = tarfile.DIRTYPE; archive.addfile(entry)
            system = stream.getvalue()
            payloads = {"boot.img": b"original boot", "recovery.img": b"original recovery", "data.ext4.tar.a": b"original data",
                        "system.ext4.tar.a": system, "recovery.log": b"original log"}
            md5 = b"".join(hashlib.md5(data).hexdigest().encode() + b"  " + name.encode() + b"\r\n"
                           for name, data in payloads.items() if name != "recovery.log")
            with zipfile.ZipFile(base, "w") as archive:
                for name, data in payloads.items(): archive.writestr(name, data)
                archive.writestr("nandroid.md5", md5)
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"fixture"); archive.writestr("classes.dex", b"fixture")
            with patch.object(firmware, "BASE_SHA256", firmware.digest(base)):
                report_path = firmware.build(base, apk, output)
            report = json.loads(report_path.read_text())
            self.assertEqual(report["outputSHA256"], firmware.digest(output))
            self.assertFalse(report["hardwareValidated"])
            self.assertEqual(report["preservationScope"], "input-archive-bytes-only")
            self.assertFalse(report["bootloaderKernelRecoveryChanged"])
            self.assertTrue(report["devicePartitionsMayBeWrittenByRestore"])
            self.assertEqual(report["restoreMayWritePartitions"], ["boot", "system", "data", "cache"])
            self.assertTrue(report["restorationMayReplaceDeviceData"])
            for gate in ["deviceCompatibilityValidated", "partitionCapacityValidated", "recoveryProcedureValidated"]:
                self.assertFalse(report[gate])
            with zipfile.ZipFile(output) as archive:
                for name, data in payloads.items():
                    if name != "system.ext4.tar.a": self.assertEqual(archive.read(name), data)
                replacement = hashlib.md5(archive.read("system.ext4.tar.a")).hexdigest().encode()
                self.assertEqual(archive.read("nandroid.md5"), md5.replace(hashlib.md5(system).hexdigest().encode(), replacement))
            with self.assertRaises(ValueError): firmware.build(base, apk, output)


if __name__ == "__main__":
    unittest.main()
