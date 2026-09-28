import Foundation

public struct PendingRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case permission, question, plan }

    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var detail: String?
        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public struct Question: Codable, Sendable, Equatable {
        public var question: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool
        public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public var id: String
    public var sessionId: String
    public var kind: Kind
    public var toolName: String
    public var title: String
    public var detail: String?
    public var questions: [Question]
    public var canAlwaysAllow: Bool
    public var createdAt: Date

    public init(id: String, sessionId: String, kind: Kind, toolName: String, title: String, detail: String?,
                questions: [Question] = [], canAlwaysAllow: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.questions = questions
        self.canAlwaysAllow = canAlwaysAllow
        self.createdAt = createdAt
    }
}

public struct RequestResponse: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case allow, always, deny, answer }
    public var id: String
    public var action: Action
    public var answers: [String: String]?

    public init(id: String, action: Action, answers: [String: String]? = nil) {
        self.id = id
        self.action = action
        self.answers = answers
    }
}

public enum RequestBuilder {
    public static func request(from payload: [String: Any], now: Date = Date()) -> PendingRequest? {
        guard let sessionId = payload["session_id"] as? String else { return nil }
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let id = payload["tool_use_id"] as? String ?? UUID().uuidString
        let suggestions = payload["permission_suggestions"] as? [Any] ?? []

        switch tool {
        case "AskUserQuestion":
            let raw = input["questions"] as? [[String: Any]] ?? []
            let questions: [PendingRequest.Question] = raw.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> PendingRequest.Option? in
                    guard let label = o["label"] as? String else { return nil }
                    return .init(label: label, detail: o["description"] as? String)
                }
                return .init(question: text, header: q["header"] as? String, options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            guard !questions.isEmpty else { return nil }
            return PendingRequest(id: id, sessionId: sessionId, kind: .question, toolName: tool,
                                  title: questions[0].question, detail: nil, questions: questions, createdAt: now)
        case "ExitPlanMode":
            return PendingRequest(id: id, sessionId: sessionId, kind: .plan, toolName: tool,
                                  title: "Plan ready", detail: "Approve and start coding?", createdAt: now)
        default:
            let (activity, detail) = HookProcessor.classify(tool: tool, input: input)
            let title: String
            switch activity {
            case .runningTests, .building, .runningCommands, .reviewing, .checkingResults: title = "Run command?"
            case .writing: title = "Create file?"
            case .editing: title = "Edit file?"
            case .browsing: title = "Fetch from web?"
            case .usingTool: title = "Use \(detail ?? "tool")?"
            default: title = "Allow \(tool)?"
            }
            let full = (input["command"] as? String).map { $0.split(separator: "\n").first.map(String.init) ?? $0 } ?? detail
            return PendingRequest(id: id, sessionId: sessionId, kind: .permission, toolName: tool, title: title,
                                  detail: full, canAlwaysAllow: !suggestions.isEmpty, createdAt: now)
        }
    }

    public static func hookOutput(for response: RequestResponse, payload: [String: Any]) -> [String: Any] {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        var decision: [String: Any]
        switch response.action {
        case .allow:
            decision = ["behavior": "allow"]
            if payload["tool_name"] as? String == "ExitPlanMode" { decision["updatedInput"] = input }
        case .always:
            decision = ["behavior": "allow"]
            if let suggestions = payload["permission_suggestions"] as? [Any], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": "Declined from the Touch Bar."]
        case .answer:
            var updated = input
            updated["answers"] = response.answers ?? [:]
            decision = ["behavior": "allow", "updatedInput": updated]
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }
}
