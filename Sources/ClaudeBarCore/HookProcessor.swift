import Foundation

public enum HookProcessor {
    public static func apply(_ payload: [String: Any], to existing: SessionRecord?, now: Date = Date()) -> SessionRecord? {
        let event = payload["hook_event_name"] as? String ?? ""
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? existing?.cwd ?? FileManager.default.currentDirectoryPath
        var r = existing ?? SessionRecord(sessionId: sessionId, cwd: cwd, now: now)
        r.cwd = cwd
        r.updatedAt = now
        if let t = payload["transcript_path"] as? String { r.transcriptPath = t }

        func set(_ phase: Phase, _ activity: Activity? = nil, detail: String? = nil, message: String? = nil) {
            if r.phase != phase { r.phaseSince = now }
            r.phase = phase
            r.activity = activity
            r.detail = detail
            r.message = message
        }

        func startTurnIfNeeded() {
            if r.turnStartedAt == nil || r.phase == .completed || r.phase == .idle || r.phase == .error {
                r.turnStartedAt = now
                r.toolCount = 0
                r.inFlight = [:]
            }
        }

        func settleAfterTool(defaultActivity: Activity) {
            if let latest = r.inFlight.values.max(by: { $0.startedAt < $1.startedAt }) {
                set(.working, latest.activity, detail: latest.detail)
            } else {
                set(.working, defaultActivity)
            }
        }

        switch event {
        case "SessionStart":
            r.inFlight = [:]
            if r.phase != .working { set(.idle) }

        case "UserPromptSubmit":
            r.turnStartedAt = now
            r.toolCount = 0
            r.inFlight = [:]
            set(.working, .thinking)

        case "PreToolUse":
            startTurnIfNeeded()
            let tool = payload["tool_name"] as? String ?? ""
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let (activity, detail) = classify(tool: tool, input: input)
            let id = payload["tool_use_id"] as? String ?? UUID().uuidString
            r.inFlight[id] = InFlightTool(activity: activity, detail: detail, startedAt: now)
            r.toolCount += 1
            set(.working, activity, detail: detail)

        case "PostToolUse", "PostToolUseFailure":
            let tool = payload["tool_name"] as? String ?? ""
            if let id = payload["tool_use_id"] as? String { r.inFlight[id] = nil } else { r.inFlight = [:] }
            if r.phase == .working || r.phase.needsUser {
                let next: Activity = (tool == "Bash" || event == "PostToolUseFailure") ? .checkingResults : .thinking
                settleAfterTool(defaultActivity: next)
            }

        case "PermissionRequest":
            let tool = payload["tool_name"] as? String
            switch tool {
            case "AskUserQuestion": set(.waiting, message: "Question for you")
            case "ExitPlanMode": set(.waiting, message: "Plan ready for review")
            default: set(.attention, r.activity, detail: r.detail, message: tool.map { "Allow \(friendlyToolName($0))?" } ?? "Permission needed")
            }

        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            let message = payload["message"] as? String
            switch type {
            case "permission_prompt":
                set(.attention, r.activity, detail: r.detail, message: message ?? "Permission needed")
            case "idle_prompt":
                if r.phase != .completed && r.phase != .idle { set(.waiting, message: message) }
            case "elicitation_dialog":
                set(.waiting, message: message ?? "Question for you")
            default:
                break
            }

        case "PreCompact":
            set(.working, .compacting)

        case "Stop":
            r.inFlight = [:]
            if let start = r.turnStartedAt { r.lastTurnDuration = now.timeIntervalSince(start) }
            r.turnStartedAt = nil
            set(.completed)

        case "StopFailure":
            r.inFlight = [:]
            r.turnStartedAt = nil
            let reason = (payload["error"] as? String) ?? (payload["error_type"] as? String) ?? (payload["reason"] as? String)
            set(.error, message: reason.map(prettifyError) ?? "Request failed")

        case "SessionEnd":
            return nil

        default:
            break
        }
        return r
    }

    public static func classify(tool: String, input: [String: Any]) -> (Activity, String?) {
        let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String)
        let file = path.map { ($0 as NSString).lastPathComponent }

        switch tool {
        case "Read", "NotebookRead":
            return (.reading, file)
        case "Glob", "LS":
            return (.exploring, (input["pattern"] as? String) ?? file)
        case "Grep":
            return (.searching, (input["pattern"] as? String).map { "“\($0.prefix(40))”" })
        case "Write":
            return (.writing, file)
        case "Edit", "MultiEdit", "NotebookEdit":
            return (.editing, file)
        case "Bash", "BashOutput":
            let command = (input["command"] as? String) ?? ""
            return describeCommand(command)
        case "Task", "Agent":
            return (.delegating, (input["description"] as? String))
        case "WebFetch", "WebSearch":
            let target = (input["query"] as? String) ?? (input["url"] as? String).flatMap { URL(string: $0)?.host }
            return (.browsing, target)
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode":
            return (.planning, nil)
        default:
            if tool.hasPrefix("mcp__") {
                let server = tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first.map(String.init)
                return (.usingTool, server)
            }
            return (.working, tool.isEmpty ? nil : tool)
        }
    }

    private static let testPattern = try! NSRegularExpression(
        pattern: #"(^|[\s;&|/])(pytest|jest|vitest|mocha|rspec|phpunit|xctest|ctest|tox)\b|\b(swift|go|cargo|dotnet|mix|deno|bun|zig)\s+test\b|\b(npm|pnpm|yarn)\s+(run\s+)?test|\bxcodebuild\b.*\btest\b|\bmake\s+(test|check)\b|\bgradlew?\s+test"#)
    private static let buildPattern = try! NSRegularExpression(
        pattern: #"\b(swift|cargo|go|dotnet|zig)\s+build\b|\b(npm|pnpm|yarn)\s+(run\s+)?build\b|\bxcodebuild\b|\btsc\b|^\s*make\b|\bgradlew?\s+(build|assemble)|\bcmake\s+--build\b"#)
    private static let reviewPattern = try! NSRegularExpression(
        pattern: #"^\s*git\s+(diff|status|log|show|blame)\b"#)

    public static func classifyCommand(_ command: String) -> Activity {
        let range = NSRange(command.startIndex..., in: command)
        if testPattern.firstMatch(in: command, range: range) != nil { return .runningTests }
        if buildPattern.firstMatch(in: command, range: range) != nil { return .building }
        if reviewPattern.firstMatch(in: command, range: range) != nil { return .reviewing }
        return .runningCommands
    }

    public static func describeCommand(_ command: String) -> (Activity, String?) {
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        let segments = splitShell(firstLine, separators: ["&&", "||", ";", "|"])
        let order: [Activity] = [.runningTests, .building, .reviewing]
        for activity in order {
            if let seg = segments.first(where: { classifyCommand($0) == activity }) {
                return (activity, shortCommand(seg))
            }
        }
        return (.runningCommands, shortCommand(command))
    }

    static func shortCommand(_ command: String) -> String? {
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        let segments = splitShell(firstLine, separators: ["&&", "||", ";", "|"])
        let boring: Set<String> = ["cd", "sleep", "export", "source", ".", "set", "echo", "true"]
        func words(_ seg: String) -> [String] { Array(tokens(seg).drop { $0.contains("=") && !$0.hasPrefix("-") }) }
        let chosen = segments.first { seg in
            guard let head = words(seg).first else { return false }
            return !boring.contains(head)
        } ?? segments.first
        guard let chosen else { return nil }
        var words = words(chosen).filter { $0.range(of: #"^\d*[<>]"#, options: .regularExpression) == nil }
        guard !words.isEmpty else { return nil }
        if words[0].contains("/") { words[0] = (words[0] as NSString).lastPathComponent }
        let text = words.prefix(3).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(32))
    }

    private static func splitShell(_ s: String, separators: [String]) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        var i = s.startIndex
        outer: while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
                current.append(c); i = s.index(after: i); continue
            }
            if c == "\"" || c == "'" { quote = c; current.append(c); i = s.index(after: i); continue }
            for sep in separators where s[i...].hasPrefix(sep) {
                parts.append(current); current = ""
                i = s.index(i, offsetBy: sep.count)
                continue outer
            }
            current.append(c); i = s.index(after: i)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = [], current = "", quote: Character?
        for c in s {
            if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == " " || c == "\t" { if !current.isEmpty { out.append(current); current = "" }; continue }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func friendlyToolName(_ tool: String) -> String {
        switch tool {
        case "Bash": return "command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit"
        case "WebFetch": return "web fetch"
        default: return tool.hasPrefix("mcp__") ? "tool" : tool
        }
    }

    static func prettifyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("rate") { return "Rate limit reached" }
        if lower.contains("overload") { return "API overloaded" }
        if lower.contains("auth") { return "Authentication failed" }
        if lower.contains("network") || lower.contains("connect") { return "Connection lost" }
        return String(raw.prefix(40))
    }

    public static func estimatedWindowStart(promptTimes: [Date], window: TimeInterval, now: Date) -> Date? {
        var start: Date?
        for t in promptTimes.sorted() where t <= now {
            if let s = start, t < s.addingTimeInterval(window) { continue }
            start = t
        }
        guard let s = start, now < s.addingTimeInterval(window) else { return nil }
        return s
    }
}
