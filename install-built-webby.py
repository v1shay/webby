"""Install the verified build without modifying a running executable's inode.

The Webby.app directory stays in place (including Dock bookmarks). Its Contents
directory is atomically swapped with a staged build, and the previous Contents
is kept as a runnable backup. Webby is never quit or relaunched by this script.
"""
import ctypes
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid


parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parent / 'Webby.app')
source = parser.parse_args().source.resolve()
installed = Path.home() / 'Applications' / 'Webby.app'
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
staged = installed.parent / ('.Webby-stage-' + uuid.uuid4().hex + '.app')
backup = Path.home() / 'Library/Application Support/Webby/Backups' / ('Webby-' + stamp + '.app')


def verify(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


if not installed.is_dir() or installed.is_symlink():
    raise SystemExit('Expected the existing Webby.app in ~/Applications.')
with (installed / 'Contents/Info.plist').open('rb') as handle:
    original_id = plistlib.load(handle)['CFBundleIdentifier']
with (source / 'Contents/Info.plist').open('rb') as handle:
    if plistlib.load(handle)['CFBundleIdentifier'] != original_id:
        raise SystemExit('Refusing to replace an app with a different bundle identifier.')

original_inode = (installed / 'Contents').stat().st_ino
subprocess.run(['ditto', str(source / 'Contents'), str(staged / 'Contents')], check=True)
verify(staged)
if (installed / 'Contents').stat().st_ino != original_inode:
    raise SystemExit('Webby changed during staging; the staged build has been kept for review.')
backup.parent.mkdir(parents=True, exist_ok=True)
cosmetic_attributes = {}
for name in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
    result = subprocess.run(['xattr', '-px', name, str(installed)], capture_output=True)
    if result.returncode == 0:
        cosmetic_attributes[name] = bytes.fromhex(result.stdout.decode()).hex()
metadata = backup.parent / ('Webby-' + stamp + '-finder-metadata.json')
metadata.write_text(json.dumps(cosmetic_attributes, indent=2) + '\n')
root_icon = installed / 'Icon\r'
backup_icon = staged / 'Icon\r'

libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
swap = libc.renamex_np
swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
swap.restype = ctypes.c_int


def swap_contents():
    if swap(os.fsencode(installed / 'Contents'), os.fsencode(staged / 'Contents'), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


swap_contents()
try:
    # NSWorkspace.setIcon adds cosmetic root metadata that strict signature
    # verification rejects. Preserve it with the old app. Webby regenerates its
    # profile icon on launch; no quarantine or other security attributes change.
    if root_icon.exists():
        root_icon.rename(backup_icon)
    for name, value in cosmetic_attributes.items():
        subprocess.run(['xattr', '-wx', name, value, str(staged)], check=True)
        subprocess.run(['xattr', '-d', name, str(installed)], check=True)
    verify(installed)
except Exception:
    swap_contents()
    if backup_icon.exists():
        backup_icon.rename(root_icon)
    for name, value in cosmetic_attributes.items():
        subprocess.run(['xattr', '-wx', name, value, str(installed)], check=True)
    raise
staged.rename(backup)
print('Installed:', installed)
print('Previous version:', backup)
print('The running app was left open. Quit and reopen Webby to load the update.')
