from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/"WidgetCanvas.swift").read_text()
solver=source[source.index("struct HomepageLayout:"):source.index("// Canvas coordinates")]
with tempfile.TemporaryDirectory(prefix="webby-layout-") as work:
    test=Path(work)/"Layout.swift"
    test.write_text("import AppKit\n"+solver+'var checked=0\nfor width in [640.0,1024,1600] {for height in [480.0,900,1200] {for count in 1...23 {for style in HomepageLayout.allCases {\n let regions = style.searchPosition == 1 ? [NSRect(x:24,y:24,width:width-48,height:(height-280)/2),NSRect(x:24,y:(height+232)/2,width:width-48,height:(height-280)/2)] : [NSRect(x:24,y:232,width:width-48,height:height-256)]\n let frames=style.frames(count:count,in:regions);assert(frames.count==count)\n for (i,f) in frames.enumerated() {\n assert(regions.contains{ $0.insetBy(dx:-0.01,dy:-0.01).contains(f) })\n for other in frames.dropFirst(i+1) {assert(!f.insetBy(dx:0.01,dy:0.01).intersects(other))}\n }\n checked += 1\n}}}}\nfor index in [1,2,3,4,5,6,7,8,9,11,14] {\n let frames=HomepageLayout(rawValue:index*3)!.frames(count:5,in:[NSRect(x:0,y:0,width:1400,height:800)])\n assert(frames.contains{abs($0.width-frames[0].width)>1 || abs($0.height-frames[0].height)>1})\n}\nprint("PASS: \\(checked) mixed-size layout cases, boundaries and overlap checks; featured layouts produce different sizes")\n')
    subprocess.run(["swift",str(test)],check=True)
