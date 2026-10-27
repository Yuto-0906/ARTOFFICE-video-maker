"""Adapt Azure Secure files to the existing isolated signing process."""
from __future__ import annotations

import base64
import os
from pathlib import Path
import subprocess


def main() -> None:
    environment = os.environ.copy()
    for source, target in (
        ("ARTOFFICE_P12_FILE", "ARTOFFICE_DEVELOPMENT_P12_BASE64"),
        ("ARTOFFICE_PROFILE_FILE", "ARTOFFICE_APP_PROFILE_BASE64"),
    ):
        path = environment.get(source)
        if not path or not Path(path).is_file():
            raise SystemExit("Configure the ARTOFFICE Azure Secure files: " + source)
        environment[target] = base64.b64encode(Path(path).read_bytes()).decode("ascii")
    if not environment.get("ARTOFFICE_DEVELOPMENT_P12_PASSWORD"):
        raise SystemExit("Configure the secret password in artoffice-ios-signing")
    # DownloadSecureFile only downloads. sign.py owns the single temporary keychain,
    # profile validation, installation and cleanup; do not import the identity twice.
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(["bash", "scripts/ios/ci.sh", "device"], cwd=root, env=environment)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
