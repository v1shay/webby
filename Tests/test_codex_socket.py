"""Protocol fixture only. Never connects to the user's Codex daemon."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import uuid


def main():
    errors = []
    with tempfile.TemporaryDirectory(prefix="webby-ws-fixture-") as folder:
        path = str(Path(folder) / "rpc.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        Path(path).chmod(0o600)
        listener.listen(1)
        listener.settimeout(15)

        def serve():
            try:
                with listener.accept()[0] as stream:
                    stream.settimeout(12)
                    buffer = bytearray()

                    def take(n):
                        while len(buffer) < n:
                            data = stream.recv(16384)
                            if not data:
                                raise EOFError()
                            buffer.extend(data)
                        value = bytes(buffer[:n])
                        del buffer[:n]
                        return value

                    while b"\r\n\r\n" not in buffer:
                        buffer.extend(stream.recv(16384))
                        assert len(buffer) < 16384
                    request, _, rest = buffer.partition(b"\r\n\r\n")
                    buffer[:] = rest
                    headers = request.decode().split("\r\n")
                    assert headers[0] == "GET /rpc HTTP/1.1", "JSONL is not a WebSocket handshake"
                    fields = dict(line.lower().split(": ", 1) for line in headers[1:] if ": " in line)
                    # Preserve the key's case: base64 is case-sensitive.
                    key = next(line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("sec-websocket-key:"))
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    stream.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())

                    def frame(data, opcode=1, final=True):
                        first = opcode | (128 if final else 0)
                        if len(data) < 126:
                            return bytes([first, len(data)]) + data
                        return bytes([first, 126]) + len(data).to_bytes(2, "big") + data

                    chat = str(uuid.uuid4())
                    finished = False
                    while True:
                        first, second = take(2)
                        assert second & 128, "Clients must mask WebSocket frames"
                        size = second & 127
                        if size == 126:
                            size = int.from_bytes(take(2), "big")
                        elif size == 127:
                            size = int.from_bytes(take(8), "big")
                        assert size < 100000
                        mask, payload = take(4), take(size)
                        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
                        if first & 15 == 10:
                            assert payload == b"probe"
                            if finished:
                                return
                            continue
                        message = json.loads(payload)
                        method = message["method"]
                        if method == "initialized":
                            continue
                        if method == "initialize":
                            result = {"userAgent": "fixture"}
                        elif method == "account/read":
                            result = {"account": {"type": "chatgpt", "email": "fixture@example.test"}}
                        elif method == "thread/list":
                            result = {"data": [{"id": chat, "title": "Socket fixture", "cwd": "/fixture"}]}
                        elif method == "account/rateLimits/read":
                            result = {"rateLimits": {"primary": {"usedPercent": 25, "windowDurationMins": 300}}}
                        elif method == "thread/queue/add":
                            assert message["params"]["input"][0]["text"] == "fixture only"
                            result = {"queuedSubmission": {"id": "fixture-queue"}}
                        else:
                            raise AssertionError("Unexpected method: " + method)
                        data = json.dumps({"id": message["id"], "result": result}).encode()
                        # Exercise fragmented data with an interleaved control frame.
                        stream.sendall(frame(data[:7], final=False) + frame(b"probe", 9) + frame(data[7:], 0))
                        if method == "thread/queue/add":
                            finished = True
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process = subprocess.run([sys.argv[1], "--socket-fixture", path], capture_output=True, text=True, timeout=30)
        worker.join(timeout=2)
        listener.close()
        if errors:
            raise errors[0]
        print(process.stdout, end="")
        if process.returncode:
            raise RuntimeError(process.stderr or "Native client failed")


if __name__ == "__main__":
    main()
