"""Exercise all download bookkeeping using disposable files and a local server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"download lifecycle fixture\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Disposition", 'attachment; filename="probe.txt"')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

checks = r'''
extension BrowserDownloads {
    func cancelForTest(_ id: UUID) {
        let item = NSMenuItem(); item.representedObject = id; cancelDownload(item)
    }
    var sessionStartedForTest: Bool { sessionDownloads.values.contains { $0.task != nil } }
    var entryCountForTest: Int { entries.count }
}
@main struct DownloadLifecycleChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = URL(string: CommandLine.arguments[2])!
        let suite = "webby-download-lifecycle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let downloads = BrowserDownloads(destinationFolder: folder, defaults: defaults)
        func spin(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "Timed out")
        }
        let store = WKWebsiteDataStore.nonPersistent().httpCookieStore
        let cancelled = downloads.startGET(URLRequest(url: url), from: store, sourceURL: url, suggestedFilename: "probe.txt")
        spin { downloads.sessionStartedForTest }
        // Deliberately withhold the main-queue completion while its worker stores
        // the file, then cancel. This reliably exercises the completion race.
        let target = folder.appendingPathComponent("probe.txt")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: target.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(FileManager.default.fileExists(atPath: target.path))
        downloads.cancelForTest(cancelled)
        spin { !FileManager.default.fileExists(atPath: target.path) }
        precondition(!downloads.hasActiveDownloads)
        precondition(downloads.automationEntries.first?["status"] as? String == "Cancelled")
        var engineCancelled = false
        let engine = downloads.queueEngineDownload("engine.txt", onCancel: { id in
            engineCancelled = true
            downloads.finishEngineDownload(id, status: "Canceled")
        })
        downloads.cancelForTest(engine)
        precondition(engineCancelled && !downloads.hasActiveDownloads)
        for index in 0..<35 {
            downloads.startGET(URLRequest(url: url), from: store, sourceURL: url, suggestedFilename: "probe.txt", isPrivate: index == 34)
            spin { !downloads.hasActiveDownloads }
        }
        precondition(downloads.entryCountForTest == 30)
        precondition(defaults.stringArray(forKey: "browserRecentDownloads")?.count == 29)
        precondition(downloads.automationEntries.first?["status"] as? String == "Finished")
        print("PASS: cancellation after file move cleans up, engine Cancel dispatches, session history stays bounded, private download not persisted")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="webby-download-lifecycle-") as work:
    work = Path(work)
    # Compile the actual implementation into the same file to inspect only its
    # private state; production access control and APIs stay unchanged.
    stubs = (root / "Tests/DownloadIntegration.swift").read_text().split("@MainActor final class DownloadTest")[0]
    source = work / "main.swift"
    source.write_text(stubs + (root / "BrowserDownloads.swift").read_text() + checks)
    binary = work / "checks"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(binary), str(work / "downloads"), f"http://127.0.0.1:{server.server_port}/file"], check=True, timeout=60)
    finally:
        server.shutdown()
        server.server_close()
