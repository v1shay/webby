"""Local-only pages for the real embedded-engine lifecycle checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        page = url.path.strip('/') or 'first'
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
    print(server.server_address[1], flush=True)
    server.serve_forever()
