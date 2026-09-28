import Foundation

public enum Phase: String, Codable, Sendable {
    case offline
    case idle
    case working
    case waiting
    case attention
    case completed
    case error

    public var needsUser: Bool { self == .waiting || self == .attention }
}

public enum Activity: String, Codable, Sendable, CaseIterable {
    case thinking, exploring, reading, searching, planning, writing, editing, building
    case runningTests, runningCommands, checkingResults, reviewing, delegating, browsing
    case usingTool, compacting, working

    public var title: String {
        switch self {
        case .thinking: return "Thinking"
        case .exploring: return "Analyzing project"
        case .reading: return "Reading files"
        case .searching: return "Searching code"
        case .planning: return "Planning changes"
        case .writing: return "Writing code"
        case .editing: return "Editing files"
        case .building: return "Building"
        case .runningTests: return "Running tests"
        case .runningCommands: return "Running commands"
        case .checkingResults: return "Checking results"
        case .reviewing: return "Reviewing changes"
        case .delegating: return "Running agent"
        case .browsing: return "Searching the web"
        case .usingTool: return "Using tools"
        case .compacting: return "Compacting context"
        case .working: return "Working"
        }
    }
}

public struct InFlightTool: Codable, Sendable, Equatable {
    public var activity: Activity
    public var detail: String?
    public var startedAt: Date
}

public struct SessionRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var claudePid: Int32?
    public var phase: Phase
    public var activity: Activity?
    public var detail: String?
    public var message: String?
    public var inFlight: [String: InFlightTool]
    public var phaseSince: Date
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var toolCount: Int
    public var updatedAt: Date
    public var createdAt: Date?
    public var transcriptPath: String?

    public init(sessionId: String, cwd: String, now: Date = Date()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.phase = .idle
        self.inFlight = [:]
        self.phaseSince = now
        self.toolCount = 0
        self.updatedAt = now
        self.createdAt = now
    }
}

public struct SessionMeta: Codable, Sendable, Equatable {
    public var sessionId: String
    public var sessionName: String?
    public var model: String?
    public var effort: String?
    public var contextPercent: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var costUSD: Double?
    public var transcriptPath: String?

    public init(sessionId: String) { self.sessionId = sessionId }
}

public struct RateWindow: Codable, Sendable, Equatable {
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

public struct UsageRecord: Codable, Sendable, Equatable {
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?
    public var rateLimitsUpdatedAt: Date?
    public var promptTimes: [Date]

    public init() { promptTimes = [] }
}

public struct UsageModel: Equatable, Sendable {
    public var window: TimeInterval
    public var windowStart: Date?
    public var usedFraction: Double?
    public var weeklyFraction: Double?
    public var isEstimate: Bool

    public init(window: TimeInterval, windowStart: Date?, usedFraction: Double?, weeklyFraction: Double? = nil, isEstimate: Bool) {
        self.window = window
        self.windowStart = windowStart
        self.usedFraction = usedFraction
        self.weeklyFraction = weeklyFraction
        self.isEstimate = isEstimate
    }

    public var resetsAt: Date? { windowStart.map { $0.addingTimeInterval(window) } }

    public func elapsed(at now: Date) -> TimeInterval {
        guard let start = windowStart else { return 0 }
        return min(max(now.timeIntervalSince(start), 0), window)
    }

    public func remaining(at now: Date) -> TimeInterval { window - elapsed(at: now) }

    public func timeFraction(at now: Date) -> Double { window > 0 ? elapsed(at: now) / window : 0 }

    public func fillFraction(at now: Date) -> Double { min(max(usedFraction ?? timeFraction(at: now), 0), 1) }
}

public struct ProjectModel: Equatable, Sendable {
    public var name: String
    public var path: String
    public var branch: String?
    public var changedFiles: Int?

    public init(name: String, path: String, branch: String? = nil, changedFiles: Int? = nil) {
        self.name = name
        self.path = path
        self.branch = branch
        self.changedFiles = changedFiles
    }

    public var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

public struct SessionPage: Equatable, Sendable {
    public var sessionId: String
    public var phase: Phase
    public init(sessionId: String, phase: Phase) {
        self.sessionId = sessionId
        self.phase = phase
    }
}

public enum DataSource: String, Equatable, Sendable {
    case none, basic, live, demo
}

public struct BarModel: Equatable, Sendable {
    public var phase: Phase
    public var activity: Activity?
    public var detail: String?
    public var message: String?
    public var phaseSince: Date
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var toolCount: Int
    public var usage: UsageModel?
    public var project: ProjectModel?
    public var sessionId: String?
    public var claudePid: Int32?
    public var sessionCount: Int
    public var source: DataSource
    public var topic: String?
    public var modelName: String?
    public var effort: String?
    public var contextPercent: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var costUSD: Double?
    public var pages: [SessionPage] = []
    public var pageIndex: Int = 0
    public var request: PendingRequest?

    public init(phase: Phase = .offline, activity: Activity? = nil, detail: String? = nil, message: String? = nil,
                phaseSince: Date = Date(), turnStartedAt: Date? = nil, lastTurnDuration: TimeInterval? = nil,
                toolCount: Int = 0, usage: UsageModel? = nil, project: ProjectModel? = nil, sessionId: String? = nil,
                claudePid: Int32? = nil, sessionCount: Int = 0, source: DataSource = .none) {
        self.phase = phase
        self.activity = activity
        self.detail = detail
        self.message = message
        self.phaseSince = phaseSince
        self.turnStartedAt = turnStartedAt
        self.lastTurnDuration = lastTurnDuration
        self.toolCount = toolCount
        self.usage = usage
        self.project = project
        self.sessionId = sessionId
        self.claudePid = claudePid
        self.sessionCount = sessionCount
        self.source = source
    }

    public var statusTitle: String {
        switch phase {
        case .offline: return "Not running"
        case .idle: return "Ready"
        case .working: return (activity ?? .thinking).title
        case .waiting: return "Waiting for input"
        case .attention: return "Needs your approval"
        case .completed: return "Completed"
        case .error: return "Needs attention"
        }
    }
}
