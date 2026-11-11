"""Codemagic manual development signing. Never prints keys，passwords or device IDs."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import tempfile

BUNDLE = "com.yuto0906.artoffice-video-maker.ios"
ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "ios" / "build"
NAMES = ("ARTOFFICE_DEVELOPMENT_P12_BASE64", "ARTOFFICE_DEVELOPMENT_P12_PASSWORD", "ARTOFFICE_APP_PROFILE_BASE64")


def run(args: list[str], *, data: bytes | None = None) -> bytes:
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        error = result.stderr.decode(errors="replace")
        for name in NAMES:
            value = os.environ.get(name)
            if value:
                error = error.replace(value, "<redacted>")
        raise RuntimeError(f"{pathlib.Path(args[0]).name} failed: {error[:2500]}")
    return result.stdout


def main() -> None:
    missing = [name for name in NAMES if not os.environ.get(name)]
    if missing:
        raise SystemExit("Configure the artoffice_ios_signing secret group: " + ", ".join(missing))
    BUILD.mkdir(parents=True, exist_ok=True)
    prior = shlex.split(run(["security", "list-keychains", "-d", "user"]).decode())
    installed: list[pathlib.Path] = []
    with tempfile.TemporaryDirectory(prefix="artoffice-signing-") as work:
        temp = pathlib.Path(work)
        p12 = temp / "development.p12"
        profile_file = temp / "app.mobileprovision"
        p12.write_bytes(base64.b64decode(os.environ[NAMES[0]], validate=True))
        profile_file.write_bytes(base64.b64decode(os.environ[NAMES[2]], validate=True))
        p12.chmod(0o600)
        profile_file.chmod(0o600)
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(profile_file)]))
        entitlement = profile["Entitlements"]
        prefix = profile["ApplicationIdentifierPrefix"][0]
        team = profile["TeamIdentifier"][0]
        if entitlement.get("application-identifier") != prefix + "." + BUNDLE:
            raise SystemExit("The provisioning profile does not match this app's explicit Bundle ID")
        if entitlement.get("get-task-allow") is not True or not profile.get("ProvisionedDevices"):
            raise SystemExit("Use an iOS App Development profile with registered test devices")
        expires = profile["ExpirationDate"].replace(tzinfo=dt.timezone.utc)
        if expires <= dt.datetime.now(dt.timezone.utc):
            raise SystemExit("The provisioning profile has expired")
        keychain = temp / "signing.keychain-db"
        keychain_password = secrets.token_urlsafe(32)
        try:
            run(["security", "create-keychain", "-p", keychain_password, str(keychain)])
            run(["security", "set-keychain-settings", "-lut", "14400", str(keychain)])
            run(["security", "unlock-keychain", "-p", keychain_password, str(keychain)])
            run(["security", "import", str(p12), "-k", str(keychain), "-P", os.environ[NAMES[1]], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, str(keychain)])
            run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *prior])
            identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)]).decode()
            matching = [(hashlib.sha1(cert).hexdigest().upper(), cert) for cert in profile["DeveloperCertificates"]]
            certificate = next(((sha, cert) for sha, cert in matching if sha in identities), None)
            if certificate is None:
                raise SystemExit("The profile does not contain the imported signing certificate")
            identity, certificate_der = certificate
            certificate_expires = run(["openssl", "x509", "-inform", "DER", "-noout", "-enddate"], data=certificate_der).decode().strip()
            for parent in [pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
                           pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]:
                parent.mkdir(parents=True, exist_ok=True)
                target = parent / (profile["UUID"] + ".mobileprovision")
                if target.exists() and target.read_bytes() != profile_file.read_bytes():
                    raise SystemExit("A different profile already occupies this UUID")
                if not target.exists():
                    shutil.copyfile(profile_file, target)
                    installed.append(target)
            args = ["xcodebuild", "-project", "ios/ARTOFFICE.xcodeproj", "-scheme", "ARTOFFICE", "-configuration", "Release",
                    "-destination", "generic/platform=iOS", "-derivedDataPath", "ios/build/signed",
                    "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=" + team, "CODE_SIGN_IDENTITY=" + identity,
                    "PROVISIONING_PROFILE_SPECIFIER=" + profile["UUID"], "build"]
            with (BUILD / "signed-build.log").open("wb") as log:
                result = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise SystemExit("Signed build failed; inspect signed-build.log")
            app = BUILD / "signed/Build/Products/Release-iphoneos/ARTOFFICE.app"
            run(["codesign", "--verify", "--deep", "--strict", str(app)])
            info = plistlib.loads((app / "Info.plist").read_bytes())
            if info["CFBundleIdentifier"] != BUNDLE or info["CFBundleSupportedPlatforms"] != ["iPhoneOS"]:
                raise SystemExit("Built app is not the expected physical-device application")
            for icons_key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                if info.get(icons_key, {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") != "AppIcon":
                    raise SystemExit("The built app is missing its iPhone or iPad icon")
            for resource in ("Assets.car", "PrivacyInfo.xcprivacy"):
                if not (app / resource).is_file() or (app / resource).stat().st_size == 0:
                    raise SystemExit("The built app is missing a required resource: " + resource)
            embedded = plistlib.loads(run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]))
            if embedded["UUID"] != profile["UUID"]:
                raise SystemExit("Embedded profile mismatch")
            signed = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)]))
            if signed.get("application-identifier") != prefix + "." + BUNDLE or signed.get("get-task-allow") is not True:
                raise SystemExit("Signed app entitlements mismatch")
            payload = temp / "Payload"
            payload.mkdir()
            run(["ditto", str(app), str(payload / app.name)])
            ipa = BUILD / "ARTOFFICE-ios-development.ipa"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(ipa)])
            report = {"bundleId": BUNDLE, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "platform": "iPhoneOS",
                      "profileExpires": expires.isoformat(), "certificateExpires": certificate_expires,
                      "registeredDeviceCount": len(profile["ProvisionedDevices"]), "codesignVerified": True,
                      "appIconVerified": True, "assetCatalogVerified": True,
                      "revision": run(["git", "rev-parse", "HEAD"]).decode().strip()}
            (BUILD / "signing-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print("Development IPA created and its signature verified")
        finally:
            run(["security", "list-keychains", "-d", "user", "-s", *prior])
            subprocess.run(["security", "delete-keychain", str(keychain)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for target in installed:
                target.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
