import Foundation
import Darwin

@MainActor final class WebbyAgentListener {
    typealias Reply = (Result<Any, Error>) -> Void
    typealias Handler = ([String: Any], @escaping Reply) -> Void
    private let source: DispatchSourceRead

    init(handler: @escaping Handler) throws {
        try WebbyAgentSocket.checkDirectory(create: true)
        // Lock the endpoint for the lifetime of the listener. Only the lock
        // holder may clean up a stale socket left by a crashed Webby.
        let lock = open(WebbyAgentSocket.directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WebbyAutomationError.message("Could not lock the Webby socket.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw WebbyAutomationError.message("Another Webby instance is serving the Local CLI.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw WebbyAutomationError.message("Could not create the Webby socket.") }
        _ = unlink(WebbyAgentSocket.path)
        WebbyAgentSocket.configure(fd, seconds: 5)
        guard WebbyAgentSocket.address({ Darwin.bind(fd, $0, $1) }) == 0,
              chmod(WebbyAgentSocket.path, 0o600) == 0, listen(fd, 8) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); unlink(WebbyAgentSocket.path); close(lock)
            throw WebbyAutomationError.message("Could not listen on the Webby socket.")
        }
        let queue = DispatchQueue(label: "Webby.LocalCLI")
        let io = DispatchQueue(label: "Webby.LocalCLI.IO", attributes: .concurrent)
        let slots = DispatchSemaphore(value: 8)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            guard WebbyAgentSocket.peerIsLocalUser(peer), slots.wait(timeout: .now()) == .success else {
                close(peer); return
            }
            _ = fcntl(peer, F_SETFL, 0)
            WebbyAgentSocket.configure(peer, seconds: 5)
            io.async {
                let finish: Reply = { result in
                    let data = WebbyAgentSocket.envelope(result)
                    io.async {
                        defer { close(peer); slots.signal() }
                        try? WebbyAgentSocket.write(data, to: peer)
                    }
                }
                do {
                    let data = try WebbyAgentSocket.read(peer, limit: 256 * 1024)
                    guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw WebbyAutomationError.message("Expected a JSON request object.")
                    }
                    DispatchQueue.main.async {
                        // Some pages never resolve a Promise. Release the CLI
                        // slot once, whether the engine replies or times out.
                        let reply = WebbyAgentReply(finish)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                            reply.send(.failure(WebbyAutomationError.message("Browser command timed out.")))
                        }
                        handler(request, reply.send)
                    }
                } catch { finish(.failure(error)) }
            }
        }
        source.setCancelHandler { close(fd); unlink(WebbyAgentSocket.path); close(lock) }
        source.resume()
    }

    deinit { source.cancel() }
}

@MainActor private final class WebbyAgentReply {
    private var callback: WebbyAgentListener.Reply?
    init(_ callback: @escaping WebbyAgentListener.Reply) { self.callback = callback }
    func send(_ result: Result<Any, Error>) {
        let reply = callback
        callback = nil
        reply?(result)
    }
}
