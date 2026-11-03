"""Exercise the production set store against isolated defaults, not user profiles."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'BrowserWallpaper.swift').read_text()
model=source[source.index('private struct WallpaperSettings'):source.index('private final class WallpaperSurface')]
checks=r'''
let suite="local.webby.wallpaper-sets-tests."+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer {defaults.removePersistentDomain(forName:suite)}
let a=UUID().uuidString,b=UUID().uuidString
private var first=WallpaperSettings();first.path="/fixture/original-a.png";first.effect=2;first.blur=9
private var second=WallpaperSettings();second.path="/fixture/original-b.mov";second.kind="video";second.fade=3
let originalA=try JSONEncoder().encode(first),originalB=try JSONEncoder().encode(second)
defaults.set(originalA,forKey:"webbyWallpaper."+a)
defaults.set(originalB,forKey:"webbyWallpaper."+b)
defaults.set(true,forKey:"webbyWallpaperFullWindow."+a)
defaults.set(0,forKey:"webbyWallpaperTabBlurScope."+b)
defaults.set(0.35,forKey:"webbyWallpaperTabBlurStrength."+b)
let original=WallpaperSetStore.load(defaults)
precondition(original.sets.count==1)
precondition(WallpaperSetStore.nextID(defaults)==nil)
WallpaperSetStore.duplicate(name:"Second pair",defaults:defaults)
let newID=WallpaperSetStore.load(defaults).active
precondition(newID != original.active)
precondition(WallpaperSetStore.nextID(defaults)==original.active)
first.path="/fixture/new-a.png";first.effect=4
let changedA=try JSONEncoder().encode(first)
defaults.set(changedA,forKey:"webbyWallpaper."+a)
defaults.set(false,forKey:"webbyWallpaperFullWindow."+a)
WallpaperSetStore.update(defaults)
precondition(WallpaperSetStore.references("/fixture/original-a.png",defaults:defaults))
precondition(WallpaperSetStore.references("/fixture/new-a.png",defaults:defaults))
let previouslyBlank=UUID().uuidString
defaults.set(changedA,forKey:"webbyWallpaper."+previouslyBlank)
WallpaperSetStore.select(original.active,defaults:defaults)
precondition(defaults.data(forKey:"webbyWallpaper."+previouslyBlank)==nil)
precondition(defaults.data(forKey:"webbyWallpaper."+a)==originalA)
precondition(WallpaperSetStore.nextID(defaults)==newID)
precondition(defaults.data(forKey:"webbyWallpaper."+b)==originalB)
precondition(defaults.bool(forKey:"webbyWallpaperFullWindow."+a))
precondition(defaults.integer(forKey:"webbyWallpaperTabBlurScope."+b)==0)
precondition(abs(defaults.double(forKey:"webbyWallpaperTabBlurStrength."+b)-0.35)<0.001)
WallpaperSetStore.select(newID,defaults:defaults)
precondition(defaults.data(forKey:"webbyWallpaper."+a)==changedA)
precondition(!defaults.bool(forKey:"webbyWallpaperFullWindow."+a))
WallpaperSetStore.rename("Night pair",defaults:defaults)
let reopened=UserDefaults(suiteName:suite)!
precondition(WallpaperSetStore.load(reopened).sets.first(where:{$0.id==newID})?.name=="Night pair")
WallpaperSetStore.select(UUID(),defaults:defaults)
precondition(WallpaperSetStore.load(defaults).active==newID)
print("PASS: original pair retained, duplicate edits isolated, both profile wallpapers/effects restored, tab glass restored, referenced assets retained, rename/restart persistence, unknown selection ignored")
'''
with tempfile.TemporaryDirectory(prefix='webby-wallpaper-sets-') as folder:
    path=Path(folder)/'main.swift';path.write_text('import Foundation\n'+model+'\n'+checks)
    binary=Path(folder)/'checks'
    subprocess.run(['swiftc','-module-cache-path',str(Path(folder)/'modules'),str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
