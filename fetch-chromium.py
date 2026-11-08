"""Fetch the pinned official CEF distribution and verify before extraction."""
import hashlib
import json
import subprocess
import tarfile
import tempfile
import urllib.parse
from pathlib import Path

root = Path(__file__).resolve().parent / "Vendor" / "CEF"
version = json.loads((root / "version.json").read_text())
with tempfile.TemporaryDirectory(prefix="webby-cef-") as directory:
    archive = Path(directory) / "cef.tar.bz2"
    url = "https://cef-builds.spotifycdn.com/" + urllib.parse.quote(version["file"])
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2",
                    "--silent", "--show-error", "--output", str(archive), url], check=True)
    with archive.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha1").hexdigest()
    if digest != version["sha1"]:
        raise SystemExit("CEF download checksum mismatch")
    with tarfile.open(archive) as bundle:
        for entry in bundle.getmembers():
            parts = Path(entry.name).parts[1:]
            if not parts:
                continue
            destination = root.joinpath(*parts)
            if not destination.resolve().is_relative_to(root.resolve()):
                raise SystemExit("Unsafe archive path")
            entry.name = str(Path(*parts))
            bundle.extract(entry, root, filter="data")
print("CEF ready:", version["version"])
