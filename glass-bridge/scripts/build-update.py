#!/usr/bin/env python3
"""Build an APK update with an existing external key; never install or flash it.

Required password environment: EXPLORER_KEYSTORE_PASSWORD and EXPLORER_KEY_PASSWORD.
Supply the original shipped base and the latest released APK (initially the base).
The latter is the offline downgrade guard; this script does not query a device.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

PACKAGE = "com.exploreros.glass"
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path):
    require(path.is_file() and not path.is_symlink(), "Input must be an existing regular non-symlink file.")
    return path.resolve()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def run(args, *, signing=False):
    env = dict(os.environ)
    if not signing:
        env.pop("EXPLORER_KEYSTORE_PASSWORD", None)
        env.pop("EXPLORER_KEY_PASSWORD", None)
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, env=env, timeout=600)
    # Do not echo signer diagnostics, arguments or environment into build logs.
    require(result.returncode == 0, "Build or APK verification command failed: " + Path(args[0]).name)
    return result.stdout


def metadata(badging, verification):
    package = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)'", badging, re.M)
    sdk = re.search(r"^sdkVersion:'([0-9]+)'$", badging, re.M)
    signers = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: ([a-fA-F0-9]{64})$", verification, re.M)
    require(package is not None and sdk is not None, "APK package/version/API metadata is missing.")
    require("Verified using v1 scheme (JAR signing): true" in verification and len(signers) == 1,
            "APK must have one verified signer and API 19-compatible v1 signing.")
    return package[1], int(package[2]), int(sdk[1]), signers[0].lower()


def compatible(info, signer):
    require(info[0] == PACKAGE and info[2] == 19, "APK must be com.exploreros.glass with minSdkVersion 19.")
    require(info[3] == signer, "APK signer does not match the required existing certificate.")


def version(path):
    fields = {}
    for line in path.read_text().splitlines():
        if line and not line.startswith("#"):
            name, value = line.split("=", 1)
            require(name not in fields, "Duplicate release version field.")
            fields[name] = value
    require(set(fields) == {"versionCode", "versionName"}, "Invalid release version configuration.")
    require(re.fullmatch(r"[1-9][0-9]*", fields["versionCode"]) is not None, "Invalid versionCode.")
    code = int(fields["versionCode"])
    require(code <= 2_100_000_000 and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", fields["versionName"]), "Invalid release version.")
    return code


def validate_update(base, previous, candidate, signer, configured):
    for info in (base, previous, candidate):
        compatible(info, signer)
    require(previous[1] >= base[1], "Previous release predates the shipped base.")
    require(candidate[1] == configured and candidate[1] > max(base[1], previous[1]),
            "Update versionCode must match configuration and exceed both base and previous release.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base-apk", "previous-apk", "keystore", "alias", "expected-signer-sha256", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--sdk", type=Path, default=Path(os.environ.get("ANDROID_SDK_ROOT", "/tmp/explorer-android-sdk")))
    parser.add_argument("--build-tools", default="35.0.0")
    parser.add_argument("--gradle", type=Path, default=Path(os.environ.get("GRADLE_BIN", "/tmp/gradle-8.11.1/bin/gradle")))
    args = parser.parse_args()
    os.environ["ANDROID_HOME"] = str(args.sdk)
    os.environ["ANDROID_SDK_ROOT"] = str(args.sdk)
    os.environ.setdefault("JAVA_HOME", "/opt/homebrew/opt/openjdk@17")
    os.environ.setdefault("GRADLE_USER_HOME", "/tmp/explorer-gradle-home")
    signer = args.expected_signer_sha256.lower()
    require(re.fullmatch(r"[a-f0-9]{64}", signer), "Expected signer must be a SHA-256 certificate fingerprint.")
    base, previous, key = [regular(Path(p)) for p in (args.base_apk, args.previous_apk, args.keystore)]
    require(not key.is_relative_to(ROOT.parent.resolve()), "Keep the existing private keystore outside the repository.")
    require(all(os.environ.get(k) for k in ("EXPLORER_KEYSTORE_PASSWORD", "EXPLORER_KEY_PASSWORD")), "Signing password environment variables are required.")
    output = Path(args.output).absolute()
    require(output.suffix == ".apk" and not output.exists() and not output.is_symlink(), "Output must be a new .apk path.")
    require(output.parent.is_dir(), "Output directory must already exist.")
    tools = args.sdk / "build-tools" / args.build_tools
    aapt, signer_tool, align = [regular(tools / name) for name in ("aapt", "apksigner", "zipalign")]
    gradle = regular(args.gradle)
    def inspect(path):
        return metadata(run([aapt, "dump", "badging", path]), run([signer_tool, "verify", "--min-sdk-version", "19", "--verbose", "--print-certs", path]))
    base_hash, previous_hash = digest(base), digest(previous)
    base_info, previous_info = inspect(base), inspect(previous)
    code = version(ROOT / "version.properties")
    validate_update(base_info, previous_info, (PACKAGE, code, 19, signer), signer, code)
    with tempfile.TemporaryDirectory(prefix="explorer-update-") as temporary:
        work = Path(temporary)
        run([gradle, "--no-daemon", "-p", ROOT, "--project-cache-dir", work / "cache", "-PexplorerBuildDir=" + str(work / "build"), ":app:assembleRelease"])
        unsigned = work / "build/outputs/apk/release/app-release-unsigned.apk"
        aligned, signed = work / "aligned.apk", work / "update.apk"
        run([align, "-p", "4", regular(unsigned), aligned])
        run([signer_tool, "sign", "--ks", key, "--ks-key-alias", args.alias,
             "--ks-pass", "env:EXPLORER_KEYSTORE_PASSWORD", "--key-pass", "env:EXPLORER_KEY_PASSWORD",
             "--v1-signing-enabled", "true", "--v2-signing-enabled", "true", "--v3-signing-enabled", "false",
             "--v4-signing-enabled", "false", "--out", signed, aligned], signing=True)
        validate_update(base_info, previous_info, inspect(signed), signer, code)
        require(digest(base) == base_hash and digest(previous) == previous_hash, "Reference APK changed during build.")
        # Publish only a complete copy. Hard-link creation cannot replace an existing path.
        with tempfile.TemporaryDirectory(prefix=".explorer-update-", dir=output.parent) as publishing:
            staged = Path(publishing) / "verified.apk"
            with staged.open("xb") as destination, signed.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    destination.write(block)
                destination.flush()
                os.fsync(destination.fileno())
            require(digest(staged) == digest(signed), "Update copy verification failed.")
            os.link(staged, output)
        print("Verified APK update: " + str(output))
        print("versionCode=" + str(code) + " sha256=" + digest(output))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
