"""Adapt Azure Secure files to the existing isolated signing process."""
from __future__ import annotations

import base64
import os
from pathlib import Path
import subprocess


def main() -> None:
    environment = os.environ.copy()
    if environment.get("TF_BUILD", "").lower() != "true":
        raise SystemExit("Run this adapter only inside an Azure Pipelines agent")
    for source, target in (
        ("ARTOFFICE_P12_FILE", "ARTOFFICE_DEVELOPMENT_P12_BASE64"),
        ("ARTOFFICE_PROFILE_FILE", "ARTOFFICE_APP_PROFILE_BASE64"),
    ):
        path = environment.get(source)
        if not path or not Path(path).is_file():
            raise SystemExit("Configure the ARTOFFICE Azure Secure files: " + source)
        environment[target] = base64.b64encode(Path(path).read_bytes()).decode("ascii")
    password_file = environment.get("ARTOFFICE_PASSWORD_FILE")
    if not password_file or not Path(password_file).is_file():
        raise SystemExit("Configure the protected ARTOFFICE password Secure file")
    password = Path(password_file).read_text(encoding="utf-8")
    if not password:
        raise SystemExit("The protected signing password is empty")
    environment["ARTOFFICE_DEVELOPMENT_P12_PASSWORD"] = password
    # Register through the agent's secret-variable channel before the child can log.
    # This is never executed locally; the Azure agent consumes and masks the value.
    escaped = password.replace("%", "%AZP25").replace("\r", "%0D").replace("\n", "%0A")
    print("##vso[task.setvariable variable=ARTOFFICE_DEVELOPMENT_P12_PASSWORD;issecret=true;isreadonly=true]" + escaped, flush=True)
    # DownloadSecureFile only downloads. sign.py owns the single temporary keychain,
    # profile validation, installation and cleanup; do not import the identity twice.
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(["bash", "scripts/ios/ci.sh", "device"], cwd=root, env=environment)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
