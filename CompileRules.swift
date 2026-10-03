import Foundation
import WebKit

guard CommandLine.arguments.count == 3 else { exit(2) }
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let json = try String(contentsOf: source, encoding: .utf8)
guard let store = WKContentRuleListStore(url: directory) else { exit(2) }

var finished = false
var succeeded = false
store.compileContentRuleList(forIdentifier: "FastRules", encodedContentRuleList: json) { list, error in
    if let error { fputs("Rule compilation failed: \(error)\n", stderr) }
    succeeded = list != nil
    finished = true
}

let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
if !finished || !succeeded { exit(1) }
