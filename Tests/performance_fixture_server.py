from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit
from pathlib import Path
import json, time, sys
class Handler(BaseHTTPRequestHandler):
    counts = {}
    def log_message(self, *_): pass
    def do_GET(self):
        path = urlsplit(self.path).path
        self.counts[path] = self.counts.get(path, 0) + 1
        if path == '/redirect':
            self.send_response(302); self.send_header('Location', '/plain?redirected=1'); self.end_headers(); return
        if path == '/slow-image.svg':
            time.sleep(2)
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30"><rect width="30" height="30" fill="green"/></svg>'
            mime = 'image/svg+xml'
        elif path == '/counts': body = json.dumps(self.counts).encode(); mime = 'application/json'
        elif path == '/favicon.ico': self.send_response(404); self.end_headers(); return
        else:
            content = '<h1>Visible content before the slow image finishes</h1><p>This is an isolated Webby test page.</p>'
            if path == '/tone': content = '<style>body{margin:0!important;padding:0!important;background:rgb(21,35,49)!important}#tone{position:sticky;top:0;height:80px;background:rgb(40,80,120)}.changed{background:rgb(180,60,30)!important}</style><div id=tone>Header</div><div style="height:3000px">Scroll</div>'
            if path == '/links': content += '<a id=normal href="/plain?normal=1">Normal link</a><br><a id=blank target=_blank href="/plain?blank=1">New tab</a>'
            if path == '/slow': content += '<img src="/slow-image.svg" width="30" height="30">'
            if path == '/form': content += '<textarea id="editor">original</textarea>'
            if path == '/frame': content += '<iframe src="/plain"></iframe>'
            if path == '/tall': content += '<div style="height:3000px;background:linear-gradient(#ddd,#555)">Long page</div>'
            body = ('<!doctype html><html><head><title>Webby '+path+'</title><style>body{background:#fff;color:#111;font:18px -apple-system;padding:32px}</style></head><body>'+content+'</body></html>').encode(); mime = 'text/html'
        self.send_response(200); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
