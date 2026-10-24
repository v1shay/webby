import AppKit
@main struct CacheTests {
 @MainActor static func main() {
 let defaults = UserDefaults.standard
 let trackKey="webbyLastSpotifyTrack", artKey="webbyLastSpotifyArtwork.v1"
 let oldTrack=defaults.object(forKey:trackKey),oldArt=defaults.object(forKey:artKey)
 defer {defaults.set(oldTrack,forKey:trackKey);defaults.set(oldArt,forKey:artKey)}
 let track=SpotifySnapshot(title:"Fixture",artist:"Artist",album:"Album",artworkURL:"https://fixture/cover",position:42,duration:180,isPlaying:true)
 defaults.set(try! JSONEncoder().encode(track),forKey:trackKey)
 assert(SpotifyBridge.lastTrack==track)
 assert(SpotifyBridge.pausedLastTrack?.isPlaying==false)
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1000,pixelsHigh:1000,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 let data=bitmap.representation(using:.png,properties:[:])!
 let image=SpotifyArtworkCache.save(data,url:track.artworkURL)!
 assert(image.size.width==640 && image.size.height==640)
 assert(SpotifyArtworkCache.read(track.artworkURL) != nil)
 assert(SpotifyArtworkCache.read("https://fixture/other")==nil)
 assert(SpotifyArtworkCache.save(Data([1,2,3]),url:"bad")==nil)
 assert(SpotifyArtworkCache.read(track.artworkURL) != nil)
 print("PASS: persisted track, paused startup, bounded 640px cover, URL isolation, corrupt cover retention")
 }
}
