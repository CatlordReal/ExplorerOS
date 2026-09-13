#!/usr/bin/env python3
"""Pure release-admission tests; no signing key, build or device is used."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("update", Path(__file__).with_name("build-update.py"))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class UpdateTests(unittest.TestCase):
    signer = "a" * 64

    def info(self, code=1, package=update.PACKAGE, sdk=19, signer=None):
        return package, code, sdk, signer or self.signer

    def test_same_identity_higher_version(self):
        update.validate_update(self.info(), self.info(2), self.info(3), self.signer, 3)

    def test_equal_or_downgrade_or_configuration_drift_rejected(self):
        for previous, candidate, configured in [(2, 2, 2), (3, 2, 2), (1, 2, 3), (0, 2, 2)]:
            with self.subTest(previous=previous, candidate=candidate), self.assertRaises(ValueError):
                update.validate_update(self.info(), self.info(previous), self.info(candidate), self.signer, configured)

    def test_any_reference_or_candidate_mismatch_rejected(self):
        for index in range(3):
            for bad in [self.info(2, package="other.app"), self.info(2, sdk=20), self.info(2, signer="b" * 64)]:
                values = [self.info(), self.info(), self.info(2)]
                values[index] = bad
                with self.subTest(index=index, bad=bad), self.assertRaises(ValueError):
                    update.validate_update(*values, self.signer, 2)

    def test_v1_single_signer_required(self):
        badging = "package: name='com.exploreros.glass' versionCode='2' versionName='0.1.1'\nsdkVersion:'19'\n"
        valid = "Verified using v1 scheme (JAR signing): true\nSigner #1 certificate SHA-256 digest: " + self.signer + "\n"
        self.assertEqual(update.metadata(badging, valid), self.info(2))
        for bad in [valid.replace(": true", ": false"), valid + "Signer #2 certificate SHA-256 digest: " + self.signer + "\n", ""]:
            with self.assertRaises(ValueError):
                update.metadata(badging, bad)

    def test_version_config_and_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "version.properties"
            path.write_text("versionCode=2\nversionName=0.1.1\n")
            self.assertEqual(update.version(path), 2)
            for value in ["0", "-1", "2.0", "2100000001"]:
                path.write_text("versionCode=" + value + "\nversionName=0.1.1\n")
                with self.assertRaises(ValueError): update.version(path)
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(ValueError): update.regular(link)


if __name__ == "__main__": unittest.main()
