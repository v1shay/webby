"""Exercise the bundled CLI against Webby's native browser fixture."""
import argparse
import contextlib
import http.server
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/file":
            body = b"Webby agent download fixture\n"
            self.send_response(200)
            self.send_header("Content-Disposition", 'attachment; filename="agent-fixture.txt"')
            self.send_header("Content-Type", "text/plain")
        else:
            body = (b'<!doctype html><title>Webby Agent Fixture</title><h1>Fixture page</h1>'
                    b'<form><label>Test <input id="query" name="query"></label>'
                    b'<button id="submit">Submit</button></form>')
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Security-Policy", "default-src 'none'; form-action 'self'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def wait_until(fn, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.15)
    raise AssertionError(f"Timed out waiting for {fn}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test_app", type=Path)
    parser.add_argument("built_app", type=Path)
    args = parser.parse_args()
    test_app, app = args.test_app.resolve(), args.built_app.resolve()
    cli = app / "Contents/Helpers/webby"
    frameworks = test_app / "Contents/Frameworks"
    if frameworks.is_symlink():
        frameworks.unlink()
    if not frameworks.exists():
        shutil.copytree(app / "Contents/Frameworks", frameworks, symlinks=True)
        identity = os.environ.get("WEBBY_SIGN_IDENTITY")
        if not identity:
            signing = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
            identity = "system local code signing" if '"system local code signing"' in signing else "-"
        subprocess.run(["codesign", "--force", "--sign", identity, test_app], check=True)

    with (tempfile.TemporaryDirectory(prefix="wba-", dir="/private/tmp") as scratch,
          http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server):
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        folder = Path(scratch)
        env = dict(os.environ, WEBBY_TEST_AGENT="only", WEBBY_ENGINE_TEST_KEYCHAIN="1",
                   WEBBY_CLI_SOCKET_DIRECTORY=scratch)
        result_file = folder / "result.json"
        log_path = test_app.parent / "agent-fixture.log"
        with log_path.open("w") as log:
            process = subprocess.Popen([test_app / "Contents/MacOS/Webby", base, result_file, "--check-engine-ui"],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                wait_until(lambda: result_file.exists() or process.poll() is not None)
                assert result_file.exists(), log_path

                def run(*words, failure=False):
                    result = subprocess.run([cli, *words], env=env, capture_output=True, text=True, timeout=40)
                    payload = json.loads(result.stdout)
                    assert (result.returncode != 0) == failure, (words, payload, result.stderr, log_path)
                    assert payload["ok"] != failure, (words, payload)
                    return payload.get("result", payload.get("error"))

                assert run("status")["version"] == 1
                assert run("json", '{"command":"status"}')["version"] == 1
                profiles = {p["name"]: p["id"] for p in run("profiles")}
                assert set(profiles) == {"Fixture A", "Fixture B"}
                assert "not found" in run("focus", "missing", failure=True).lower()
                assert run("agent")["opened"]
                assert sum(tab["title"] == "Webby Agent" for tab in run("tabs")) == 1
                agent_tab = run("status")["tab"]
                background = run("json", json.dumps({"command": "open", "url": base, "engine": "webkit", "foreground": False}))
                assert not background["active"] and run("status")["tab"] == agent_tab
                assert "Fixture page" in run("snapshot", run("wait", background["id"])["id"])["text"]
                assert run("close", background["id"])["closed"]
                for engine, profile in zip(("webkit", "chromium"), profiles.values()):
                    tab = run("open", base, profile, engine)
                    tab_id = tab["id"]
                    assert tab["profile"] == profile and tab["engine"].lower() == engine

                    def loaded():
                        item = next(row for row in run("tabs") if row["id"] == tab_id)
                        assert item["error"] is None, item
                        return item["url"] and not item["loading"]

                    assert run("wait", tab_id)["id"] == tab_id
                    wait_until(loaded)
                    assert run("focus", tab_id)["active"]
                    status = run("status")
                    assert status["profile"] == profile and status["tab"] == tab_id, status
                    assert run("text", "@active").startswith("Fixture page")
                    assert "Fixture page" in run("snapshot", tab_id)["text"]
                    assert run("eval", tab_id, "Promise.resolve(document.title)") == "Webby Agent Fixture"
                    assert run("fill", tab_id, "#query", "webby")
                    assert run("eval", tab_id, "document.querySelector('#query').value") == "webby"
                    assert run("click", tab_id, "#submit")
                    wait_until(lambda: loaded() and any(
                        "?query=webby" in (row["url"] or "") for row in run("tabs") if row["id"] == tab_id))
                    assert run("screenshot", tab_id)["png"].startswith("iVBORw0KGgo")
                    download_id = run("download", tab_id, base + "/file")["id"]

                    def downloaded():
                        item = next((entry for entry in run("downloads") if entry["id"] == download_id), None)
                        if not item or item["status"] == "Downloading":
                            return None
                        assert item["status"] == "Finished", item
                        return Path(item["path"])

                    assert wait_until(downloaded).read_bytes() == b"Webby agent download fixture\n"
                    assert run("close", tab_id)["closed"]
                    print(f"PASS: {engine} profile, DOM, JavaScript, screenshot, and download")
            finally:
                if process.poll() is None:
                    process.terminate()
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        process.wait(timeout=8)
                    if process.poll() is None:
                        process.kill()
                        process.wait()
        server.shutdown()


if __name__ == "__main__":
    main()
