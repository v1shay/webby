from pathlib import Path
import re, subprocess, plistlib, shutil, sys, os, json, hashlib, platform, datetime
root=Path(__file__).resolve().parents[1]
work=Path(sys.argv[1]).resolve(); work.mkdir(parents=True,exist_ok=True)
baseline=Path(os.environ['WEBBY_TEST_BASELINE_DIR']) if os.environ.get('WEBBY_TEST_BASELINE_DIR') else None
def sourcefile(name):
    candidate=baseline/name if baseline else None
    return candidate if candidate and candidate.is_file() else root/name
source=sourcefile('BrowserApp.swift').read_text()
source=source.replace('LightweightIDE()', 'LightweightIDE(nativeOnly: true)')
source=source.replace('    private func scheduleSpaceSave() {','    private func scheduleSpaceSave() {\n        return // Test copy never writes real browser profiles.',1)
source=source.replace('    private func loadCookieHosts(for space: BrowserSpace) {','    private func loadCookieHosts(for space: BrowserSpace) {\n        return // Never read personal cookies in a fixture.',1)
source=source.replace('configuration.websiteDataStore = ownerSpace(for: tab).dataStore','configuration.websiteDataStore = Self.performanceStore')
source=source.replace('    static func main() {','    static func main() {\n        WBPrepareApplication()\n        if CommandLine.arguments.count == 3 || ProcessInfo.processInfo.environment["WEBBY_TEST_AGENT"] == "only" {\n            if ProcessInfo.processInfo.environment["WEBBY_TEST_IDE_PURE"] == "1" { try! IDEProjectWidgetChecks.pure(); return }; BrowserApp.launchPerformanceChecks(base: CommandLine.arguments[1], output: URL(fileURLWithPath: CommandLine.arguments[2])); return\n        }',1)
source=source.replace('try spaceSaveQueue.sync { try BrowserSpaceStore.save(values) }',
    'try BrowserSpaceStore.save(values, to: FileManager.default.temporaryDirectory.appendingPathComponent("webby-setup-profiles-" + String(ProcessInfo.processInfo.processIdentifier) + ".json"))', 1)
# Fixture-only traces never run against personal tabs.
source=source.replace('    private func navigationFailed(in webView: WKWebView, error: Error) {', '    private func navigationFailed(in webView: WKWebView, error: Error) {\n        print("FIXTURE failure",(error as NSError).code)')
source=source.replace('    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {', '    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {\n        print("FIXTURE provisional",(error as NSError).code,tab(for:webView)?.currentNavigation === navigation)')
harness=(root/'Tests/BrowserPerformanceHarness.swift.inc').read_text()
if 'private func saveSessionTabs(wait:' not in source: harness=harness.replace('saveSessionTabs(wait: true)','saveSessionTabs()')
source+='\n'+harness+'\nextension BrowserApp { static let performanceStore = WKWebsiteDataStore.nonPersistent() }\n'
profile_copy=work/'ChromeImport.swift'
profile_source=sourcefile('ChromeImport.swift').read_text()
profile_start=profile_source.index('    static var fileURL: URL {')
profile_end=profile_source.index('    static func load(',profile_start)
profile_source=profile_source[:profile_start]+\
    '    static var fileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("webby-test-profiles-" + String(ProcessInfo.processInfo.processIdentifier) + ".json") }\n\n'+profile_source[profile_end:]
profile_copy.write_text(profile_source)
copy=work/'BrowserApp.swift';copy.write_text(source)
download_copy=work/'BrowserDownloads.swift'
download_copy.write_text(sourcefile('BrowserDownloads.swift').read_text()+'\n'+(root/'Tests/DownloadHarness.swift.inc').read_text())
workbench_copy=work/'CodeWorkbench.swift'
workbench_source=sourcefile('CodeWorkbench.swift').read_text().replace('private var process: Process?', 'fileprivate var process: Process?').replace('private var clients =', 'fileprivate var clients =')
workbench_copy.write_text(workbench_source+'\n'+(root/'Tests/CodeWorkbenchHarness.swift.inc').read_text())
identity_copy=work/'IDEIdentity.swift'
identity_copy.write_text(sourcefile('IDEIdentity.swift').read_text()+'\n'+(root/'Tests/IDEProjectWidgetHarness.swift.inc').read_text())
codex_copy=work/'CodexAppWidgets.swift'
codex_copy.write_text(sourcefile('CodexAppWidgets.swift').read_text()+'\n'+(root/'Tests/CodexAppWidgetHarness.swift.inc').read_text())
wallpaper_copy=work/'BrowserWallpaper.swift'
wallpaper_copy.write_text(sourcefile('BrowserWallpaper.swift').read_text()+'\n'+(root/'Tests/WallpaperHarness.swift.inc').read_text())
menu_copy=work/'BrowserMenuBar.swift'
menu_copy.write_text(sourcefile('BrowserMenuBar.swift').read_text()+'\n'+(root/'Tests/BrowserMenuBarHarness.swift.inc').read_text())
widget_copy=work/'WidgetCanvas.swift'
widget_copy.write_text(sourcefile('WidgetCanvas.swift').read_text().replace('private final class GlassWidgetCard', 'final class GlassWidgetCard')+'\n'+(root/'Tests/WidgetGlassHarness.swift.inc').read_text())
app=work/'WebbyTests.app'
mac=app/'Contents/MacOS';mac.mkdir(parents=True,exist_ok=True)
resources=app/'Contents/Resources'
if not resources.exists(): shutil.copytree(root/'Webby.app/Contents/Resources',resources)
(resources/'WidgetBrands').mkdir(parents=True,exist_ok=True)
for asset in (root/'WidgetBrands').iterdir(): shutil.copy2(asset,resources/'WidgetBrands'/asset.name)
(resources/'Fonts/Geist').mkdir(parents=True,exist_ok=True)
for font in (root/'Fonts/Geist').iterdir(): shutil.copy2(font,resources/'Fonts/Geist'/font.name)
for name in ['FastRules.json','VideoControls.js','GeistPage.js','glass-page.js','PasswordFieldProbe.js','GooglePromptFilter.js','ChromeTone.js','ChatGPTWidget.js','LinkPreview.js','SchoologyDark.js']:
    shutil.copy2(sourcefile(name),resources/name)
optimization=os.environ.get('WEBBY_TEST_OPTIMIZATION','-Onone')
plistlib.dump({'WebbyTestOptimization':optimization,'CFBundleIdentifier':'local.webby.performance-tests','CFBundleExecutable':'Webby','CFBundleName':'Webby Performance Tests','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0'},(app/'Contents/Info.plist').open('wb'))
cache=work/'module-cache';cache.mkdir(exist_ok=True)
obj=work/'PTYLauncher.o'
subprocess.run(['clang','-O2','-target','arm64-apple-macos14.0','-c',str(root/'PTYLauncher.c'),'-o',str(obj)],check=True)
files=list(dict.fromkeys(re.findall(r'"\$script_dir/([^"\n]+\.swift)"',(root/'build.sh').read_text())))
replacements = {
    'BrowserApp.swift': copy, 'ChromeImport.swift': profile_copy,
    'IDEIdentity.swift': identity_copy, 'CodeWorkbench.swift': workbench_copy,
    'WidgetCanvas.swift': widget_copy, 'BrowserMenuBar.swift': menu_copy,
    'CodexAppWidgets.swift': codex_copy, 'BrowserWallpaper.swift': wallpaper_copy,
    'BrowserDownloads.swift': download_copy,
}
files = [str(replacements.get(f, sourcefile(f))) for f in files if f not in {'CompileRules.swift','WebbyCLI.swift'}]
args=['swiftc',optimization,'-parse-as-library','-target','arm64-apple-macos14.0','-module-cache-path',str(cache)]
if os.environ.get('WEBBY_TEST_WMO') == '1': args+=['-whole-module-optimization']
if 'private func openAgentTab()' in source: args+=['-D','WEBBY_TEST_AGENT']
bridge=work/'ChromiumBridge.o'
subprocess.run(['clang++','-std=c++20','-fobjc-arc','-O2','-target','arm64-apple-macos14.0','-I',str(root/'Vendor/CEF'),'-c',str(sourcefile('ChromiumBridge.mm')),'-o',str(bridge)],check=True)
args+=['-import-objc-header',str(sourcefile('ChromiumBridge.h'))]
for framework in ['AppKit','WebKit','AVFoundation','Security','CryptoKit','IOKit','JavaScriptCore','CoreImage','ImageIO','Carbon','WidgetKit']:args+=['-framework',framework]
background_target=root.parent/'work/code-background-target'
subprocess.run([str(Path.home()/'.cargo/bin/cargo'),'build','--release','--locked','--offline','--target','aarch64-apple-darwin','--manifest-path',str(root/'Vendor/CodeBackground/Cargo.toml'),'--target-dir',str(background_target)],check=True)
args+=files+[str(obj),str(bridge),str(background_target/'aarch64-apple-darwin/release/libwebby_code_background.a'),'-lc++','-lsqlite3','-o',str(mac/'Webby')]
def capture(command):
    result=subprocess.run(command,capture_output=True,text=True)
    return {'exit':result.returncode,'output':result.stdout.strip(),'error':result.stderr.strip()}
manifest={'builtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'optimization':optimization,'swiftArguments':args,'hardware':capture(['sysctl','-n','hw.model']),
    'os':platform.platform(),'power':capture(['pmset','-g','batt']),
    'thermal':capture(['pmset','-g','therm']), 'compiler':capture(['swiftc','--version']),
    'commit':capture(['git','-C',str(root),'rev-parse','HEAD']),
    'sources':{str(Path(f).relative_to(root)) if Path(f).is_relative_to(root) else Path(f).name:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},
    'bridge':{n:hashlib.sha256(sourcefile(n).read_bytes()).hexdigest() for n in ['ChromiumBridge.h','ChromiumBridge.mm']},
    'scripts':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(resources.glob('*.js'))}}
(work/'build-manifest.json').write_text(json.dumps(manifest,indent=2))
subprocess.run(args,check=True)
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
print(app)
