import AppKit
import IOKit.ps
import Darwin

struct SpotifySnapshot: Codable, Equatable {
    let title: String
    let artist: String
    let album: String
    let artworkURL: String
    let position: Double
    let duration: Double
    let isPlaying: Bool
}

enum MusicCommand { case previous, toggle, next }

enum SpotifyBridge {
    private static let lastTrackKey = "webbyLastSpotifyTrack"

    private static var pausedLastTrack: SpotifySnapshot? {
        lastTrack.map { SpotifySnapshot(title: $0.title, artist: $0.artist, album: $0.album,
                                        artworkURL: $0.artworkURL, position: $0.position,
                                        duration: $0.duration, isPlaying: false) }
    }

    static var lastTrack: SpotifySnapshot? {
        guard let data = UserDefaults.standard.data(forKey: lastTrackKey) else { return nil }
        return try? JSONDecoder().decode(SpotifySnapshot.self, from: data)
    }

    static func read() -> SpotifySnapshot? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            return pausedLastTrack
        }
        let script = """
        tell application id "com.spotify.client"
            if player state is stopped then return ""
            set t to current track
            set cover to ""
            try
                set cover to artwork url of t as text
            end try
            set playback to "paused"
            if player state is playing then set playback to "playing"
            set separator to ASCII character 30
            return (name of t) & separator & (artist of t) & separator & (album of t) & separator & cover & separator & (player position as text) & separator & (duration of t as text) & separator & playback
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              !result.isEmpty else { return pausedLastTrack }
        let fields = result.components(separatedBy: String(UnicodeScalar(30)!))
        guard fields.count == 7 else { return lastTrack }
        let rawDuration = Double(fields[5]) ?? 0
        let track = SpotifySnapshot(title: fields[0], artist: fields[1], album: fields[2],
                                    artworkURL: fields[3], position: Double(fields[4]) ?? 0,
                                    duration: rawDuration > 10_000 ? rawDuration / 1000 : rawDuration,
                                    isPlaying: fields[6].lowercased().contains("playing"))
        if let data = try? JSONEncoder().encode(track) { UserDefaults.standard.set(data, forKey: lastTrackKey) }
        return track
    }

    static func send(_ command: MusicCommand) {
        let instruction: String
        switch command {
        case .previous: instruction = "previous track"
        case .toggle: instruction = "playpause"
        case .next: instruction = "next track"
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"com.spotify.client\" to \(instruction)")?.executeAndReturnError(&error)
    }
}

struct BatterySnapshot {
    let percentage: Int
    let charging: Bool
    let timeRemaining: Int?
    let name: String
}

enum WidgetSystemData {
    static func battery() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            return BatterySnapshot(percentage: Int(Double(current) / Double(maximum) * 100),
                                   charging: charging, timeRemaining: minutes.flatMap { $0 >= 0 ? $0 : nil },
                                   name: description[kIOPSNameKey] as? String ?? "Mac")
        }
        return nil
    }

    static func cpuTicks() -> [UInt64]? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return [UInt64(load.cpu_ticks.0), UInt64(load.cpu_ticks.1),
                UInt64(load.cpu_ticks.2), UInt64(load.cpu_ticks.3)]
    }

    static func memory() -> String {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return "—" }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let usedPages = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
        let used = usedPages * Double(vm_kernel_page_size) / 1_073_741_824
        return String(format: "%.1f / %.0f GB", min(used, total), total)
    }

    static func disk() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity else { return "—" }
        return "\(Int(Double(total - available) / 1_000_000_000)) / \(Int(Double(total) / 1_000_000_000)) GB"
    }

    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let item = current {
            let address = item.pointee.ifa_addr
            if address?.pointee.sa_family == UInt8(AF_LINK),
               (item.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = item.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            current = item.pointee.ifa_next
        }
        return (received, sent)
    }

    static func recentDownloads() -> [URL] {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let urls = try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                      (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            .prefix(5).map { $0 }
    }
}

struct ExpressionCalculator {
    private let characters: [Character]
    private var index = 0

    init(_ expression: String) { characters = Array(expression.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")) }

    mutating func evaluate() -> Double? {
        guard let answer = sum() else { return nil }
        spaces()
        return index == characters.count && answer.isFinite ? answer : nil
    }

    private mutating func spaces() { while index < characters.count && characters[index].isWhitespace { index += 1 } }
    private mutating func eat(_ c: Character) -> Bool {
        spaces()
        guard index < characters.count && characters[index] == c else { return false }
        index += 1
        return true
    }
    private mutating func sum() -> Double? {
        guard var result = product() else { return nil }
        while true {
            if eat("+") { guard let rhs = product() else { return nil }; result += rhs }
            else if eat("-") { guard let rhs = product() else { return nil }; result -= rhs }
            else { return result }
        }
    }
    private mutating func product() -> Double? {
        guard var result = signedPower() else { return nil }
        while true {
            if eat("*") { guard let rhs = signedPower() else { return nil }; result *= rhs }
            else if eat("/") { guard let rhs = signedPower(), rhs != 0 else { return nil }; result /= rhs }
            else { return result }
        }
    }
    private mutating func signedPower() -> Double? {
        if eat("+") { return signedPower() }
        if eat("-") { return signedPower().map { -$0 } }
        return power()
    }
    private mutating func power() -> Double? {
        guard let base = primary() else { return nil }
        if eat("^") { guard let exponent = signedPower() else { return nil }; return pow(base, exponent) }
        return base
    }
    private mutating func primary() -> Double? {
        if eat("(") { guard let result = sum(), eat(")") else { return nil }; return result }
        spaces()
        let start = index
        while index < characters.count && (characters[index].isNumber || characters[index] == ".") { index += 1 }
        guard index > start else { return nil }
        return Double(String(characters[start..<index]))
    }
}
