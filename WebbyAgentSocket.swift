import Foundation
import Darwin

enum WebbyAutomationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum WebbyAgentSocket {
    static let limit = 8 * 1024 * 1024
    static var directory: String {
        if let directory = ProcessInfo.processInfo.environment["WEBBY_CLI_SOCKET_DIRECTORY"], directory.hasPrefix("/") {
            return directory
        }
        return "/private/tmp/webby-agent-\(getuid())"
    }
    static var path: String { directory + "/control.sock" }

    static func checkDirectory(create: Bool) throws {
        guard path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw WebbyAutomationError.message("Webby socket path is too long.")
        }
        if create { _ = mkdir(directory, 0o700) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw WebbyAutomationError.message("Open Webby Agent and enable Local CLI.")
        }
    }

    static func address(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32, seconds: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            _ = setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func peerIsLocalUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func connect() throws -> Int32 {
        try checkDirectory(create: false)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw WebbyAutomationError.message("Webby Local CLI is offline.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WebbyAutomationError.message("Could not open local connection.") }
        configure(fd, seconds: 35)
        guard address({ Darwin.connect(fd, $0, $1) }) == 0, peerIsLocalUser(fd) else {
            close(fd)
            throw WebbyAutomationError.message("Could not connect to Webby. Check Local CLI in the Agent tab.")
        }
        return fd
    }

    static func read(_ fd: Int32, limit: Int = limit) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            let chunk = buffer.prefix(count)
            if let end = chunk.firstIndex(of: 10) {
                data.append(contentsOf: chunk[..<end])
                if data.count <= limit { return data }
                break
            }
            data.append(contentsOf: chunk)
        }
        throw WebbyAutomationError.message("Incomplete, timed out, or oversized Webby response.")
    }

    static func write(_ data: Data, to fd: Int32) throws {
        var line = data
        line.append(10)
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WebbyAutomationError.message("Webby connection closed.") }
                offset += count
            }
        }
    }

    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func envelope(_ result: Result<Any, Error>) -> Data {
        switch result {
        case .success(let value):
            if let data = try? encode(["ok": true, "result": value]), data.count < limit { return data }
            return envelope(.failure(WebbyAutomationError.message("Webby result is too large or cannot be represented as JSON.")))
        case .failure(let error):
            return (try? encode(["ok": false, "error": String(error.localizedDescription.prefix(4000))])) ?? Data()
        }
    }
}
