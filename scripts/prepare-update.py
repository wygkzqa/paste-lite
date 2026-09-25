#!/usr/bin/env python3
"""Prepare a signed Sparkle feed for an existing, immutable Universal DMG."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ROOT = Path(__file__).resolve().parent.parent


def run(command, *, key=None):
    result = subprocess.run([str(part) for part in command], input=key, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Signing tools receive the private key through stdin. Never echo their inputs or output.
        raise ValueError(f'{Path(command[0]).name} failed (exit {result.returncode}).')
    return result.stdout.strip()


def prepare(args):
    directory = args.package_directory.resolve()
    if (directory / 'appcast.xml').exists():
        raise ValueError('Refusing to replace an existing appcast.')
    packages = list(directory.glob('*.dmg'))
    if len(packages) != 1:
        raise ValueError('Expected exactly one DMG.')
    package = packages[0]
    key = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
    if not key:
        raise ValueError('SPARKLE_PRIVATE_KEY is required.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        raise ValueError('Invalid repository name.')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
        raise ValueError('Expected a stable vX.Y.Z tag.')
    sign = args.sparkle_bin.resolve() / 'sign_update'
    generate = args.sparkle_bin.resolve() / 'generate_appcast'
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    expected = f'{digest}  {package.name}'
    if expected not in (directory / 'SHA256SUMS.txt').read_text().splitlines():
        raise ValueError('DMG checksum mismatch.')

    with tempfile.TemporaryDirectory(prefix='paste-lite-update-') as temporary:
        temporary = Path(temporary)
        mount = temporary / 'mount'
        mount.mkdir()
        run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, package])
        try:
            apps = list(mount.glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Expected exactly one application in the DMG.')
            run(['codesign', '--verify', '--deep', '--strict', apps[0]])
            info = plistlib.loads((apps[0] / 'Contents/Info.plist').read_bytes())
            run(['lipo', apps[0] / 'Contents/MacOS' / info['CFBundleExecutable'], '-verify_arch', 'arm64', 'x86_64'])
        finally:
            run(['hdiutil', 'detach', mount])

        if info['CFBundleIdentifier'] != args.bundle_id:
            raise ValueError('Unexpected application identity.')
        version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
        if args.tag != f'v{version}' or package.name != f'Paste-Lite-{version}-universal.dmg':
            raise ValueError('Tag, application version and package name must match.')
        if not re.fullmatch(r'[1-9]\d*', build):
            raise ValueError('Expected a positive integer build number.')
        public_key = info.get('SUPublicEDKey', '')
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError('The application must embed its public update key.')
        feed_url = f'https://github.com/{args.repository}/releases/latest/download/appcast.xml'
        if info.get('SUFeedURL') != feed_url:
            raise ValueError('Unexpected production update feed URL.')
        for name in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
            if info.get(name) is not True:
                raise ValueError(f'{name} must be enabled.')
        for name in ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling']:
            if info.get(name) is not False:
                raise ValueError(f'{name} must be disabled by default.')

        signature = run([sign, '--ed-key-file', '-', '-p', package], key=key)
        run(['xcrun', 'swift', '-module-cache-path', ROOT / '.build/ModuleCache.noindex',
             ROOT / 'scripts/verify-update-signature.swift', public_key, package, signature])

        stage = temporary / 'updates'
        stage.mkdir()
        previous_builds = set()
        if args.previous_appcast:
            previous = args.previous_appcast.resolve()
            run([sign, '--ed-key-file', '-', '--verify', previous], key=key)
            previous_tree = ET.parse(previous)
            for item in previous_tree.findall('./channel/item'):
                old_build = item.findtext(SPARKLE + 'version')
                if not old_build or not old_build.isdecimal():
                    raise ValueError('Invalid build number in previous appcast.')
                previous_builds.add(old_build)
            if not previous_builds or int(build) <= max(map(int, previous_builds)):
                raise ValueError('The build number must increase beyond every previous release.')
            shutil.copyfile(previous, stage / 'appcast.xml')

        shutil.copyfile(package, stage / package.name)
        notes = []
        for filename, language in [('CHANGELOG.md', 'English'), ('CHANGELOG.zh-CN.md', '简体中文')]:
            changelog = (args.changelog_directory / filename).read_text()
            match = re.search(r'^## \[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^## |\Z)',
                              changelog, re.MULTILINE | re.DOTALL)
            if not match or not match[1].strip():
                raise ValueError(f'Missing release notes in {filename}.')
            notes.append(language + '\n\n' + match[1].strip())
        (stage / package.with_suffix('.txt').name).write_text('\n\n'.join(notes))
        run([generate, '--ed-key-file', '-', '--maximum-deltas', '0', '--maximum-versions', '0',
             '--versions', build, '--embed-release-notes',
             '--download-url-prefix', f'https://github.com/{args.repository}/releases/download/{args.tag}/',
             '--link', f'https://github.com/{args.repository}/releases/tag/{args.tag}', stage], key=key)
        feed = stage / 'appcast.xml'
        run([sign, '--ed-key-file', '-', '--verify', feed], key=key)
        items = ET.parse(feed).findall('./channel/item')
        builds = [item.findtext(SPARKLE + 'version') for item in items]
        if builds.count(build) != 1 or not previous_builds.issubset(builds):
            raise ValueError('Generated appcast lost previous versions or duplicated this build.')
        item = next(item for item in items if item.findtext(SPARKLE + 'version') == build)
        enclosure = item.find('enclosure')
        expected_url = f'https://github.com/{args.repository}/releases/download/{args.tag}/{package.name}'
        if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(package.stat().st_size):
            raise ValueError('Generated appcast does not match the verified package.')
        if item.findtext(SPARKLE + 'shortVersionString') != version:
            raise ValueError('Generated display version does not match the application.')
        if hashlib.sha256(package.read_bytes()).hexdigest() != digest:
            raise ValueError('The verified DMG changed during feed generation.')
        shutil.copyfile(feed, directory / 'appcast.xml')
        feed_digest = hashlib.sha256(feed.read_bytes()).hexdigest()
        (directory / 'SHA256SUMS.txt').write_text(expected + f'\n{feed_digest}  appcast.xml\n')
    print('Verified DMG signature, application key, increasing build number and signed appcast.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-directory', required=True, type=Path)
    parser.add_argument('--sparkle-bin', required=True, type=Path)
    parser.add_argument('--repository', default='wygkzqa/paste-lite')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--bundle-id', default='com.local.PasteLite')
    parser.add_argument('--changelog-directory', type=Path, default=ROOT)
    history = parser.add_mutually_exclusive_group(required=True)
    history.add_argument('--previous-appcast', type=Path)
    history.add_argument('--initialize', action='store_true')
    try:
        prepare(parser.parse_args())
    except (ValueError, OSError, ET.ParseError, KeyError) as error:
        raise SystemExit(str(error)) from None
