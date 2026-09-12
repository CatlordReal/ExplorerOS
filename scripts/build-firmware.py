#!/usr/bin/env python3
"""Preinstall Explorer Link in a copy of the pinned CWM backup; never flash hardware."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import zipfile

BASE_SHA256 = "a9997605089820b0bb23be90a126ed58cc2b853243af4ce4cc96c738d567a17d"
SYSTEM_TAR = "system.ext4.tar.a"
APK_PATH = "system/app/ExplorerLink.apk"


def digest(path: Path, algorithm: str = "sha256", count: int | None = None) -> str:
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        remaining = count
        while remaining is None or remaining > 0:
            data = stream.read(min(1024 * 1024, remaining) if remaining is not None else 1024 * 1024)
            if not data:
                if remaining:
                    raise ValueError("Truncated input")
                break
            result.update(data)
            if remaining is not None:
                remaining -= len(data)
    return result.hexdigest()


def append_service(base_tar: Path, destination: Path, apk: Path) -> dict:
    """Preserve every existing tar header/body byte; replace only its end marker."""
    if destination.exists() or destination.resolve() == base_tar.resolve():
        raise ValueError("Output must be a new file")
    with tarfile.open(base_tar, "r:") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if APK_PATH in names or "system/app" not in names:
            raise ValueError("Unexpected system archive or bridge already present")
        if any(member.name.startswith("/") or ".." in Path(member.name).parts for member in members):
            raise ValueError("Unsafe archive entry path")
        prefix_size = archive.offset
    before = digest(base_tar, count=prefix_size)
    shutil.copyfile(base_tar, destination)
    with tarfile.open(destination, "a", format=tarfile.USTAR_FORMAT) as archive:
        entry = tarfile.TarInfo(APK_PATH)
        entry.size = apk.stat().st_size
        entry.mode, entry.uid, entry.gid = 0o644, 0, 0
        entry.uname = entry.gname = "root"
        entry.mtime = 1_789_084_800  # Fixed build metadata; no host-specific timestamps.
        with apk.open("rb") as stream:
            archive.addfile(entry, stream)
    if digest(destination, count=prefix_size) != before:
        raise ValueError("An existing system archive byte changed")
    with tarfile.open(destination, "r:") as archive:
        if archive.getnames() != names + [APK_PATH]:
            raise ValueError("Unexpected archive membership after integration")
        entry = archive.getmember(APK_PATH)
        with archive.extractfile(entry) as stream:
            if hashlib.sha256(stream.read()).hexdigest() != digest(apk):
                raise ValueError("Preinstalled APK does not match input")
    return {"existingSystemBytesPreserved": prefix_size, "existingSystemPrefixSHA256": before,
            "addedPath": APK_PATH, "addedMode": "0644", "addedUID": 0, "addedGID": 0}


def build(base: Path, apk: Path, output: Path) -> Path:
    if output.exists() or output.with_suffix(".build.json").exists():
        raise ValueError("Output/archive report already exists")
    if base.is_symlink() or apk.is_symlink() or not apk.is_file() or not 0 < apk.stat().st_size <= 32 * 1024 * 1024:
        raise ValueError("Provide regular base/APK files; bridge APK limit is 32 MiB")
    if digest(base) != BASE_SHA256:
        raise ValueError("Base differs from the inspected original Public Beta 3 ZIP")
    with zipfile.ZipFile(apk) as app:
        if not {"AndroidManifest.xml", "classes.dex"}.issubset(app.namelist()) or app.testzip() is not None:
            raise ValueError("APK archive is invalid")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="firmware-build-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        original_tar, integrated_tar = temporary / "original.tar", temporary / "integrated.tar"
        staged_zip = temporary / "integrated.zip"
        with zipfile.ZipFile(base) as original:
            if len(original.namelist()) != len(set(original.namelist())) or original.testzip() is not None:
                raise ValueError("Base ZIP has duplicate or damaged entries")
            md5_bytes = original.read("nandroid.md5")
            records = [line.split() for line in md5_bytes.decode("ascii").splitlines() if line]
            expected = dict((name, checksum) for checksum, name in records)
            if len(expected) != len(records):
                raise ValueError("Duplicate CWM checksum entries")
            with original.open(SYSTEM_TAR) as source, original_tar.open("wb") as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            preservation = append_service(original_tar, integrated_tar, apk)
            unchanged = {}
            with zipfile.ZipFile(staged_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as integrated:
                for info in original.infolist():
                    if info.filename == "nandroid.md5":
                        continue
                    md5, sha = hashlib.md5(), hashlib.sha256()  # CWM requires MD5; SHA-256 records integrity separately.
                    with original.open(info) as stream:
                        for data in iter(lambda: stream.read(1024 * 1024), b""):
                            md5.update(data); sha.update(data)
                    if info.filename in expected and md5.hexdigest() != expected[info.filename]:
                        raise ValueError(f"Original CWM checksum mismatch: {info.filename}")
                    if info.filename == SYSTEM_TAR:
                        with integrated_tar.open("rb") as source, integrated.open(info, "w") as target:
                            shutil.copyfileobj(source, target, 1024 * 1024)
                    else:
                        unchanged[info.filename] = sha.hexdigest()
                        with original.open(info) as source, integrated.open(info, "w") as target:
                            shutil.copyfileobj(source, target, 1024 * 1024)
                updated_md5, count = re.subn(rb"(?m)^[a-fA-F0-9]{32}(?=[ \t]+system\.ext4\.tar\.a\r?$)",
                                            digest(integrated_tar, "md5").encode("ascii"), md5_bytes)
                if count != 1:
                    raise ValueError("Expected exactly one system archive checksum")
                integrated.writestr(original.getinfo("nandroid.md5"), updated_md5)
        with zipfile.ZipFile(staged_zip) as verified:
            if verified.testzip() is not None:
                raise ValueError("Integrated ZIP integrity check failed")
            for name, expected_sha in unchanged.items():
                actual = hashlib.sha256()
                with verified.open(name) as stream:
                    for data in iter(lambda: stream.read(1024 * 1024), b""):
                        actual.update(data)
                if actual.hexdigest() != expected_sha:
                    raise ValueError(f"Unrelated payload changed: {name}")
        report = {"version": 1, "format": "cwm-backup", "integration": "preinstalled-background-service",
                  "baseSHA256": BASE_SHA256, "outputSHA256": digest(staged_zip), "apkSHA256": digest(apk),
                  "unchangedEntries": unchanged, "preservation": preservation,
                  "hardwareValidated": False, "preservationScope": "input-archive-bytes-only",
                  "bootloaderKernelRecoveryChanged": False,
                  "devicePartitionsMayBeWrittenByRestore": True,
                  "restoreMayWritePartitions": ["boot", "system", "data", "cache"],
                  "restorationMayReplaceDeviceData": True,
                  "deviceCompatibilityValidated": False,
                  "partitionCapacityValidated": False,
                  "recoveryProcedureValidated": False}
        os.link(staged_zip, output)  # Exclusive publication: never replace an existing output.
        report_path = output.with_suffix(".build.json")
        with report_path.open("x") as stream:
            stream.write(json.dumps(report, indent=2) + "\n")
    return report_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-zip", type=Path, required=True)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(build(args.base_zip, args.apk, args.output))
