#!/usr/bin/env python3
"""Validate a built Beta bundle and its installer using disposable apps only."""
import base64
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / '.build/Build/Products/Beta/Paste Lite Beta.app'
INSTALLER = ROOT / '.build/install-beta'


def run(*args, succeeds=True):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result.stdout


def snapshot(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob('*') if path.is_file()}


def main():
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.local.PasteLite.beta'
    assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'Paste Lite Beta'
    assert info['CFBundleExecutable'] == 'PasteLite' and info['PasteLiteBuildChannel'] == 'beta'
    assert info['SUFeedURL'] == info['SUPublicEDKey'] == ''
    run('xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', '.build/ModuleCache.noindex', 'scripts/install-beta.swift', '-o', INSTALLER)
    with tempfile.TemporaryDirectory(prefix='beta-installer-', dir=ROOT / '.build') as name:
        root = pathlib.Path(name)
        destination = root / 'Applications/Paste Lite Beta.app'
        # These are synthetic stable files, never the user's installed app or history.
        stable = root / 'Applications/Paste Lite.app'
        stable.mkdir(parents=True)
        (stable / 'sentinel').write_text('Stable app must stay unchanged')
        data = root / 'Library/Application Support/PasteLiteBeta'
        data.mkdir(parents=True)
        (data / 'sentinel').write_text('Beta history survives app replacement')
        stable_before, data_before = snapshot(stable), snapshot(data)
        run(INSTALLER, APP, destination)
        before = snapshot(destination)

        run(INSTALLER, APP, stable, succeeds=False)
        wrong = root / 'Wrong/Paste Lite Beta.app'
        shutil.copytree(APP, wrong, symlinks=True)
        wrong_info = dict(info, CFBundleIdentifier='com.local.PasteLite')
        (wrong / 'Contents/Info.plist').write_bytes(plistlib.dumps(wrong_info))
        run(INSTALLER, wrong, destination, succeeds=False)
        run(INSTALLER, APP, wrong, succeeds=False)
        assert plistlib.loads((wrong / 'Contents/Info.plist').read_bytes()) == wrong_info
        link = root / 'Link/Paste Lite Beta.app'
        link.parent.mkdir()
        link.symlink_to(stable, target_is_directory=True)
        run(INSTALLER, APP, link, succeeds=False)

        replacement = root / 'New/Paste Lite Beta.app'
        shutil.copytree(APP, replacement, symlinks=True)
        marker = replacement / 'Contents/Resources/beta-test-marker'
        marker.write_text('Second local build')
        run(INSTALLER, replacement, destination, succeeds=False)  # Invalid signature.
        assert snapshot(destination) == before
        run('codesign', '--force', '--sign', '-', replacement)
        run(INSTALLER, replacement, destination)
        assert (destination / 'Contents/Resources/beta-test-marker').read_text() == 'Second local build'
        assert snapshot(stable) == stable_before and snapshot(data) == data_before
        assert not list(destination.parent.glob('.paste-lite-beta-*'))
        print('PASS: install and replace Beta; preserve data and stable app; reject stable identities, wrong paths, symlinks and invalid signatures')

        fixture = root / 'Beta Update Check.app'
        executable = fixture / 'Contents/MacOS/BetaUpdateCheck'
        executable.parent.mkdir(parents=True)
        framework = ROOT / '.build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
        run('xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-D', 'BETA',
            '-module-cache-path', ROOT / '.build/ModuleCache.noindex',
            '-F', framework, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', framework,
            'PasteLite/Models/AppVariant.swift', 'PasteLite/Models/PanelShortcut.swift',
            'PasteLite/Services/AppSettings.swift', 'PasteLite/Services/AppUpdateManager.swift',
            'PasteLite/UI/AppUpdateView.swift', 'Tests/BetaUpdateTests.swift', '-o', executable)
        (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='com.local.PasteLite.BetaUpdateCheck', CFBundleExecutable='BetaUpdateCheck',
            CFBundlePackageType='APPL', LSUIElement=True,
            SUPublicEDKey=base64.b64encode(bytes(range(32))).decode(),
            SUFeedURL='https://example.invalid/appcast.xml')))
        print(run(executable).strip())

        fixture = root / 'Beta Termination Check.app'
        executable = fixture / 'Contents/MacOS/BetaTerminationCheck'
        executable.parent.mkdir(parents=True)
        harness = root / 'BetaTerminationCheck.swift'
        harness.write_text((ROOT / 'PasteLite/App/AppDelegate.swift').read_text() + '\n'
                           + (ROOT / 'Tests/BetaTerminationTests.swift').read_text())
        sources = sorted((ROOT / 'PasteLite/Models').glob('*.swift'))
        sources += sorted((ROOT / 'PasteLite/Services').glob('*.swift'))
        sources += sorted((ROOT / 'PasteLite/UI').glob('*.swift'))
        run('xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-D', 'BETA',
            '-module-name', 'PasteLiteBetaTerminationTests',
            '-module-cache-path', ROOT / '.build/ModuleCache.noindex',
            '-F', framework, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', framework,
            *sources, ROOT / 'Tests/Performance/Fixtures.swift', harness, '-o', executable)
        (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='com.local.PasteLite.BetaTerminationCheck', CFBundleExecutable='BetaTerminationCheck',
            CFBundlePackageType='APPL', LSUIElement=True)))
        print(run(executable).strip())


if __name__ == '__main__':
    main()
