import Foundation
import Darwin

@main struct WebbyCLI {
    static let commands: [String: [String]] = [
        "status": [], "profiles": [], "tabs": [], "downloads": [], "agent": [],
        "use-profile": ["profile"], "open": ["url", "profile", "engine"],
        "focus": ["tab"], "wait": ["tab"], "close": ["tab"], "navigate": ["tab", "url"],
        "back": ["tab"], "forward": ["tab"], "reload": ["tab"],
        "snapshot": ["tab"], "screenshot": ["tab"], "text": ["tab"], "eval": ["tab", "script"],
        "click": ["tab", "selector"], "fill": ["tab", "selector", "value"],
        "press": ["tab", "key"], "scroll": ["tab", "y"], "download": ["tab", "url"]
    ]
    static let optional: Set<String> = ["open", "scroll"]

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, !["help", "-h", "--help"].contains(command) else {
                print("Webby local browser control. Open Webby Agent (⌘⇧J) and enable Local CLI.")
                print("Commands return JSON. Use IDs from tabs and profiles, or @active for the active tab.")
                for (name, keys) in commands.sorted(by: { $0.key < $1.key }) {
                    let arguments = keys.enumerated().map { index, key in
                        optional.contains(name) && index > 0 ? "[\(key)]" : "<\(key)>"
                    }.joined(separator: " ")
                    print("  webby \(name) \(arguments)")
                }
                print("  webby json '<request>'    or    webby json -  (read stdin)")
                print("Engine values: webkit, chromium. Use - for the current profile in open.")
                return
            }
            let request: Data
            if command == "json", args.count == 2 {
                request = args[1] == "-" ? FileHandle.standardInput.readData(ofLength: WebbyAgentSocket.limit + 1) : Data(args[1].utf8)
            } else {
                guard let keys = commands[command], args.count - 1 <= keys.count,
                      args.count - 1 >= (optional.contains(command) ? 1 : keys.count) else {
                    throw WebbyAutomationError.message("Invalid arguments. Run webby help.")
                }
                var object = Dictionary(uniqueKeysWithValues: zip(keys, args.dropFirst()))
                if object["profile"] == "-" { object.removeValue(forKey: "profile") }
                object["command"] = command
                request = try WebbyAgentSocket.encode(object)
            }
            guard request.count <= WebbyAgentSocket.limit,
                  let parsed = try JSONSerialization.jsonObject(with: request) as? [String: Any] else {
                throw WebbyAutomationError.message("Expected a JSON request object.")
            }
            let fd = try WebbyAgentSocket.connect()
            defer { close(fd) }
            try WebbyAgentSocket.write(WebbyAgentSocket.encode(parsed), to: fd)
            let response = try WebbyAgentSocket.read(fd)
            FileHandle.standardOutput.write(response + Data([10]))
            let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            if decoded?["ok"] as? Bool != true { exit(1) }
        } catch {
            FileHandle.standardOutput.write(WebbyAgentSocket.envelope(.failure(error)) + Data([10]))
            exit(1)
        }
    }
}
