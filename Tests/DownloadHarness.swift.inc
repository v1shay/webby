extension BrowserDownloads {
    var testEntries: [(name: String, url: URL?, status: String)] { entries.map { ($0.name, $0.url, $0.status) } }
    var testRetainedCount: Int { retainedDownloads.count }
    func testCancelActive() {
        guard let index = active.values.first else { return }
        let item = NSMenuItem(); item.representedObject = entries[index].id
        cancelDownload(item)
    }
}
