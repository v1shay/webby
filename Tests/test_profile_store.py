from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'ChromeImport.swift').read_text()
models=s[s.index('struct BrowserLink:'):s.index('@MainActor final class BrowserSpace')]
store=s[s.index('enum BrowserSpaceStore {'):s.index('struct ChromeProfileSource')]
with tempfile.TemporaryDirectory(prefix='webby-profile-store-') as work:
    path=Path(work)/'Check.swift'
    path.write_text('import Foundation\n'+models+store+'''
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("profiles.json")
assert(try BrowserSpaceStore.load(from:file).isEmpty)
let id=UUID()
let first=SavedBrowserSpace(id:id,name:"Account",chromeDirectory:"Profile 1",bookmarks:[],history:[])
try BrowserSpaceStore.save([first],to:file)
let second=SavedBrowserSpace(id:id,name:"Renamed",chromeDirectory:"Profile 1",bookmarks:[],history:[])
try BrowserSpaceStore.save([second],to:file)
assert(try BrowserSpaceStore.load(from:file)[0].name == "Renamed")
let corrupt=Data("broken json".utf8);try corrupt.write(to:file)
let recovered=try BrowserSpaceStore.load(from:file)
assert(recovered[0].id==id && recovered[0].chromeDirectory=="Profile 1")
assert(try Data(contentsOf:file)==corrupt)
try Data("broken backup".utf8).write(to:file.appendingPathExtension("last-good"))
do { _ = try BrowserSpaceStore.load(from:file); fatalError("Corruption became a fresh install") } catch {}
assert(try Data(contentsOf:file)==corrupt)
print("PASS: fresh install, atomic saves, previous-good recovery, profile identity retained, corrupt files never treated as an empty install")
'''.replace('assert(try ','assertNoThrow(try '))
    # Swift assert autoclosures cannot throw; evaluate arguments before assertion.
    text=path.read_text().replace('let folder =','func assertNoThrow(_ condition: Bool) { precondition(condition) }\nlet folder =',1)
    path.write_text(text)
    subprocess.run(['swift',str(path)],check=True)
