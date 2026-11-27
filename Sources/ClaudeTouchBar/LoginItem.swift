import Foundation
import ServiceManagement

/// "Launch at Login" that works on every supported macOS.
/// macOS 13+ uses SMAppService; older systems (Catalina – Monterey) fall back
/// to a per-user LaunchAgent that opens the app bundle at login.
enum LoginItem {
    private static let label = "com.claudetouchbar.app.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func toggle() throws {
        if isEnabled { try disable() } else { try enable() }
    }

    static func enable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
            return
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }

    static func disable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
            return
        }
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}
