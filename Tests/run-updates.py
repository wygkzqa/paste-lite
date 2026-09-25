#!/usr/bin/env python3
"""Run real Sparkle updates using disposable apps, keys, preferences and a loopback feed."""
import argparse
from functools import partial
import http.server
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, capture_output=True, text=True, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sparkle-directory', type=Path, required=True,
                        help='Extracted official SPM archive containing bin and Sparkle.xcframework')
    args = parser.parse_args()
    sparkle = args.sparkle_directory.resolve()
    framework = sparkle / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    sign = sparkle / 'bin/sign_update'
    (ROOT / '.build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='update-tests-', dir=ROOT / '.build') as temporary:
        root = Path(temporary)
        key_source = root / 'Key.swift'
        key_source.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("private-key"), atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("private-key").path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public-key"), atomically: true, encoding: .utf8)
''')
        run(['xcrun', 'swift', '-module-cache-path', ROOT / '.build/ModuleCache.noindex', key_source, root])
        key, public = (root / 'private-key').read_text(), (root / 'public-key').read_text()
        executable = root / 'UpdateTest'
        run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-D', 'UPDATE_TESTING',
             '-module-cache-path', ROOT / '.build/ModuleCache.noindex', '-F', framework.parent,
             '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
             ROOT / 'PasteLite/Services/AppSettings.swift', ROOT / 'PasteLite/Services/AppUpdateManager.swift',
             ROOT / 'PasteLite/UI/AppUpdateView.swift', ROOT / 'PasteLite/UI/AboutView.swift',
             ROOT / 'Tests/AppUpdateHarness.swift', '-o', executable])
        server_root = root / 'server'
        server_root.mkdir()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(server_root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            for mode in ['update', 'cancel', 'quit', 'no-update', 'bad-archive', 'bad-feed']:
                identifier = 'com.local.PasteLite.UpdateTests.' + uuid.uuid4().hex
                case = root / mode
                result = case / 'result.txt'
                installed = case / 'installed/Paste Lite Update Tests.app'
                target = case / 'new/Paste Lite Update Tests.app'
                try:
                    for app, build in [(installed, '20'), (target, '21')]:
                        (app / 'Contents/MacOS').mkdir(parents=True)
                        (app / 'Contents/Resources').mkdir()
                        shutil.copy2(executable, app / 'Contents/MacOS/UpdateTest')
                        shutil.copytree(framework, app / 'Contents/Frameworks/Sparkle.framework', symlinks=True)
                        for language in ['en', 'zh-Hans']:
                            shutil.copytree(ROOT / 'PasteLite/Resources' / f'{language}.lproj', app / 'Contents/Resources' / f'{language}.lproj')
                        info = dict(CFBundleIdentifier=identifier, CFBundleName='Paste Lite Update Tests', CFBundleExecutable='UpdateTest',
                                    CFBundlePackageType='APPL', CFBundleVersion=build, CFBundleShortVersionString='1.0.2',
                                    LSMinimumSystemVersion='14.0', LSUIElement=True, SUPublicEDKey=public, SUFeedURL=base + '/appcast.xml',
                                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                                    SUEnableSystemProfiling=False, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                                    UpdateTestMode='error' if mode.startswith('bad-') else mode, UpdateTestResult=str(result),
                                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
                        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                        run(['codesign', '--force', '--sign', '-', app / 'Contents/Frameworks/Sparkle.framework'])
                        run(['codesign', '--force', '--sign', '-', app])
                    archive = server_root / 'update.dmg'
                    archive.unlink(missing_ok=True)
                    run(['hdiutil', 'create', '-quiet', '-volname', 'Paste Lite Update Tests',
                         '-srcfolder', target.parent, '-format', 'UDZO', archive])
                    signature = run([sign, '--ed-key-file', '-', '-p', archive], input=key).stdout.strip()
                    feed = server_root / 'appcast.xml'
                    build = '19' if mode == 'no-update' else '21'
                    feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated Update Test</title><item><title>Test update</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>1.0.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion><description sparkle:format="plain-text">Synthetic release notes.</description><enclosure url="{base}/update.dmg" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>''')
                    run([sign, '--ed-key-file', '-', feed], input=key)
                    if mode == 'bad-feed':
                        feed.write_text(feed.read_text().replace('Synthetic release notes.', 'Tampered release notes.'))
                    if mode == 'bad-archive':
                        with archive.open('r+b') as handle:
                            handle.seek(-1, os.SEEK_END)
                            value = handle.read(1)[0]
                            handle.seek(-1, os.SEEK_END)
                            handle.write(bytes([value ^ 1]))
                    run(['open', '-n', installed])
                    deadline = time.monotonic() + 180
                    while not result.exists() and time.monotonic() < deadline:
                        time.sleep(0.2)
                    if not result.exists():
                        trace = result.with_suffix('.txt.trace')
                        if trace.exists():
                            shutil.copyfile(trace, ROOT / '.build/update-integration-failure.log')
                        raise AssertionError(f'{mode}: app did not finish within 180 seconds')
                    outcome = result.read_text()
                    if not outcome.startswith('PASS:'):
                        raise AssertionError(f'{mode}: {outcome}')
                    # Allow an unwanted install-on-quit to become observable.
                    time.sleep(2)
                    actual = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
                    if actual != ('21' if mode == 'update' else '20'):
                        raise AssertionError(f'{mode}: unexpected installed build {actual}')
                    print(f'{mode}: {outcome}', flush=True)
                finally:
                    subprocess.run(['pkill', '-f', re.escape(str(installed / 'Contents') + '/')], capture_output=True)
                    subprocess.run(['defaults', 'delete', identifier], capture_output=True)
                    subprocess.run(['tccutil', 'reset', 'All', identifier], capture_output=True)
                    shutil.rmtree(Path.home() / 'Library/Caches' / identifier, ignore_errors=True)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
