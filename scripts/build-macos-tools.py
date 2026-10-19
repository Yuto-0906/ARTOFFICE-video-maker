#!/usr/bin/env python3
"""Build pinned, native macOS FFmpeg tools with no third-party dylib dependencies."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "tools.macos.lock.json").read_text(encoding="utf-8"))
COMMON = json.loads((ROOT / "tools.lock.json").read_text(encoding="utf-8"))
CACHE = ROOT / ".tool-cache" / "macos-sources"


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(artifact: dict) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    destination = CACHE / artifact["fileName"]
    expected = artifact["sha256"].lower()
    if destination.is_file() and sha256(destination) == expected:
        return destination
    partial = destination.with_name(destination.name + ".partial")
    for attempt in range(4):
        try:
            request = urllib.request.Request(artifact["url"], headers={"User-Agent": "ARTOFFICE-build/0.4"})
            with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output)
            if sha256(partial) != expected:
                raise ValueError(f"SHA-256 mismatch: {artifact['fileName']}")
            partial.replace(destination)
            return destination
        except Exception:
            partial.unlink(missing_ok=True)
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def run(*args: str | Path, cwd: Path, env: dict | None = None) -> None:
    command = [str(arg) for arg in args]
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")
    roots = [path for path in destination.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise ValueError(f"Unexpected source layout: {archive.name}")
    return roots[0]


def verify_binary(binary: Path, architecture: str) -> None:
    actual = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if actual != architecture:
        raise ValueError(f"Unexpected architecture for {binary}: {actual}")
    linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    for line in linked.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency and not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise ValueError(f"Non-system dylib dependency in {binary}: {dependency}")
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True).splitlines()
    minimums = []
    for line in commands:
        tokens = line.split()
        if tokens and tokens[0] in ("minos", "version") and len(tokens) == 2:
            # "version" is used by LC_VERSION_MIN_MACOSX on older toolchains.
            try:
                minimums.append(tuple(int(part) for part in tokens[1].split(".")))
            except ValueError:
                pass
    if not minimums or any(value > (15, 0, 0) for value in minimums):
        raise ValueError(f"Unexpected minimum macOS version for {binary}: {minimums}")


def prepare_fonts(destination: Path) -> None:
    font = COMMON["notoSansJp"]
    source = fetch(font)
    license_file = fetch({
        "fileName": font["licenseFileName"], "url": font["licenseUrl"],
        "sha256": font["licenseSha256"],
    })
    fonts = destination / "resources" / "fonts"
    licenses = destination / "licenses"
    fonts.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    generated = fonts / "NotoSansJP-Black.ttf"
    import fontTools
    if fontTools.__version__ != COMMON["buildDependencies"]["fontToolsVersion"]:
        raise ValueError("Install the fontTools version recorded in tools.lock.json")
    run(sys.executable, "-m", "fontTools.varLib.instancer", source, "wght=900",
        "--update-name-table", "--no-recalc-timestamp", "--output", generated, cwd=ROOT)
    if sha256(generated) != font["generatedBlackSha256"].lower():
        raise ValueError("Generated Noto Sans JP Black SHA-256 mismatch")
    shutil.copy2(license_file, licenses / font["licenseFileName"])


def source_package() -> Path:
    artifacts = ROOT / "artifacts"
    artifacts.mkdir(exist_ok=True)
    version = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))["version"]
    archive = artifacts / f"ARTOFFICE-video-maker-v{version}-macos-sources.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        for name, artifact in LOCK["sources"].items():
            output.add(fetch(artifact), arcname=f"sources/{artifact['fileName']}")
        output.add(fetch(COMMON["notoSansJp"]), arcname=f"sources/{COMMON['notoSansJp']['fileName']}")
        for name in ("tools.macos.lock.json", "tools.lock.json", "THIRD_PARTY_NOTICES.md",
                     "scripts/build-macos-tools.py", "docs/MAC_BUILD_AND_SIGNING.md"):
            output.add(ROOT / name, arcname=name)
    archive.with_name(archive.name + ".sha256").write_text(
        f"{sha256(archive)}  {archive.name}\n", encoding="ascii"
    )
    return archive


def build(architecture: str) -> None:
    if sys.platform != "darwin" or platform.machine() != architecture:
        raise ValueError("Run this script on a native macOS runner of the selected architecture")
    target = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}[architecture]
    digest = hashlib.sha256((ROOT / "tools.macos.lock.json").read_bytes()
                            + Path(__file__).read_bytes()).hexdigest()[:20]
    runtime = ROOT / ".tool-cache" / "macos-runtime" / f"{architecture}-{digest}"
    if not (runtime / "complete.json").exists():
        runtime.mkdir(parents=True, exist_ok=True)
        work_parent = ROOT / ".tool-cache" / "macos-work"
        work_parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"{architecture}-", dir=work_parent) as temporary:
            work = Path(temporary)
            prefix = work / "prefix"
            env = os.environ.copy()
            env.update({
                "MACOSX_DEPLOYMENT_TARGET": LOCK["minimumMacOSVersion"],
                "CC": "clang", "CXX": "clang++",
                "CFLAGS": "-O2 -mmacosx-version-min=15.0",
                "CXXFLAGS": "-O2 -mmacosx-version-min=15.0",
                "LDFLAGS": "-mmacosx-version-min=15.0",
                "PATH": str(prefix / "bin") + os.pathsep + os.environ["PATH"],
                "PKG_CONFIG_PATH": str(prefix / "lib" / "pkgconfig"),
                "PKG_CONFIG_LIBDIR": str(prefix / "lib" / "pkgconfig"),
            })
            jobs = str(min(os.cpu_count() or 2, 6))
            sources = {name: extract(fetch(artifact), work / name)
                       for name, artifact in LOCK["sources"].items()}
            if architecture == "x86_64":
                run("./configure", f"--prefix={prefix}", cwd=sources["nasm"], env=env)
                run("make", f"-j{jobs}", cwd=sources["nasm"], env=env)
                run("make", "install", cwd=sources["nasm"], env=env)
            if "pkgconf" in sources:
                run("./configure", f"--prefix={prefix}", "--disable-shared", "--enable-static",
                    cwd=sources["pkgconf"], env=env)
                run("make", f"-j{jobs}", cwd=sources["pkgconf"], env=env)
                run("make", "install", cwd=sources["pkgconf"], env=env)
                if not (prefix / "bin" / "pkg-config").exists():
                    (prefix / "bin" / "pkg-config").symlink_to("pkgconf")
            run("./configure", f"--prefix={prefix}", "--enable-static", "--disable-cli",
                "--enable-pic", "--disable-opencl", "--bit-depth=8", "--chroma-format=420",
                cwd=sources["x264"], env=env)
            run("make", f"-j{jobs}", cwd=sources["x264"], env=env)
            run("make", "install", cwd=sources["x264"], env=env)
            run("./configure", f"--prefix={prefix}", "--disable-shared", "--enable-static",
                "--with-harfbuzz=no", "--with-bzip2=no", "--with-png=no", "--with-brotli=no",
                "--with-zlib=no", cwd=sources["freetype"], env=env)
            run("make", f"-j{jobs}", cwd=sources["freetype"], env=env)
            run("make", "install", cwd=sources["freetype"], env=env)
            hb_build = work / "harfbuzz-build"
            run("meson", "setup", hb_build, sources["harfbuzz"], f"--prefix={prefix}",
                "--libdir=lib", "--buildtype=release", "--default-library=static",
                "--wrap-mode=nodownload", "-Dauto_features=disabled", "-Dfreetype=enabled",
                "-Dtests=disabled", "-Dutilities=disabled", "-Ddocs=disabled",
                "-Dintrospection=disabled", "-Dsubset=disabled", "-Draster=disabled",
                "-Dvector=disabled", "-Dgpu=disabled", cwd=work, env=env)
            run("meson", "compile", "-C", hb_build, "-j", jobs, cwd=work, env=env)
            run("meson", "install", "-C", hb_build, cwd=work, env=env)
            run("./configure", f"--prefix={prefix}", "--target-os=darwin",
                f"--arch={architecture}", "--enable-gpl", "--enable-version3",
                "--disable-autodetect", "--disable-shared", "--enable-static",
                "--disable-debug", "--disable-doc", "--disable-ffplay",
                "--enable-libx264", "--enable-libfreetype", "--enable-libharfbuzz",
                "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-zlib",
                "--pkg-config-flags=--static", f"--extra-cflags=-I{prefix / 'include'}",
                f"--extra-ldflags=-L{prefix / 'lib'} -lc++",
                cwd=sources["ffmpeg"], env=env)
            run("make", f"-j{jobs}", "ffmpeg", "ffprobe", cwd=sources["ffmpeg"], env=env)
            for name in ("ffmpeg", "ffprobe"):
                shutil.copy2(sources["ffmpeg"] / name, runtime / name)
            licenses = runtime / "licenses"
            licenses.mkdir(exist_ok=True)
            for name, source_file in (("FFmpeg-GPL-3.0.txt", sources["ffmpeg"] / "COPYING.GPLv3"),
                                      ("x264-COPYING.txt", sources["x264"] / "COPYING"),
                                      ("FreeType-FTL.txt", sources["freetype"] / "docs" / "FTL.TXT"),
                                      ("HarfBuzz-COPYING.txt", sources["harfbuzz"] / "COPYING")):
                shutil.copy2(source_file, licenses / name)
            shutil.copy2(sources["ffmpeg"] / "config.h", runtime / "ffmpeg-config.h")
            shutil.copy2(sources["ffmpeg"] / "ffbuild" / "config.mak", runtime / "ffmpeg-config.mak")
            for name in ("ffmpeg", "ffprobe"):
                verify_binary(runtime / name, architecture)
            (runtime / "complete.json").write_text(json.dumps({
                "architecture": architecture, "target": target,
                "minimumMacOSVersion": LOCK["minimumMacOSVersion"], "sourceLock": digest,
            }, indent=2) + "\n", encoding="utf-8")
    destination = ROOT / "vendor-tools"
    binaries = ROOT / "src-tauri" / "binaries"
    (destination / "ffmpeg" / "bin").mkdir(parents=True, exist_ok=True)
    binaries.mkdir(parents=True, exist_ok=True)
    for name in ("ffmpeg", "ffprobe"):
        verify_binary(runtime / name, architecture)
        shutil.copy2(runtime / name, destination / "ffmpeg" / "bin" / name)
        shutil.copy2(runtime / name, binaries / f"{name}-{target}")
    shutil.copytree(runtime / "licenses", destination / "licenses", dirs_exist_ok=True)
    prepare_fonts(destination)
    shutil.copy2(ROOT / "tools.macos.lock.json", destination / "tools.macos.lock.json")
    print(f"Native macOS tools ready: {target}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"))
    parser.add_argument("--sources-only", action="store_true")
    options = parser.parse_args()
    if options.sources_only:
        print(source_package())
    elif options.arch:
        build(options.arch)
    else:
        parser.error("--arch or --sources-only is required")


if __name__ == "__main__":
    main()
