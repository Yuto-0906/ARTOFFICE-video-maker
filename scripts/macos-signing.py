#!/usr/bin/env python3
"""Import a Developer ID certificate into an ephemeral GitHub Actions keychain."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys

REQUIRED = ("APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY",
            "APPLE_ID", "APPLE_PASSWORD", "APPLE_TEAM_ID")
STATE = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "artoffice-signing-state.json"


def redact(text: str) -> str:
    for name in REQUIRED:
        value = os.environ.get(name, "")
        if value:
            text = text.replace(value, "***")
    return text


def secure_run(args: list[str], label: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{label} failed:\n{redact(result.stdout + result.stderr)}")
    return result.stdout


def cleanup() -> None:
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text(encoding="utf-8"))
    try:
        secure_run(["security", "list-keychains", "-d", "user", "-s", *state["original"]],
                   "Restore keychain search list")
    finally:
        keychain = Path(state["keychain"])
        if keychain.exists():
            secure_run(["security", "delete-keychain", str(keychain)], "Delete temporary keychain")
        Path(state["certificate"]).unlink(missing_ok=True)
        STATE.unlink(missing_ok=True)


def prepare() -> None:
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Missing GitHub Secrets: " + ", ".join(missing))
    identity = os.environ["APPLE_SIGNING_IDENTITY"]
    if not identity.startswith("Developer ID Application:"):
        raise RuntimeError("APPLE_SIGNING_IDENTITY must be a Developer ID Application identity")
    if STATE.exists():
        raise RuntimeError("A signing keychain already exists for this job")
    original = shlex.split(secure_run(["security", "list-keychains", "-d", "user"], "List keychains"))
    keychain = STATE.parent / f"artoffice-{secrets.token_hex(10)}.keychain-db"
    certificate = keychain.with_suffix(".p12")
    STATE.write_text(json.dumps({
        "original": original, "keychain": str(keychain), "certificate": str(certificate)
    }), encoding="utf-8")
    STATE.chmod(0o600)
    password = secrets.token_urlsafe(32)
    print(f"::add-mask::{password}", flush=True)
    try:
        descriptor = os.open(certificate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(base64.b64decode(os.environ["APPLE_CERTIFICATE"], validate=True))
        secure_run(["security", "create-keychain", "-p", password, str(keychain)], "Create keychain")
        secure_run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], "Set keychain timeout")
        secure_run(["security", "unlock-keychain", "-p", password, str(keychain)], "Unlock keychain")
        secure_run(["security", "import", str(certificate), "-k", str(keychain),
                    "-P", os.environ["APPLE_CERTIFICATE_PASSWORD"],
                    "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "Import certificate")
        secure_run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                    "-s", "-k", password, str(keychain)], "Allow command-line signing")
        secure_run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *original],
                   "Set keychain search list")
        identities = secure_run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)],
                                "Verify signing identity")
        if f'"{identity}"' not in identities:
            raise RuntimeError("The imported certificate does not match APPLE_SIGNING_IDENTITY")
    except Exception:
        cleanup()
        raise
    finally:
        certificate.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["prepare"]:
            prepare()
        elif sys.argv[1:] == ["cleanup"]:
            cleanup()
        else:
            raise RuntimeError("Usage: macos-signing.py prepare|cleanup")
    except Exception as error:
        print(redact(str(error)), file=sys.stderr)
        sys.exit(1)
