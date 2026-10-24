import AppKit

@main struct FaviconStoreTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webby-favicon-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BrowserFaviconStore(directory: root)
        let profile = UUID(), other = UUID()
        let url = URL(string: "https://example.test/inbox")!
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x:0,y:0,width:128,height:128).fill(); image.unlockFocus()
        first.remember(image, for: url, profile: profile)
        for _ in 0..<100 {
            if ((try? FileManager.default.contentsOfDirectory(atPath: root.path).count) ?? 0) > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let restarted = BrowserFaviconStore(directory: root)
        func load(_ target: URL, _ owner: UUID) async -> NSImage? {
            await withCheckedContinuation { continuation in
                restarted.load(for: target, profile: owner) { continuation.resume(returning: $0) }
            }
        }
        let restored = await load(URL(string:"https://example.test/other")!, profile)
        precondition(restored != nil && restored!.cgImage(forProposedRect:nil,context:nil,hints:nil)?.width == 64, "Disk restore failed")
        let isolated = await load(url, other)
        precondition(isolated == nil, "Profile icon cache leaked")
        let differentOrigin = await load(URL(string:"https://example.test:444/")!, profile)
        precondition(differentOrigin == nil, "Distinct origins mixed")
        let unsupported = await load(URL(string:"file:///tmp/icon")!, profile)
        precondition(unsupported == nil, "Unsupported scheme cached")
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey])
        precondition(files.count == 1)
        let bytes = try files[0].resourceValues(forKeys:[.fileSizeKey]).fileSize!
        precondition(bytes < 65536)
        // Exercise the asynchronous disk bound without network or browser state.
        let padding = Data(repeating: 0, count: 20000)
        for index in 0..<520 { try padding.write(to: root.appendingPathComponent("fixture-\(index).png")) }
        try await Task.sleep(nanoseconds: 5_500_000_000)
        let retained = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey])
        let total = try retained.reduce(0) { try $0 + ($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) }
        precondition(retained.count <= 512 && total <= 8 * 1024 * 1024, "Disk budget exceeded")
        print("PASS: disk budget \(retained.count) files / \(total) bytes")
        print("PASS: fresh-store disk restore, 64px thumbnail, profile/origin isolation, unsupported URL; cached PNG \(bytes) bytes")
    }
}
