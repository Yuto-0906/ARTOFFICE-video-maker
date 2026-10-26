"""Inspect a development IPA's structure. Cryptographic verification stays on macOS."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import zipfile


def inspect_ipa(path: Path, expected_bundle: str) -> dict:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('IPA contains duplicate ZIP entries')
        entries = set(names)
        hosts = [name for name in names if len(PurePosixPath(name).parts) == 3
                 and name.startswith('Payload/') and name.endswith('.app/Info.plist')]
        if len(hosts) != 1:
            raise ValueError('IPA must contain exactly one Payload/*.app/Info.plist')
        root = hosts[0][:-len('Info.plist')]
        info = plistlib.loads(archive.read(hosts[0]))
        if not isinstance(info, dict):
            raise ValueError('App Info.plist is not a dictionary')
        if info.get('CFBundleIdentifier') != expected_bundle:
            raise ValueError('App Bundle ID does not match the requested app')
        platforms = info.get('CFBundleSupportedPlatforms', [])
        if not isinstance(platforms, list) or 'iPhoneOS' not in platforms:
            raise ValueError('Expected an iPhoneOS device app, not a simulator or other platform')

        def check_component(component_root: str, profile_name: str) -> None:
            component_info = plistlib.loads(archive.read(component_root + 'Info.plist'))
            if not isinstance(component_info, dict):
                raise ValueError('Component Info.plist is not a dictionary')
            executable = component_info.get('CFBundleExecutable')
            if not isinstance(executable, str) or not executable or '/' in executable or '\\' in executable:
                raise ValueError('Component has an invalid executable name')
            for suffix in (executable, '_CodeSignature/CodeResources', profile_name):
                name = component_root + suffix
                if name not in entries or archive.getinfo(name).file_size == 0:
                    raise ValueError(f'Missing or empty component file: {name}')

        check_component(root, 'embedded.mobileprovision')
        extension_counts = {'appex': 0, 'dext': 0}
        for name in names:
            if not name.startswith(root):
                continue
            kind = next((kind for kind in extension_counts if name.endswith(f'.{kind}/Info.plist')), None)
            if kind is None:
                continue
            extension_root = name[:-len('Info.plist')]
            extension_info = plistlib.loads(archive.read(name))
            if not isinstance(extension_info, dict):
                raise ValueError('Extension Info.plist is not a dictionary')
            identifier = extension_info.get('CFBundleIdentifier', '')
            if not isinstance(identifier, str) or not identifier.startswith(expected_bundle + '.'):
                raise ValueError('Extension Bundle ID must begin with the host Bundle ID')
            check_component(extension_root, 'embedded.provisionprofile' if kind == 'dext' else 'embedded.mobileprovision')
            extension_counts[kind] += 1
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {
        'bundleId': expected_bundle,
        'version': info.get('CFBundleShortVersionString'),
        'build': info.get('CFBundleVersion'),
        'minimumOS': info.get('MinimumOSVersion'),
        'appExtensions': extension_counts['appex'],
        'driverExtensions': extension_counts['dext'],
        'sha256': digest,
        'structureVerified': True,
        'cryptographicSignatureVerification': 'Use macOS codesign and on-device validation',
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--bundle', required=True)
    args = parser.parse_args()
    try:
        report = inspect_ipa(args.ipa, args.bundle)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f'IPA structure check failed: {error}\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
