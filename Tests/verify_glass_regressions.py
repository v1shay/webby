# Generate a temporary standalone WKWebView probe from the committed test harness.
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
source=source.replace("for(let i=0;i<600;i++)", "app.innerHTML='<div id=accent style=\"background:rgb(230,40,30);width:100px;height:40px\">Accent</div><div id=gradient class=panel style=\"background-image:linear-gradient(#fff,#ddd)\">Gradient</div><canvas id=media width=100 height=40 style=\"background:rgb(240,20,10)\"></canvas>'; for(let i=0;i<10;i++)")
source=source.replace("surface:gcs(document.querySelector('.panel')).backgroundColor,text:gcs(document.querySelector('.panel')).color", "surface:gcs(document.querySelector('.panel')).backgroundColor,text:gcs(document.querySelector('.panel')).color,accent:gcs(document.getElementById('accent')).backgroundColor,media:gcs(document.getElementById('media')).backgroundColor,gradient:gcs(document.getElementById('gradient')).backgroundImage")
Path(sys.argv[2]).write_text(source)
