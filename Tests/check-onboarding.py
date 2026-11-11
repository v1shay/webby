"""Build and exercise native onboarding with disposable Chrome data.

Run after build.sh. Pass an output directory for screenshots and test results.
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


def encrypted(value):
    ciphertext = subprocess.check_output(
        ["/usr/bin/openssl", "enc", "-aes-128-cbc", "-K", "41" * 16, "-iv", "20" * 16],
        input=value,
    )
    return b"v10" + ciphertext


def chrome_fixture(root):
    root.mkdir(parents=True, exist_ok=True)
    profiles = {"Default": {"name": "Fixture Chrome A"}, "Profile 1": {"name": "Fixture Chrome B"}}
    (root / "Local State").write_text(json.dumps({"profile": {"info_cache": profiles}}))
    for name in profiles:
        folder = root / name
        (folder / "Network").mkdir(parents=True, exist_ok=True)
        (folder / "Bookmarks").write_text(json.dumps({
            "roots": {"bookmark_bar": {"children": [
                {"type": "url", "name": "Example", "url": "https://example.test/"}
            ]}}
        }))
        with sqlite3.connect(folder / "History") as db:
            db.execute("CREATE TABLE IF NOT EXISTS urls (url TEXT, title TEXT, last_visit_time INTEGER)")
            db.execute("DELETE FROM urls")
            db.execute("INSERT INTO urls VALUES (?, ?, ?)",
                       ("https://example.test/history", "Fixture visit", 13370000000000000))
        with sqlite3.connect(folder / "Login Data") as db:
            db.execute("CREATE TABLE IF NOT EXISTS logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER)")
            db.execute("DELETE FROM logins")
            db.execute("INSERT INTO logins VALUES (?, ?, ?, 0)",
                       ("https://example.test/", "fixture-user", encrypted(b"fixture-password")))
        with sqlite3.connect(folder / "Network" / "Cookies") as db:
            db.execute("CREATE TABLE IF NOT EXISTS cookies (host_key TEXT, name TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, top_frame_site_key TEXT, has_expires INTEGER)")
            db.execute("DELETE FROM cookies")
            value = encrypted(hashlib.sha256(b"example.test").digest() + b"fixture-value")
            db.execute('INSERT INTO cookies VALUES (?, ?, ?, ?, 0, 1, 1, "", 0)',
                       ("example.test", "fixture-cookie", value, "/"))


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    chrome_fixture(output / "chrome-fixture")
    tests = Path(__file__).resolve().parent
    if "--reuse-build" not in sys.argv[2:]:
        subprocess.run([sys.executable, str(tests / "build_performance_harness.py"), str(output)], check=True)
    executable = output / "WebbyTests.app" / "Contents" / "MacOS" / "Webby"
    subprocess.run(
        ["/usr/bin/time", "-l", str(executable), "http://127.0.0.1:1", str(output / "result.json")],
        env={**os.environ, "WEBBY_TEST_ONBOARDING": "only"}, check=True, timeout=45,
    )


if __name__ == "__main__":
    main()
