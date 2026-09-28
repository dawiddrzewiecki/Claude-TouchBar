import Foundation
import notify

public enum Store {
    public static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["CCTB_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClaudeTouchBar", isDirectory: true)
    }()

    public static var sessionsDirectory: URL { supportDirectory.appendingPathComponent("sessions", isDirectory: true) }
    public static var metaDirectory: URL { supportDirectory.appendingPathComponent("meta", isDirectory: true) }
    public static func metaFile(_ id: String) -> URL {
        metaDirectory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    public static let changeNotification = "com.claudetouchbar.changed"
    public static func postChange() { notify_post(changeNotification) }

    public static var requestsDirectory: URL { supportDirectory.appendingPathComponent("requests", isDirectory: true) }
    public static func requestFile(_ id: String) -> URL {
        requestsDirectory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    public static func responseFile(_ id: String) -> URL {
        requestsDirectory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".response.json")
    }
    public static let responseNotification = "com.claudetouchbar.response"
    public static var appPidFile: URL { supportDirectory.appendingPathComponent("app.pid") }

    public static func appIsRunning() -> Bool {
        guard let text = try? String(contentsOf: appPidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func clearRequests(sessionId: String, toolUseId: String? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: requestsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".response.json") {
            guard let r = read(PendingRequest.self, from: file), r.sessionId == sessionId else { continue }
            if let toolUseId, r.id != toolUseId { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: responseFile(r.id))
        }
    }

    public static var usageFile: URL { supportDirectory.appendingPathComponent("usage.json") }
    static var lockFile: URL { supportDirectory.appendingPathComponent(".lock") }

    public static var claudeSessionsDirectory: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("sessions", isDirectory: true)
    }

    public static func sessionFile(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return sessionsDirectory.appendingPathComponent("\(safe).json")
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metaDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        ensureDirectories()
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }
}
