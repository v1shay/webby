"""Fetch the pinned official CEF distribution and verify before extraction."""
import hashlib
import json
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent / "Vendor" / "CEF"
version = json.loads((root / "version.json").read_text())
with tempfile.TemporaryDirectory(prefix="webby-cef-") as directory:
    archive = Path(directory) / "cef.tar.bz2"
    urllib.request.urlretrieve("https://cef-builds.spotifycdn.com/" + urllib.parse.quote(version["file"]), archive)
    if hashlib.sha1(archive.read_bytes()).hexdigest() != version["sha1"]:
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
