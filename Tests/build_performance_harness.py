from pathlib import Path
import re, subprocess, plistlib, shutil, sys, os
root=Path(__file__).resolve().parents[1]
work=Path(sys.argv[1]).resolve(); work.mkdir(parents=True,exist_ok=True)
source=(root/'BrowserApp.swift').read_text()
source=source.replace('    private func scheduleSpaceSave() {','    private func scheduleSpaceSave() {\n        return // Test copy never writes real browser profiles.',1)
source=source.replace('    private func loadCookieHosts(for space: BrowserSpace) {','    private func loadCookieHosts(for space: BrowserSpace) {\n        return // Never read personal cookies in a fixture.',1)
source=source.replace('configuration.websiteDataStore = ownerSpace(for: tab).dataStore','configuration.websiteDataStore = .nonPersistent()')
source=source.replace('    static func main() {','    static func main() {\n        if CommandLine.arguments.count == 3 {\n            BrowserApp.launchPerformanceChecks(base: CommandLine.arguments[1], output: URL(fileURLWithPath: CommandLine.arguments[2])); return\n        }',1)
# Fixture-only traces never run against personal tabs.
source=source.replace('    private func navigationFailed(in webView: WKWebView, error: Error) {', '    private func navigationFailed(in webView: WKWebView, error: Error) {\n        print("FIXTURE failure",(error as NSError).code)')
source=source.replace('    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {', '    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {\n        print("FIXTURE provisional",(error as NSError).code,tab(for:webView)?.currentNavigation === navigation)')
source+='\n'+(root/'Tests/BrowserPerformanceHarness.swift.inc').read_text()
copy=work/'BrowserApp.swift';copy.write_text(source)
menu_copy=work/'BrowserMenuBar.swift'
menu_copy.write_text((root/'BrowserMenuBar.swift').read_text()+'\n'+(root/'Tests/BrowserMenuBarHarness.swift.inc').read_text())
widget_copy=work/'WidgetCanvas.swift'
widget_copy.write_text((root/'WidgetCanvas.swift').read_text()+'\n'+(root/'Tests/WidgetGlassHarness.swift.inc').read_text())
app=work/'WebbyTests.app'
mac=app/'Contents/MacOS';mac.mkdir(parents=True,exist_ok=True)
resources=app/'Contents/Resources'
if not resources.exists(): shutil.copytree(root/'Webby.app/Contents/Resources',resources)
for name in ['glass-page.js','PasswordFieldProbe.js','GooglePromptFilter.js','ChromeTone.js']:
    shutil.copy2(root/name,resources/name)
plistlib.dump({'CFBundleIdentifier':'local.webby.performance-tests','CFBundleExecutable':'Webby','CFBundleName':'Webby Performance Tests','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0'},(app/'Contents/Info.plist').open('wb'))
cache=work/'module-cache';cache.mkdir(exist_ok=True)
obj=work/'PTYLauncher.o'
subprocess.run(['clang','-O2','-target','arm64-apple-macos13.0','-c',str(root/'PTYLauncher.c'),'-o',str(obj)],check=True)
files=re.findall(r'"\$script_dir/([^"\n]+\.swift)"',(root/'build.sh').read_text())
files=[str(copy if f=='BrowserApp.swift' else (widget_copy if f=='WidgetCanvas.swift' else (menu_copy if f=='BrowserMenuBar.swift' else root/f))) for f in files if f!='CompileRules.swift']
args=['swiftc',os.environ.get('WEBBY_TEST_OPTIMIZATION','-Onone'),'-parse-as-library','-target','arm64-apple-macos13.0','-module-cache-path',str(cache)]
for framework in ['AppKit','WebKit','AVFoundation','Security','CryptoKit','IOKit','JavaScriptCore','CoreImage','ImageIO','Carbon']:args+=['-framework',framework]
background_target=root.parent/'work/code-background-target'
subprocess.run([str(Path.home()/'.cargo/bin/cargo'),'build','--release','--offline','--manifest-path',str(root/'Vendor/CodeBackground/Cargo.toml'),'--target-dir',str(background_target)],check=True)
args+=files+[str(obj),str(background_target/'release/libwebby_code_background.a'),'-lc++','-lsqlite3','-o',str(mac/'Webby')]
subprocess.run(args,check=True)
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
print(app)
