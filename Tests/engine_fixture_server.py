"""Local-only pages for the real embedded-engine lifecycle checks."""
import time
from html import escape
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if urlparse(self.path).path != '/popup-post':
            self.send_error(404)
            return
        body = escape(self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode(errors='replace'))
        content = (f'<!doctype html><title>POST preserved: {body}</title>'
                   '<script>if (!window.opener) document.title="Missing opener";</script>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        url = urlparse(self.path)
        page = url.path.strip('/') or 'first'
        if page == 'popup-form':
            content = b'<!doctype html><form action="/popup-post" method="POST" target="webbyPopupForm"><input name="token" value="popup-payload"></form>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        if page == 'native-interaction':
            content = (b'<!doctype html><style>body{margin:30px}#selection{font:20px monospace;display:inline-block;user-select:text}input{display:block;margin-top:30px;width:350px;height:30px}</style>'
                       b'<span id="selection">Selection fixture text</span><input id="edit" value="replace me">')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        if page == 'download-status':
            content = self.server.download_states.get(url.query, 'waiting').encode()
            self.send_response(200)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        if page == 'slow-download':
            self.server.download_states[url.query] = 'streaming'
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="slow.bin"')
            self.send_header('Content-Length', str(64 * 1024 * 100))
            self.end_headers()
            try:
                for _ in range(100):
                    self.wfile.write(b'x' * (64 * 1024))
                    self.wfile.flush()
                    time.sleep(0.05)
                self.server.download_states[url.query] = 'finished'
            except (BrokenPipeError, ConnectionResetError):
                self.server.download_states[url.query] = 'disconnected'
            return
        if page == 'chromium-media.mp4':
            content = (Path(__file__).parent / 'Fixtures' / 'video.mp4').read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if page == 'chromium-media':
            content = (b'<!doctype html><title>Chromium MP4 fixture</title>'
                       b'<video controls muted playsinline width="640" height="360" src="/chromium-media.mp4"></video>')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        marker = parse_qs(url.query).get('set', [''])[0]
        content = f'''<!doctype html><html><body><h1>{page}</h1><input id="edit">
        <script>
        const stored = localStorage.getItem('engineTest') || 'empty';
        const cookie = document.cookie.split('; ').find(x=>x.startsWith('engineTest='))?.split('=')[1] || 'empty';
        const previous = stored === cookie ? stored : 'storage-mismatch';
        document.title = {page!r} + '|' + previous;
        if ({marker!r}) {{localStorage.setItem('engineTest', {marker!r});document.cookie='engineTest='+{marker!r}+'; path=/'}}
        if ({page!r} === 'edit') setTimeout(()=>{{document.querySelector('input').value='unsaved';document.querySelector('input').dispatchEvent(new Event('input',{{bubbles:true}}))}},500);
        </script></body></html>'''.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.download_states = {}
    print(server.server_address[1], flush=True)
    server.serve_forever()
