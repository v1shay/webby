#!/usr/bin/env python3
"""Install a verified, isolated macOS Apple Silicon workbench for Webby."""
from pathlib import Path
import hashlib, json, os, platform, shutil, subprocess, tarfile, tempfile, urllib.request

root = Path(__file__).resolve().parent
lock = json.loads((root / 'ide-runtime-lock.json').read_text())
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('This runtime lock targets Apple Silicon macOS.')
base = Path.home() / 'Library/Application Support/Webby IDE'
runtime = base / 'Runtime'
base.mkdir(parents=True, exist_ok=True)
if not (runtime / 'bin/code-server').exists():
    with tempfile.TemporaryDirectory(prefix='runtime-install-', dir=base) as temporary:
        stage = Path(temporary)
        for name, package in [('code-server', lock['codeServer']), ('node', lock['node'])]:
            headers = {}
            if name == 'code-server':
                with urllib.request.urlopen('https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/code-server:pull', timeout=30) as response:
                    headers['Authorization'] = 'Bearer ' + json.load(response)['token']
            archive = stage / (name + '.tar.gz')
            request = urllib.request.Request(package['url'], headers=headers)
            with urllib.request.urlopen(request, timeout=120) as source, archive.open('wb') as target:
                shutil.copyfileobj(source, target)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != package['sha256']:
                raise SystemExit('Runtime checksum did not match: ' + name)
            unpack = stage / (name + '-unpack'); unpack.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(unpack, filter='data')
            source = next(unpack.glob('code-server/*/libexec')) if name == 'code-server' else next(unpack.iterdir())
            shutil.copytree(source, stage / name, symlinks=True)
        (stage / 'bin').mkdir()
        launcher = stage / 'bin/code-server'
        launcher.write_text('#!/bin/sh\nWEBBY_IDE_RUNTIME=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)\nexec "$WEBBY_IDE_RUNTIME/node/bin/node" "$WEBBY_IDE_RUNTIME/code-server/out/node/entry.js" "$@"\n')
        launcher.chmod(0o755)
        if runtime.exists():
            raise SystemExit('An incomplete Runtime directory exists; preserve or rename it before installing.')
        runtime.mkdir()
        for name in ['code-server', 'node', 'bin']:
            shutil.move(str(stage / name), runtime / name)
workbench = base / 'Workbench'; workbench.mkdir(exist_ok=True)
config = workbench / 'config.yaml'
if not config.exists(): config.write_text('{}\n')
command = [str(runtime / 'bin/code-server'), '--config', str(config), '--user-data-dir', str(workbench), '--extensions-dir', str(workbench / 'extensions')]
subprocess.run(command + ['--version'], check=True)
subprocess.run(command + [part for extension in lock['extensions'] for part in ['--install-extension', extension]], check=True)
print('Webby workbench installed. Open it with Command–Shift–I after reopening Webby.')
