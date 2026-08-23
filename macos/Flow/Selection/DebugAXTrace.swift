#if DEBUG
import Foundation

enum DebugAXTrace {
    static let notificationName = Notification.Name("com.hojmoseit.flow.debug.capture-selection")
    private static let prefix = "[DEBUG-AXFULL]"
    private static let queue = DispatchQueue(label: "com.hojmoseit.flow.debug-ax-trace")
    private static let startedAt = ProcessInfo.processInfo.systemUptime

    static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flow-axfull.jsonl")
    }

    static func reset() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
        record("flow_started", fields: ["pid": "\(ProcessInfo.processInfo.processIdentifier)"])
    }

    static func record(_ event: String, fields: [String: String] = [:]) {
        queue.sync {
            var payload = fields
            payload["tag"] = prefix
            payload["event"] = event
            payload["t_ms"] = String(
                format: "%.1f",
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: lineData)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        }
    }
}
#endif
