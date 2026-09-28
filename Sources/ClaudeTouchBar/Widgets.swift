import AppKit
import ClaudeBarCore

enum WidgetTap: Equatable {
    case none
    case detail(DetailKind)
    case action(BarAction)
}

class Widget: CALayer {
    let config: WidgetConfig
    var kind: WidgetKind { config.kind }

    init(_ config: WidgetConfig) {
        self.config = config
        super.init()
        contentsScale = Theme.scale
    }

    override init(layer: Any) {
        config = (layer as? Widget)?.config ?? WidgetConfig(.space)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { 0 }
    var minimumWidth: CGFloat { preferredWidth }
    var hasContent: Bool { true }
    var tap: WidgetTap { .none }
    var usesKeyPress: Bool { false }
    var slideLayer: CALayer { self }

    func adapt(to barWidth: CGFloat) {}
    func update(_ m: BarModel, animated: Bool) {}
    func tick(_ m: BarModel, now: Date, animated: Bool) {}
    func setPressed(_ on: Bool) {}

    static func make(_ config: WidgetConfig) -> Widget {
        switch config.kind {
        case .session: return SessionWidget(config)
        case .status: return StatusWidget(config)
        case .usage, .weekly, .context: return MeterWidget(config)
        case .project: return ProjectWidget(config)
        case .timer, .model, .cost, .diff, .branch, .tools, .clock, .reset: return InfoWidget(config)
        case .terminal, .finder: return ButtonWidget(config)
        case .divider: return DividerWidget(config)
        case .space, .flexSpace: return SpaceWidget(config)
        }
    }
}

final class SessionWidget: Widget {
    let identity = IdentityLayer()

    override init(_ config: WidgetConfig) {
        super.init(config)
        identity.showsDots = config.isOn("sessions")
        identity.markColor = IdentityLayer.MarkColor(rawValue: config.value("color")) ?? .claude
        identity.mark.motion = ClaudeMarkLayer.Motion(rawValue: config.value("motion")) ?? .lively
        addSublayer(identity)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredWidth: CGFloat { identity.contentWidth }
    override var tap: WidgetTap { .action(.openTerminal) }
    override var slideLayer: CALayer { identity.carousel }

    override func adapt(to barWidth: CGFloat) {
        identity.showsTitle = config.isOn("topic") && barWidth >= 560
        identity.maxTitleWidth = barWidth >= 940 ? 210 : (barWidth >= 760 ? 160 : 120)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { identity.frame = bounds }
        identity.setNeedsLayout()
    }

    override func update(_ m: BarModel, animated: Bool) {
        identity.isDemo = m.source == .demo
        identity.update(phase: m.phase, topic: m.topic, pages: m.pages, pageIndex: m.pageIndex, animated: animated)
    }
}

final class StatusWidget: Widget {
    let status = StatusLayer()

    override init(_ config: WidgetConfig) {
        super.init(config)
        status.showsDetail = config.isOn("detail")
        status.showsElapsed = config.isOn("timer")
        status.shimmer = config.isOn("shimmer")
        addSublayer(status)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredWidth: CGFloat { status.naturalWidth }
    override var minimumWidth: CGFloat { min(status.naturalWidth, 120) }
    override var tap: WidgetTap { .detail(.status) }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { status.frame = bounds }
        status.setNeedsLayout()
    }
}

enum UsageLabelStyle: String {
    case auto, percent, used, left
}

final class MeterWidget: Widget {
    let meter = UsageLayer()

    override init(_ config: WidgetConfig) {
        super.init(config)
        meter.meterStyle = UsageLayer.Style(rawValue: config.value("style")) ?? .key
        meter.warn = Double(config.value("warn")).map { $0 / 100 }
        addSublayer(meter)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredWidth: CGFloat { meter.contentWidth }
    override var usesKeyPress: Bool { meter.meterStyle.usesKey }
    override var tap: WidgetTap { kind == .context ? .detail(.status) : .detail(.usage) }

    override func adapt(to barWidth: CGFloat) {
        let base: CGFloat = barWidth >= 940 ? 250 : (barWidth >= 820 ? 210 : (barWidth >= 680 ? 160 : 120))
        let share: CGFloat = kind == .usage ? 1 : 0.72
        let size: CGFloat = ["compact": 0.62, "wide": 1.35][config.value("size")] ?? 1
        meter.barWidth = round(base * share * size)
        meter.showsRightLabel = barWidth >= 680 && (kind != .usage || config.isOn("reset") || config.value("label") != "auto")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { meter.frame = bounds }
        meter.setNeedsLayout()
    }

    override func setPressed(_ on: Bool) { meter.setPressed(on) }

    override func update(_ m: BarModel, animated: Bool) {
        CALayer.animate(animated ? Theme.normal : 0) { meter.opacity = m.phase == .offline ? 0.5 : 1 }
    }

    override func tick(_ m: BarModel, now: Date, animated: Bool) {
        switch kind {
        case .weekly:
            let f = m.usage?.weeklyFraction
            meter.update(fraction: f ?? 0, ghost: nil, left: f.map { Format.percent($0) } ?? "–", right: "7-day", animated: animated)
        case .context:
            let f = m.contextPercent.map { $0 / 100 }
            meter.update(fraction: f ?? 0, ghost: nil, left: f.map { Format.percent($0) } ?? "–", right: "context", animated: animated)
        default:
            guard let u = m.usage else {
                meter.update(fraction: 0, ghost: nil, left: meter.meterStyle.usesKey ? "No usage data" : "–", right: meter.meterStyle.usesKey ? nil : "5h", animated: false)
                return
            }
            let ghost = u.usedFraction != nil ? u.timeFraction(at: now) : nil
            let (left, right) = labels(u, now: now)
            meter.update(fraction: u.fillFraction(at: now), ghost: ghost, left: left, right: right, animated: animated)
        }
    }

    private func labels(_ u: UsageModel, now: Date) -> (String, String?) {
        var style = UsageLabelStyle(rawValue: config.value("label")) ?? .auto
        if style == .auto { style = u.usedFraction != nil ? .percent : .used }
        let prefix = u.isEstimate ? "~" : ""
        let reset = u.windowStart != nil && config.isOn("reset") ? "resets in " + Format.duration(u.remaining(at: now)) : nil
        switch style {
        case .percent where u.usedFraction != nil:
            return (Format.percent(u.usedFraction ?? 0), reset)
        case .left:
            return (prefix + Format.duration(u.remaining(at: now)) + " left", u.usedFraction.map { Format.percent($0) + " used" })
        default:
            return (prefix + Format.duration(u.elapsed(at: now)), "of " + Format.hours(u.window))
        }
    }
}

final class ProjectWidget: Widget {
    let project = ProjectLayer()
    private var hasProject = false

    override init(_ config: WidgetConfig) {
        super.init(config)
        project.lineMode = config.value("line")
        project.showsRing = config.isOn("ring")
        addSublayer(project)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredWidth: CGFloat { project.preferredWidth }
    override var hasContent: Bool { hasProject }
    override var usesKeyPress: Bool { true }
    override var tap: WidgetTap { .detail(.project) }
    override var slideLayer: CALayer { project.content }

    override func adapt(to barWidth: CGFloat) {
        project.showsBranch = barWidth >= 640
        project.maxWidth = barWidth >= 800 ? 230 : 170
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { project.frame = bounds }
        project.setNeedsLayout()
    }

    override func setPressed(_ on: Bool) { project.setPressed(on) }

    override func update(_ m: BarModel, animated: Bool) {
        hasProject = m.project != nil
        project.update(m, animated: animated)
    }
}

final class InfoWidget: Widget {
    private let icon = CALayer.plain()
    private let value = TextLayer()
    private let caption = TextLayer()
    private let symbol: String?

    override init(_ config: WidgetConfig) {
        let symbols: [WidgetKind: String] = [.timer: "timer", .tools: "wrench.and.screwdriver", .cost: "creditcard", .branch: "arrow.triangle.branch", .reset: "arrow.clockwise"]
        let wantsIcon = config.kind.options.contains { $0.key == "icon" } ? config.isOn("icon") : config.kind == .reset
        symbol = wantsIcon ? symbols[config.kind] : nil
        super.init(config)
        if let symbol {
            icon.contents = Glyphs.symbol(symbol, pointSize: 10.5, weight: .semibold, color: Theme.tertiary)
            icon.contentsGravity = .center
            addSublayer(icon)
        }
        addSublayer(value)
        addSublayer(caption)
    }

    override init(layer: Any) {
        symbol = nil
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var iconWidth: CGFloat { symbol == nil ? 0 : 19 }
    private var captionWidth: CGFloat { (caption.text?.length ?? 0) > 0 ? 5 + (caption.text?.width ?? 0) : 0 }

    override var preferredWidth: CGFloat { ceil(iconWidth + (value.text?.width ?? 0) + captionWidth) }

    override var tap: WidgetTap {
        switch kind {
        case .diff, .branch: return .detail(.project)
        case .reset: return .detail(.usage)
        case .clock: return .none
        default: return .detail(.status)
        }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still {
            let mid = bounds.midY
            icon.frame = CGRect(x: 0, y: 0, width: 14, height: bounds.height)
            let vw = value.text?.width ?? 0
            value.place(x: iconWidth, midY: mid, width: vw)
            caption.place(x: iconWidth + vw + 5, midY: mid, width: caption.text?.width ?? 0)
        }
    }

    override func update(_ m: BarModel, animated: Bool) { tick(m, now: Date(), animated: animated) }

    override func tick(_ m: BarModel, now: Date, animated: Bool) {
        let (v, c) = content(m, now: now)
        guard v != value.text || c?.string != caption.text?.string else { return }
        CALayer.still {
            value.text = v
            caption.text = c
            layoutSublayers()
        }
    }

    private func text(_ s: String, _ color: NSColor = Theme.primary) -> NSAttributedString {
        NSAttributedString(s, font: Theme.digits, color: color)
    }

    private var none: NSAttributedString { text("–", Theme.tertiary) }

    private func content(_ m: BarModel, now: Date) -> (NSAttributedString, NSAttributedString?) {
        func cap(_ s: String) -> NSAttributedString { NSAttributedString(s, font: Theme.small, color: Theme.tertiary) }
        switch kind {
        case .timer:
            if (m.phase == .working || m.phase.needsUser), let start = m.turnStartedAt { return (text(Format.elapsed(now.timeIntervalSince(start))), nil) }
            if let last = m.lastTurnDuration { return (text(Format.elapsed(last), Theme.secondary), cap("last")) }
            return (none, nil)
        case .model:
            guard let name = m.modelName else { return (none, nil) }
            return (text(name), config.isOn("effort") ? m.effort.map(cap) : nil)
        case .cost:
            return (m.costUSD.map { text(String(format: "$%.2f", $0)) } ?? none, nil)
        case .diff:
            if config.value("mode") == "files" {
                guard let n = m.project?.changedFiles else { return (none, nil) }
                return (text("\(n)"), cap(n == 1 ? "file" : "files"))
            }
            guard let a = m.linesAdded, let r = m.linesRemoved else { return (none, nil) }
            let s = NSMutableAttributedString(attributedString: text("+\(a)", Theme.diffAdd))
            s.append(text(" −\(r)", Theme.diffRemove))
            return (s, nil)
        case .branch:
            return (m.project?.branch.map { text($0) } ?? none, nil)
        case .tools:
            return (text("\(m.toolCount)"), cap(m.toolCount == 1 ? "tool" : "tools"))
        case .clock:
            let f = DateFormatter()
            let day = config.isOn("date") ? "EEE " : ""
            switch config.value("format") {
            case "24h": f.dateFormat = day + "HH:mm"
            case "12h": f.dateFormat = day + "h:mm a"
            default: f.setLocalizedDateFormatFromTemplate(day + "jmm")
            }
            return (text(f.string(from: now)), nil)
        case .reset:
            guard let u = m.usage, let reset = u.resetsAt else { return (none, nil) }
            if config.value("mode") == "clock" { return (text(Format.clock(reset)), cap("reset")) }
            return (text(Format.duration(u.remaining(at: now))), cap("to reset"))
        default:
            return (none, nil)
        }
    }
}

final class ButtonWidget: Widget {
    private let background = CALayer.plain()
    private let icon = CALayer.plain()
    private let label = TextLayer()

    override init(_ config: WidgetConfig) {
        super.init(config)
        background.backgroundColor = Theme.key.cgColor
        background.cornerRadius = UsageLayer.radius
        addSublayer(background)
        icon.contents = Glyphs.symbol(config.kind == .finder ? "folder" : "terminal", pointSize: 12, weight: .semibold, color: Theme.primary)
        icon.contentsGravity = .center
        background.addSublayer(icon)
        if config.isOn("label") {
            label.text = NSAttributedString(config.kind == .finder ? "Finder" : "Terminal", font: .systemFont(ofSize: 12, weight: .medium), color: Theme.primary)
        }
        background.addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private var labelWidth: CGFloat { label.text?.width ?? 0 }
    override var preferredWidth: CGFloat { labelWidth > 0 ? labelWidth + 38 : 40 }
    override var usesKeyPress: Bool { true }
    override var tap: WidgetTap { .action(kind == .finder ? .openFinder : .openTerminal) }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still {
            background.frame = bounds.insetBy(dx: 0, dy: 1)
            let h = background.bounds.height
            icon.frame = labelWidth > 0 ? CGRect(x: 9, y: 0, width: 16, height: h) : CGRect(x: 0, y: 0, width: bounds.width, height: h)
            label.place(x: 29, midY: h / 2, width: labelWidth)
        }
    }

    override func setPressed(_ on: Bool) {
        CALayer.animate(on ? 0.08 : Theme.normal) {
            background.backgroundColor = (on ? Theme.keyPressed : Theme.key).cgColor
        }
    }
}

final class DividerWidget: Widget {
    private let line = CALayer.plain()

    override init(_ config: WidgetConfig) {
        super.init(config)
        line.backgroundColor = Theme.hairline.cgColor
        addSublayer(line)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredWidth: CGFloat { 1 }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { line.frame = CGRect(x: 0, y: bounds.midY - 7, width: 1, height: 14) }
    }
}

final class SpaceWidget: Widget {
    override var preferredWidth: CGFloat {
        guard kind == .space else { return 0 }
        return ["small": 4, "large": 48][config.value("size")] ?? 18
    }
}
