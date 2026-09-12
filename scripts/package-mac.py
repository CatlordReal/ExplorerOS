#!/usr/bin/env python3
"""Create a relocatable Mac app for personal offline transfer; never access a device."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PB3_SHA256 = "a9997605089820b0bb23be90a126ed58cc2b853243af4ce4cc96c738d567a17d"
PB3_SOURCE = "https://drive.google.com/file/d/1Y6JeQiSHetOuX7c_LSAqespGjnVa1Gty/view"


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(data)
    return result.hexdigest()


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], check=True)


def check_runtime(binary: Path, app: Path | None = None) -> None:
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise SystemExit(f"Both Apple silicon and Intel slices are required: {binary}")
    dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True).splitlines()
    rpaths = []
    for index, line in enumerate(commands):
        if line.strip() == "cmd LC_RPATH":
            rpaths.append(commands[index + 2].strip().split(" (offset ", 1)[0].removeprefix("path "))

    def expand(value: str) -> str:
        if app:
            value = value.replace("@executable_path", str(app / "Contents/MacOS"))
        return value.replace("@loader_path", str(binary.parent))

    for line in dependencies.splitlines():
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (compatibility ", 1)[0]
        if dependency.startswith(("/System/", "/usr/lib/")):
            continue
        candidates = [expand(dependency)]
        if dependency.startswith("@rpath/"):
            candidates = [expand(path + "/" + dependency.removeprefix("@rpath/")) for path in rpaths]
        valid = False
        for candidate in candidates:
            if candidate.startswith(("/System/", "/usr/lib/")):
                valid = True  # System dyld shared-cache libraries need not exist as loose files.
            elif app and Path(candidate).is_file() and Path(candidate).resolve().is_relative_to(app):
                valid = True
        if not valid:
            raise SystemExit(f"Non-portable runtime dependency in {binary.name}: {dependency}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Built universal ExplorerTools.app")
    parser.add_argument("--platform-tools", type=Path, required=True, help="Existing platform-tools folder with NOTICE.txt")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--firmware", type=Path, help="Original Public Beta 3 ZIP, for personal transfer only")
    parser.add_argument("--firmware-report", type=Path, help="build-firmware.py report for an integrated service firmware ZIP")
    parser.add_argument("--output", type=Path, required=True, help="New output folder; existing folders are never overwritten")
    args = parser.parse_args()
    app, tool_root, apk = args.app.resolve(), args.platform_tools.resolve(), args.apk.resolve()
    output = args.output.absolute().resolve()
    if output.is_relative_to(app) or any(output.is_relative_to(ROOT / name) for name in
                                       ["apple", "glass-bridge", "protocol", "fixtures", "simulator", "qt", "scripts", "docs"]):
        raise SystemExit("Output must be outside the input app and source directories.")
    executable = app / "Contents/MacOS/ExplorerTools"
    if not executable.is_file() or not apk.is_file() or apk.suffix.lower() != ".apk":
        raise SystemExit("Provide a built Mac application and bridge APK.")
    for binary in [executable, tool_root / "adb", tool_root / "fastboot"]:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise SystemExit(f"Missing executable: {binary}")
        check_runtime(binary, app if binary == executable else None)
    for path in app.rglob("*"):
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(app):
                raise SystemExit(f"App contains an absolute or escaping symlink: {path}")
        elif path.is_file() and "Mach-O" in subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True):
            check_runtime(path, app)
    if not (tool_root / "NOTICE.txt").is_file():
        raise SystemExit("Platform-Tools NOTICE.txt is required.")
    integrated_firmware = False
    if args.firmware_report and not args.firmware:
        raise SystemExit("A firmware report requires its firmware ZIP.")
    if args.firmware:
        expected_sha = PB3_SHA256
        if args.firmware_report:
            report = json.loads(args.firmware_report.read_text())
            if (report.get("version") != 1 or report.get("baseSHA256") != PB3_SHA256
                    or report.get("integration") != "preinstalled-background-service"
                    or report.get("apkSHA256") != digest(apk)
                    or report.get("bootloaderKernelRecoveryChanged") is not False
                    or report.get("hardwareValidated") is not False):
                raise SystemExit("Invalid or mismatched local firmware build report.")
            expected_sha = report.get("outputSHA256")
            integrated_firmware = True
        if args.firmware.is_symlink() or digest(args.firmware) != expected_sha:
            raise SystemExit("Firmware differs from its recorded original or local build hash.")
        with zipfile.ZipFile(args.firmware) as archive:
            required = {"boot.img", "recovery.img", "data.ext4.tar.a", "system.ext4.tar.a", "nandroid.md5"}
            if not required.issubset(archive.namelist()) or archive.testzip() is not None:
                raise SystemExit("Firmware archive integrity/layout check failed.")
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="package-", dir=output) as temporary:
        staging = Path(temporary)
        destination = staging / "Explorer Tools.app"
        shutil.copytree(app, destination, symlinks=True)
        portable = destination / "Contents/Resources/Portable"
        portable.mkdir(parents=True, exist_ok=False)
        entries = []

        def add(source: Path, path: str, role: str, provenance: str, sign: bool = False) -> None:
            target = portable / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            if sign:
                run("/usr/bin/codesign", "--force", "--sign", "-", target)
            entries.append({"role": role, "path": path, "sha256": digest(target),
                            "size": target.stat().st_size, "source": provenance})

        source = "https://developer.android.com/tools/releases/platform-tools"
        add(tool_root / "adb", "Tools/adb", "adb", source, sign=True)
        add(tool_root / "fastboot", "Tools/fastboot", "fastboot", source, sign=True)
        add(apk, "Apps/ExplorerLink.apk", "bridge", "https://github.com/CatlordReal/ExplorerOS/tree/feature/apple-companion")
        if args.firmware:
            filename = "ExplorerOS-26PB3-ExplorerLink.zip" if integrated_firmware else "ExplorerOS-26-0-PublicBeta3.zip"
            add(args.firmware, "Firmware/" + filename, "firmware", PB3_SOURCE)
            if args.firmware_report:
                add(args.firmware_report, "Firmware/build-report.json", "firmwareReport", "Local build from the recorded original Public Beta 3 archive")
        licenses = portable / "Licenses"
        licenses.mkdir()
        shutil.copy2(tool_root / "NOTICE.txt", licenses / "Android-Platform-Tools-NOTICE.txt")
        shutil.copy2(ROOT / "LICENSE", licenses / "ExplorerOS-GPL-3.0.txt")
        if (tool_root / "source.properties").is_file():
            shutil.copy2(tool_root / "source.properties", licenses / "platform-tools-source.properties")
        for name in ["FIRMWARE-BUNDLE.md", "FIRMWARE-INTEGRATION.md", "UPSTREAM-INSTALLER.md", "FLASHING.md", "GLASS.md", "HARDWARE.md", "INTEGRATIONS.md", "FEASIBILITY-HFP.md"]:
            shutil.copy2(ROOT / "docs" / name, portable / name)
        guide = ROOT / "docs/PORTABLE-MAC.md"
        shutil.copy2(guide, portable / "INSTALL.md")
        shutil.copy2(guide, staging / "START HERE.md")
        (portable / "bundle.json").write_text(json.dumps({
            "version": 1, "title": "ExplorerOS + iPhone service" if integrated_firmware else "ExplorerOS Public Beta 3 + Explorer Link" if args.firmware else "Explorer Link tools",
            "firmwareFormat": "cwm-backup" if args.firmware else "none", "files": entries,
        }, indent=2) + "\n")
        # Include our source for rebuilding; exclude downloads, build products and signing material.
        with zipfile.ZipFile(staging / "ExplorerLink-source.zip", "w", zipfile.ZIP_DEFLATED) as sources:
            paths = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                                             "apple", "glass-bridge", "protocol", "fixtures", "simulator", "qt", "scripts", "docs"])
            for relative in sorted(set(paths.decode().strip("\0").split("\0"))):
                path = ROOT / relative
                if not path.is_file() or path.is_symlink():
                    continue
                if path.suffix in {".log", ".key", ".keystore", ".p12", ".pfx", ".mobileprovision", ".provisionprofile", ".xcuserstate"}:
                    continue
                if path.name in {"local.properties", ".DS_Store"} or path.name.startswith(".env"):
                    continue
                sources.write(path, relative)
            for name in ["LICENSE", "README.md", ".gitignore"]:
                sources.write(ROOT / name, name)
        run("/usr/bin/codesign", "--force", "--sign", "-", destination)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", destination)
        archive = output / "Explorer-Tools-Portable.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", staging, archive)
        shutil.move(destination, output / destination.name)
        shutil.copy2(staging / "START HERE.md", output / "START HERE.md")
        (output / "SHA256SUMS.txt").write_text(f"{digest(archive)}  {archive.name}\n")
    print(f"Personal transfer package: {archive}")
    print("No device commands ran. This developer build is not notarized.")


if __name__ == "__main__":
    main()
