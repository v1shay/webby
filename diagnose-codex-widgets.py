#!/usr/bin/env python3
"""Read-only probe of the existing Codex app daemon. Never starts a server,
sends prompts, reads auth.json, or prints chat/account contents."""
import json
import os
from pathlib import Path
import stat
import socket as sockets
import base64
import hashlib
import time


def main():
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    socket = home / "app-server-control/app-server-control.sock"
    candidates = [Path("/Applications/ChatGPT.app"), Path.home() / "Applications/ChatGPT.app"]
    app = next((p for p in candidates if (p / "Contents/Resources/codex-cli/bin/codex").is_file()), None)
    result = {"readOnly": True, "appFound": app is not None, "transport": "native-unix-websocket", "probeVersion": 2}
    connection = None
    try:
        resolved = socket.resolve()
        info = resolved.stat()
        parent = resolved.parent.stat()
        result.update(socketExists=True, socketOwnedByUser=info.st_uid == os.getuid(),
                      socketMode=oct(stat.S_IMODE(info.st_mode)),
                      parentOwnedByUser=parent.st_uid == os.getuid(), parentMode=oct(stat.S_IMODE(parent.st_mode)))
        if app is None:
            result["failure"] = "Codex app not found"
            return
        connection = sockets.socket(sockets.AF_UNIX, sockets.SOCK_STREAM)
        connection.settimeout(8)
        result["stage"] = "connect"
        connection.connect(str(socket))
        key = base64.b64encode(os.urandom(16)).decode()
        result["stage"] = "websocket-upgrade"
        connection.sendall(("GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        pending = bytearray()
        while b"\r\n\r\n" not in pending:
            data = connection.recv(16384)
            if not data:
                raise RuntimeError("Socket disconnected during upgrade")
            pending.extend(data)
            if len(pending) > 16384:
                raise RuntimeError("Upgrade reply exceeded limit")
        headers, _, remainder = pending.partition(b"\r\n\r\n")
        pending[:] = remainder
        lines = headers.decode().split("\r\n")
        result["upgradeStatus"] = lines[0].split(" ")[1]
        fields = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip() for line in lines[1:] if ":" in line}
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if result["upgradeStatus"] != "101" or fields.get("sec-websocket-accept") != expected:
            raise RuntimeError("WebSocket upgrade rejected")
        result["websocketUpgrade"] = True
        next_id = 0
        fragment = bytearray()

        def send_frame(payload, opcode=1):
            mask = os.urandom(4)
            count = len(payload)
            header = bytes([0x80 | opcode, 0x80 | count]) if count < 126 else bytes([0x80 | opcode, 0xFE]) + count.to_bytes(2, "big")
            connection.sendall(header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))

        def send(packet):
            send_frame(json.dumps(packet).encode())

        def take(count):
            while len(pending) < count:
                data = connection.recv(16384)
                if not data:
                    raise RuntimeError("Socket disconnected")
                pending.extend(data)
                if len(pending) > 2_000_000:
                    raise RuntimeError("Frame exceeded limit")
            data = bytes(pending[:count])
            del pending[:count]
            return data

        def call(method, params=None):
            nonlocal next_id
            next_id += 1
            packet = {"id": next_id, "method": method}
            if params is not None:
                packet["params"] = params
            result["stage"] = method
            send(packet)
            until = time.monotonic() + 8
            while time.monotonic() < until:
                first, second = take(2)
                opcode, count = first & 15, second & 127
                if second & 128:
                    raise RuntimeError("Unexpected masked server frame")
                if count == 126:
                    count = int.from_bytes(take(2), "big")
                elif count == 127:
                    count = int.from_bytes(take(8), "big")
                if count > 2_000_000:
                    raise RuntimeError("Frame exceeded limit")
                data = take(count)
                if opcode == 9:
                    send_frame(data, 10)
                    continue
                if opcode == 10:
                    continue
                if opcode == 8:
                    raise RuntimeError("Server closed WebSocket")
                fragment.extend(data)
                if not first & 128:
                    continue
                value = json.loads(fragment)
                fragment.clear()
                if value.get("id") == next_id:
                    if "error" in value:
                        result["rpcErrorCode"] = value["error"].get("code")
                        result["rpcErrorMessage"] = str(value["error"].get("message", ""))[:250]
                        raise RuntimeError("RPC rejected")
                    return value.get("result", {})
            raise TimeoutError("Reply timed out")

        call("initialize", {"clientInfo": {"name": "webby_widgets", "title": "Webby Widgets", "version": "1"},
                            "capabilities": {"experimentalApi": True}})
        result["handshake"] = True
        send({"method": "initialized"})
        account = call("account/read", {"refreshToken": False})
        result["signedIn"] = isinstance(account.get("account"), dict)
        chats = call("thread/list", {"limit": 1, "sortKey": "updated_at", "sortDirection": "desc",
                                     "archived": False, "sourceKinds": ["cli", "vscode", "exec", "appServer"],
                                     "useStateDbOnly": True})
        result["recentChatsReadable"] = isinstance(chats.get("data"), list)
        usage = call("account/rateLimits/read")
        result["usageReadable"] = bool(usage.get("rateLimits") or usage.get("rateLimitsByLimitId"))
        result["success"] = True
    except PermissionError:
        result["failure"] = "macOS denied socket access"
    except FileNotFoundError:
        result["failure"] = "Existing app socket missing; no server was started"
    except Exception as error:
        result["failure"] = type(error).__name__ + ": " + str(error)[:150]
    finally:
        if connection is not None:
            connection.close()
        output = Path(__file__).resolve().parent.parent / "work/codex-widget-diagnostic.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + "\n")
        output.chmod(0o600)
        print(json.dumps(result, indent=2))
        print("Diagnostic saved to", output)


if __name__ == "__main__":
    main()
