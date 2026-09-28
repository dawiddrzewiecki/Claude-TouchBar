import Foundation

public enum WidgetKind: String, Codable, CaseIterable, Sendable {
    case session, status, usage, weekly, context, project
    case timer, model, cost, diff, branch, tools, clock, reset
    case terminal, finder
    case divider, space, flexSpace

    public var title: String {
        switch self {
        case .session: return "Claude & Topic"
        case .status: return "Status"
        case .usage: return "5-Hour Limit"
        case .weekly: return "Weekly Limit"
        case .context: return "Context Window"
        case .project: return "Project Card"
        case .timer: return "Turn Timer"
        case .model: return "Model"
        case .cost: return "Session Cost"
        case .diff: return "Lines Changed"
        case .branch: return "Git Branch"
        case .tools: return "Tool Calls"
        case .clock: return "Clock"
        case .reset: return "Limit Reset"
        case .terminal: return "Terminal Button"
        case .finder: return "Finder Button"
        case .divider: return "Divider"
        case .space: return "Space"
        case .flexSpace: return "Flexible Space"
        }
    }

    public var summary: String {
        switch self {
        case .session: return "Animated Claude mark, session topic and the other sessions as dots"
        case .status: return "What Claude is doing right now, with the file or command"
        case .usage: return "Your real 5-hour usage from Claude Code"
        case .weekly: return "How much of the 7-day limit is used"
        case .context: return "How full the context window is, before auto-compact"
        case .project: return "Project name, branch, lines changed and context ring"
        case .timer: return "How long the current turn has been running"
        case .model: return "The model and effort level of the session"
        case .cost: return "What this session has cost so far"
        case .diff: return "Lines added and removed in this session"
        case .branch: return "The current git branch"
        case .tools: return "Tool calls in the current turn"
        case .clock: return "The time of day"
        case .reset: return "When the 5-hour limit resets"
        case .terminal: return "Jump to the terminal running this session"
        case .finder: return "Open the project folder"
        case .divider: return "A thin line between widgets"
        case .space: return "A fixed gap"
        case .flexSpace: return "Pushes the widgets after it to the right"
        }
    }

    public var isRepeatable: Bool { self == .divider || self == .space || self == .flexSpace }
    public var isFlexible: Bool { self == .status || self == .flexSpace }

    public var options: [WidgetOption] {
        let meterStyles: [WidgetOption.Choice] = [.init("key", "Filled key"), .init("segmented", "Segments"), .init("slim", "Slim bar"), .init("ring", "Ring"), .init("text", "Text only")]
        let size = WidgetOption("size", "Width", [.init("regular", "Regular"), .init("compact", "Compact"), .init("wide", "Wide")])
        switch self {
        case .session:
            return [
                .toggle("topic", "Topic"),
                .toggle("sessions", "Other sessions"),
                WidgetOption("motion", "Animation", [.init("lively", "Lively"), .init("calm", "Calm"), .init("off", "Off")]),
                WidgetOption("color", "Mark color", [.init("claude", "Claude"), .init("white", "White"), .init("status", "Status")]),
            ]
        case .status:
            return [.toggle("detail", "File / command"), .toggle("timer", "Timer"), .toggle("shimmer", "Shimmer")]
        case .usage:
            return [
                WidgetOption("style", "Style", meterStyles),
                WidgetOption("label", "Label", [.init("auto", "Automatic"), .init("percent", "Percent used"), .init("used", "Time in window"), .init("left", "Time until reset")]),
                .toggle("reset", "Reset time"),
                size,
                WidgetOption("warn", "Warn at", [.init("80", "80%"), .init("70", "70%"), .init("90", "90%"), .init("off", "Never")]),
            ]
        case .weekly:
            return [WidgetOption("style", "Style", [.init("slim", "Slim bar")] + meterStyles.filter { $0.value != "slim" }), size,
                    WidgetOption("warn", "Warn at", [.init("80", "80%"), .init("70", "70%"), .init("90", "90%"), .init("off", "Never")])]
        case .context:
            return [WidgetOption("style", "Style", [.init("ring", "Ring")] + meterStyles.filter { $0.value != "ring" }), size,
                    WidgetOption("warn", "Warn at", [.init("85", "85%"), .init("70", "70%"), .init("95", "95%"), .init("off", "Never")])]
        case .project:
            return [
                WidgetOption("line", "Second line", [.init("both", "Branch & lines"), .init("branch", "Branch"), .init("diff", "Lines changed"), .init("none", "None")]),
                .toggle("ring", "Context ring"),
            ]
        case .model:
            return [.toggle("effort", "Effort level")]
        case .diff:
            return [WidgetOption("mode", "Show", [.init("lines", "Lines + / −"), .init("files", "Changed files")])]
        case .clock:
            return [WidgetOption("format", "Format", [.init("system", "System"), .init("24h", "24-hour"), .init("12h", "12-hour")]), .toggle("date", "Weekday", on: false)]
        case .reset:
            return [WidgetOption("mode", "Show", [.init("countdown", "Countdown"), .init("clock", "Time of day")])]
        case .terminal, .finder:
            return [.toggle("label", "Label")]
        case .space:
            return [WidgetOption("size", "Size", [.init("medium", "Medium"), .init("small", "Small"), .init("large", "Large")])]
        case .timer, .tools, .cost, .branch:
            return [.toggle("icon", "Icon")]
        case .divider, .flexSpace:
            return []
        }
    }
}

public struct WidgetOption: Sendable, Equatable {
    public struct Choice: Sendable, Equatable {
        public let value: String
        public let title: String
        public init(_ value: String, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    public let key: String
    public let title: String
    public let choices: [Choice]

    public init(_ key: String, _ title: String, _ choices: [Choice]) {
        self.key = key
        self.title = title
        self.choices = choices
    }

    public static func toggle(_ key: String, _ title: String, on: Bool = true) -> WidgetOption {
        WidgetOption(key, title, on ? [Choice("on", "On"), Choice("off", "Off")] : [Choice("off", "Off"), Choice("on", "On")])
    }

    public var isToggle: Bool { Set(choices.map(\.value)) == ["on", "off"] }
    public var defaultValue: String { choices.first?.value ?? "" }
}

public struct WidgetConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: WidgetKind
    public var options: [String: String]

    public init(_ kind: WidgetKind, options: [String: String] = [:], id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.options = options
    }

    public func value(_ key: String) -> String {
        let option = kind.options.first { $0.key == key }
        if let v = options[key], option?.choices.contains(where: { $0.value == v }) ?? false { return v }
        return option?.defaultValue ?? ""
    }

    public func isOn(_ key: String) -> Bool { value(key) == "on" }

    public func setting(_ key: String, to value: String) -> WidgetConfig {
        var c = self
        c.options[key] = value
        return c
    }
}

public struct BarLayout: Codable, Equatable, Sendable {
    public var widgets: [WidgetConfig]

    public init(_ widgets: [WidgetConfig]) { self.widgets = widgets }

    public init(kinds: [WidgetKind]) { self.init(kinds.map { WidgetConfig($0) }) }

    private enum CodingKeys: String, CodingKey { case widgets }

    private struct Lossy: Decodable {
        let value: WidgetConfig?
        init(from decoder: Decoder) throws { value = try? WidgetConfig(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widgets = try c.decode([Lossy].self, forKey: .widgets).compactMap(\.value)
        normalize()
    }

    public static let standard = BarLayout(kinds: [.session, .divider, .status, .usage, .project])

    public static let presets: [(name: String, layout: BarLayout)] = [
        ("Default", standard),
        ("Minimal", BarLayout(kinds: [.session, .divider, .status, .usage])),
        ("Limits", BarLayout([WidgetConfig(.session, options: ["topic": "off"]), WidgetConfig(.divider), WidgetConfig(.status),
                              WidgetConfig(.usage, options: ["size": "compact"]), WidgetConfig(.weekly), WidgetConfig(.reset)])),
        ("Developer", BarLayout([WidgetConfig(.session), WidgetConfig(.divider), WidgetConfig(.status, options: ["timer": "off"]), WidgetConfig(.timer),
                                 WidgetConfig(.context), WidgetConfig(.branch), WidgetConfig(.diff), WidgetConfig(.terminal, options: ["label": "off"])])),
        ("Everything", BarLayout([WidgetConfig(.session, options: ["topic": "off"]), WidgetConfig(.status, options: ["detail": "off"]),
                                  WidgetConfig(.usage, options: ["style": "ring"]), WidgetConfig(.weekly, options: ["style": "ring"]),
                                  WidgetConfig(.context), WidgetConfig(.model, options: ["effort": "off"]), WidgetConfig(.cost), WidgetConfig(.clock)])),
    ]

    public func contains(_ kind: WidgetKind) -> Bool { widgets.contains { $0.kind == kind } }

    public func canInsert(_ kind: WidgetKind) -> Bool { kind.isRepeatable || !contains(kind) }

    public mutating func insert(_ widget: WidgetConfig, at index: Int) {
        guard widget.kind.isRepeatable || !widgets.contains(where: { $0.kind == widget.kind && $0.id != widget.id }) else { return }
        widgets.removeAll { $0.id == widget.id }
        widgets.insert(widget, at: min(max(index, 0), widgets.count))
    }

    public mutating func remove(id: String) { widgets.removeAll { $0.id == id } }

    public mutating func update(_ widget: WidgetConfig) {
        guard let i = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[i] = widget
    }

    public mutating func normalize() {
        var seen = Set<WidgetKind>(), ids = Set<String>()
        widgets = widgets.filter { w in
            guard ids.insert(w.id).inserted else { return false }
            return w.kind.isRepeatable || seen.insert(w.kind).inserted
        }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> BarLayout? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(BarLayout.self, from: data)
    }
}
