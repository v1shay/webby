#!/usr/bin/env python3
"""Run Chromium popup or native edit checks against a copy of a built Webby bundle."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('popup', 'native'))
    parser.add_argument('--app', type=Path, default=root / 'Webby.app')
    args = parser.parse_args()
    native = args.mode == 'native'
    source = 'NativeInteractionChecks' if native else 'ChromiumPopupChecks'
    binary = f'Webby{source}'

    with tempfile.TemporaryDirectory(prefix='webby-engine-checks.', dir='/private/tmp') as directory:
        work = Path(directory)
        app = work / 'Webby Engine Audit.app'
        subprocess.run(['cp', '-cR', str(args.app.resolve()), str(app)], check=True)
        info_file = app / 'Contents/Info.plist'
        with info_file.open('rb') as stream:
            info = plistlib.load(stream)
        info.update(CFBundleExecutable=binary, CFBundleIdentifier=f'local.webby.audit.{args.mode}',
                    CFBundleName='Webby Engine Audit', LSUIElement=False)
        with info_file.open('wb') as stream:
            plistlib.dump(info, stream)
        exe = app / 'Contents/MacOS' / binary
        subprocess.run(['clang++', '-std=c++20', '-fobjc-arc', '-O1', '-target', 'arm64-apple-macos14.0',
                        '-I', str(root / 'Vendor/CEF'), str(root / 'Tests' / f'{source}.mm'),
                        str(root / 'ChromiumBridge.mm'), '-framework', 'AppKit', '-framework', 'WebKit',
                        '-o', str(exe)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        with subprocess.Popen([sys.executable, str(root / 'Tests/engine_fixture_server.py')],
                              stdout=subprocess.PIPE, text=True) as server:
            try:
                port = server.stdout.readline().strip()
                if not port:
                    raise RuntimeError('Loopback fixture server did not start')
                options = [f'http://127.0.0.1:{port}', str(work / 'profiles'), '--check-engine-ui']
                env = dict(os.environ, WEBBY_ENGINE_TEST_KEYCHAIN='1')
                if not native:
                    return subprocess.run([str(exe), *options], env=env, timeout=45).returncode
                log = work / 'interaction.log'
                # LaunchServices registers a separate app with its own menu and key window.
                result = subprocess.run(['open', '-n', '-W', '-a', str(app), '--env',
                                         'WEBBY_ENGINE_TEST_KEYCHAIN=1', '--stdout', str(log),
                                         '--stderr', str(log), '--args', *options], env=env, timeout=55)
                output = log.read_text() if log.exists() else ''
                print(output, end='')
                if 'SKIP:' in output:
                    return 77
                return int(result.returncode != 0 or 'FAIL:' in output or output.count('PASS:') != 2)
            finally:
                server.terminate()


if __name__ == '__main__':
    raise SystemExit(main())
