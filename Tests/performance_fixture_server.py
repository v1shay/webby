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
        if path.startswith('/full-'): self.counts[self.path]=self.counts.get(self.path,0)+1
        if path in ('/download-fixture','/download-once'):
            if 'webby_download_auth=ok' not in self.headers.get('Cookie',''):
                self.send_response(403);self.send_header('Content-Disposition','attachment; filename="webby-fixture.txt"');self.end_headers();return
            if path == '/download-once' and self.counts[path] > 1:
                self.send_response(403);self.end_headers();return
            body=b'webby-integration-download\n'
            self.send_response(200);self.send_header('Content-Type','application/octet-stream')
            self.send_header('Content-Disposition','attachment; filename="webby-fixture.txt"')
            self.send_header('Content-Length',str(len(body)));self.end_headers()
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        if path == '/video.mp4':
            body=(Path(__file__).parent/'Fixtures/video.mp4').read_bytes()
            start,end=0,len(body)-1
            requested=self.headers.get('Range','')
            if requested.startswith('bytes='):
                first,last=requested[6:].split(',')[0].split('-',1)
                start=int(first or 0);end=min(end,int(last) if last else end)
                if start>end or start>=len(body): self.send_response(416);self.end_headers();return
                self.send_response(206);self.send_header('Content-Range',f'bytes {start}-{end}/{len(body)}')
            else: self.send_response(200)
            self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length',str(end-start+1));self.end_headers()
            try:self.wfile.write(body[start:end+1])
            except (BrokenPipeError,ConnectionResetError):pass
            return
        if path == '/tracking-slow.js':
            time.sleep(0.6)
            body=b'window.trackerRan=true;'
            self.send_response(200);self.send_header('Content-Type','application/javascript');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers()
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
            return
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
            if path == '/download-page': content = '<a id="download" href="/download-fixture">download</a><a id="attribute" href="/download-fixture" download>attribute download</a><a id="blank" href="/download-fixture" target="_blank">new window download</a><a id="once" href="/download-once">one-use download</a>'
            if path == '/video': content = """<video id=video controls preload=auto width=640 height=360 src='/video.mp4'></video><br><button id=start onclick="window.videoClicks=(window.videoClicks||0)+1;const v=document.getElementById('video');v.volume=.37;v.muted=false;v.playbackRate=1.25;v.currentTime=4;v.play()">Start video</button><button id=full onclick="fetch('/full-click');document.getElementById('video').requestFullscreen().then(()=>fetch('/full-ok')).catch(e=>fetch('/full-error?'+encodeURIComponent(e.name+':'+e.message)))">Website fullscreen</button>"""
            if path == '/video-frame': content = "<iframe id=player src='/video' width=700 height=470 allow='picture-in-picture; fullscreen' allowfullscreen></iframe>"
            if path == '/chatgpt': content = """<textarea id=prompt-textarea></textarea><input type=file accept='image/*' multiple><div id=previews></div><button data-testid=send-button disabled>Send</button><script>const editor=document.querySelector('textarea'),send=document.querySelector('button');editor.addEventListener('input',()=>send.disabled=!editor.value);document.querySelector('input').addEventListener('change',e=>{window.uploaded=[...e.target.files].map(x=>x.name);document.getElementById('previews').innerHTML=window.uploaded.map(x=>'<button aria-label=Remove>'+x+'</button>').join('')});send.onclick=()=>window.sent={text:editor.value,files:window.uploaded||[]};</script>"""
            if path == '/tone': content = '<style>body{margin:0!important;padding:0!important;background:rgb(21,35,49)!important}#tone{position:sticky;top:0;height:80px;background:rgb(40,80,120)}.changed{background:rgb(180,60,30)!important}</style><div id=tone>Header</div><div style="height:3000px">Scroll</div>'
            if path == '/tracking-page': content = '<textarea>original</textarea><script src="/tracking-slow.js"></script><p>Ready</p>'
            if path == '/links': content += '<meta property="og:site_name" content="Fixture Site">'
            if path == '/links': content += '<a id=normal href="/plain?normal=1">Normal link</a><br><a id=blank target=_blank href="/plain?blank=1">New tab</a>'
            if path == '/slow': content += '<img src="/slow-image.svg" width="30" height="30">'
            if path == '/geist': content = '<p id=geist-text>Geist weight and spacing</p><em id=geist-italic>Italic text</em><pre><code id=geist-code>let value = 42</code></pre><span id=geist-icon class=material-icons>home</span><textarea id=geist-input></textarea><script>document.getElementById("geist-icon").style.fontFamily="FixtureIcons";</script>'
            if path == '/form': content += '<textarea id="editor">original</textarea>'
            if path == '/frame': content += '<iframe src="/plain"></iframe>'
            if path == '/tall': content += '<div style="height:3000px;background:linear-gradient(#ddd,#555)">Long page</div>'
            body = ('<!doctype html><html><head><title>Webby '+path+'</title><style>body{background:#fff;color:#111;font:18px -apple-system;padding:32px}</style></head><body>'+content+'</body></html>').encode(); mime = 'text/html'
        self.send_response(200);
        if path == '/geist': self.send_header('Content-Security-Policy', "font-src 'none'; style-src 'none'")
        if path == '/download-page': self.send_header('Set-Cookie','webby_download_auth=ok; Path=/; HttpOnly; SameSite=Lax')
        self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
