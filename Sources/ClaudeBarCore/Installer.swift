import Foundation

public enum Installer {
    public static let hookEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "PreCompact", "Stop", "StopFailure",
    ]
    static let marker = "cctb"

    public static var settingsURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json")
    }

    static var chainedStatusLineURL: URL { Store.supportDirectory.appendingPathComponent("statusline-original.json") }

    public enum Status: Equatable { case notInstalled, installed, partial }

    public static func status() -> Status {
        let settings = loadSettings()
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let installed = hookEvents.filter { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
        let statusLine = (settings["statusLine"] as? [String: Any]).map(isOursCommand) ?? false
        if installed.count == hookEvents.count && statusLine { return .installed }
        return installed.isEmpty && !statusLine ? .notInstalled : .partial
    }

    public static func install(helperPath: String, includeStatusLine: Bool = true) throws {
        var settings = loadSettings()
        try backup()
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            let timeout = event == "PermissionRequest" ? 660 : 5
            var group: [String: Any] = ["hooks": [["type": "command", "command": "\(quoted) hook", "timeout": timeout]]]
            if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"].contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        if includeStatusLine {
            if let existing = settings["statusLine"] as? [String: Any], !isOursCommand(existing) {
                Store.ensureDirectories()
                let data = try JSONSerialization.data(withJSONObject: existing)
                try data.write(to: chainedStatusLineURL, options: .atomic)
            }
            settings["statusLine"] = ["type": "command", "command": "\(quoted) statusline", "padding": 0]
        }
        try save(settings)
    }

    public static func uninstall() throws {
        var settings = loadSettings()
        try backup()
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept = groups.filter { !isOurs($0) }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if let statusLine = settings["statusLine"] as? [String: Any], isOursCommand(statusLine) {
            if let data = try? Data(contentsOf: chainedStatusLineURL),
               let original = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings["statusLine"] = original
                try? FileManager.default.removeItem(at: chainedStatusLineURL)
            } else {
                settings["statusLine"] = nil
            }
        }
        try save(settings)
    }

    public static func chainedStatusLineCommand() -> String? {
        guard let data = try? Data(contentsOf: chainedStatusLineURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOursCommand)
    }

    static func isOursCommand(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains("/\(marker)'") || command.contains("/\(marker) ")
    }

    static func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func save(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    static func backup() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.cctb-backup-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: target)
    }
}
