#!/usr/bin/env python3
"""Build, relocate, verify and optionally notarize a macOS DMG."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tools = load_module("macos_build_tools", "build-macos-tools.py")
signing = load_module("macos_signing", "macos-signing.py")


def checked(args: list[str], env: dict | None = None) -> str:
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True)
    if result.returncode:
        # Command arguments may contain notarization credentials; never print them.
        raise RuntimeError(signing.redact(f"{Path(args[0]).name} failed:\n{result.stdout}\n{result.stderr}"))
    return result.stdout


def apple_ticket_check(args: list[str]) -> str:
    for attempt in range(4):
        try:
            return checked(args)
        except RuntimeError as error:
            transient = any(message in str(error).lower() for message in (
                "network connection", "cloudkit", "timed out", "temporarily", "error 68",
                "could not validate ticket",
            ))
            if not transient or attempt == 3:
                raise
            print(f"Apple ticket service connection failed; retry {attempt + 1}/3", flush=True)
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def notarize_dmg(dmg: Path) -> None:
    checked(["codesign", "--force", "--sign", os.environ["APPLE_SIGNING_IDENTITY"],
             "--timestamp", str(dmg)])
    result = checked([
        "xcrun", "notarytool", "submit", str(dmg), "--apple-id", os.environ["APPLE_ID"],
        "--password", os.environ["APPLE_PASSWORD"], "--team-id", os.environ["APPLE_TEAM_ID"],
        "--wait", "--timeout", "60m", "--output-format", "json",
    ])
    response = json.loads(result)
    if response.get("status") != "Accepted":
        raise RuntimeError(f"DMG notarization failed: {response.get('status')} ({response.get('id')})")
    apple_ticket_check(["xcrun", "stapler", "staple", str(dmg)])
    apple_ticket_check(["xcrun", "stapler", "validate", str(dmg)])
    checked(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(dmg)])


def create_disk_image(application: Path, dmg: Path) -> None:
    dmg.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ARTOFFICE DMG payload ") as temporary:
        payload = Path(temporary)
        checked(["ditto", str(application), str(payload / application.name)])
        (payload / "Applications").symlink_to("/Applications")
        checked(["hdiutil", "create", "-ov", "-format", "UDZO", "-volname", "ARTOFFICE",
                 "-srcfolder", str(payload), str(dmg)])
    checked(["hdiutil", "verify", str(dmg)])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("aarch64-apple-darwin", "x86_64-apple-darwin"), required=True)
    parser.add_argument("--signed", action="store_true")
    options = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("macOS packaging requires a macOS runner")
    architecture = "arm64" if options.target.startswith("aarch64") else "x86_64"
    label = "arm64" if architecture == "arm64" else "x64"
    env = os.environ.copy()
    if not options.signed:
        env = {key: value for key, value in env.items() if not key.startswith("APPLE_")}
        env["APPLE_SIGNING_IDENTITY"] = "-"
    result = subprocess.run(["npm", "run", "tauri", "--", "build", "--target", options.target,
                             "--bundles", "app"], cwd=ROOT, env=env)
    if result.returncode:
        raise RuntimeError("Tauri macOS build failed")
    bundle = ROOT / "src-tauri" / "target" / options.target / "release" / "bundle"
    applications = list((bundle / "macos").glob("*.app"))
    if len(applications) != 1:
        raise RuntimeError("Expected exactly one .app")
    application = applications[0]
    dmg = bundle / "dmg" / f"ARTOFFICE-macos-{label}.dmg"
    for executable in (application / "Contents" / "MacOS").iterdir():
        if executable.is_file():
            tools.verify_binary(executable, architecture)
    checked(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(application)])
    if options.signed:
        # Tauri's notarization can finish before a successful staple. Complete
        # and verify it explicitly before copying the app into the disk image.
        apple_ticket_check(["xcrun", "stapler", "staple", str(application)])
        apple_ticket_check(["xcrun", "stapler", "validate", str(application)])
        checked(["spctl", "--assess", "--type", "execute", str(application)])
    create_disk_image(application, dmg)
    if options.signed:
        notarize_dmg(dmg)
    with tempfile.TemporaryDirectory(prefix="ARTOFFICE 移動後 ") as temporary:
        root = Path(temporary)
        moved = root / application.name
        mount = root / "DMG"
        mount.mkdir()
        checked(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)])
        try:
            contained = mount / application.name
            checked(["codesign", "--verify", "--deep", "--strict", str(contained)])
            if options.signed:
                apple_ticket_check(["xcrun", "stapler", "validate", str(contained)])
            checked(["ditto", str(contained), str(moved)])
            clean_env = {key: value for key, value in os.environ.items()
                         if not key.startswith(("AOV_", "DYLD_", "APPLE_"))}
            clean_env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "AOV_BUNDLED_ONLY": "1"})
            output = checked([str(moved / "Contents" / "MacOS" / "artoffice-video-maker"),
                              "--verify-runtime", str(root / "検証結果")], env=clean_env)
            report = json.loads(output.strip().splitlines()[-1])
            if report["status"] != "passed":
                raise RuntimeError("Relocated runtime check failed")
            for name in ("ffmpeg", "ffprobe", "font"):
                if not Path(report[name]).is_relative_to(moved):
                    raise RuntimeError(f"Runtime check used a dependency outside the app: {name}")
            checked(["codesign", "--verify", "--deep", "--strict", str(moved)])
            if options.signed:
                apple_ticket_check(["xcrun", "stapler", "validate", str(moved)])
                checked(["spctl", "--assess", "--type", "execute", str(moved)])
        finally:
            checked(["hdiutil", "detach", str(mount)])
    version = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))["version"]
    artifacts = ROOT / "artifacts"
    artifacts.mkdir(exist_ok=True)
    destination = artifacts / f"ARTOFFICE-video-maker-v{version}-macos-{label}.dmg"
    shutil.copy2(dmg, destination)
    destination.with_name(destination.name + ".sha256").write_text(
        f"{tools.sha256(destination)}  {destination.name}\n", encoding="ascii"
    )
    (artifacts / f"macos-{label}-verification.json").write_text(json.dumps({
        **report, "architecture": architecture, "signedAndNotarized": options.signed,
        "dmgContentsVerified": True,
        "guiVerified": False, "physicalHardwareAccelerationVerified": False,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified DMG: {destination.name}; signed/notarized={options.signed}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(signing.redact(str(error)), file=sys.stderr)
        sys.exit(1)
