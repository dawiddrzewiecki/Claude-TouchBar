import AppKit
import ClaudeBarCore

final class BarView: NSView {
    var onAction: ((BarAction) -> Void)?
    var barLayout: BarLayout = .standard { didSet { if barLayout != oldValue { rebuildWidgets() } } }
    var answerKeysEnabled = true { didSet { if answerKeysEnabled != oldValue, let model { render(model, animated: false) } } }
    var isInteractive = true
    var adaptWidth: CGFloat?
    var showsPageArrows = true { didSet { edges.isHidden = !showsPageArrows; needsLayout = true } }
    private var animatesLayout = false

    func setBarLayout(_ layout: BarLayout, animated: Bool) {
        barLayout = layout
        guard animated else { return }
        animatesLayout = true
        layoutSubtreeIfNeeded()
        animatesLayout = false
    }

    private let main = CALayer.plain()
    private var widgets: [Widget] = []
    private let fallbackStatus = StatusWidget(WidgetConfig(.status, id: "fallback-status"))
    private let pressHighlight = CALayer.plain()
    private let detail = DetailLayer()
    private let action = ActionLayer()
    private let edges = PageArrowsLayer()

    private(set) var model: BarModel?
    private var actionRequestId: String?
    private var questionIndex = 0
    private var answers: [String: String] = [:]
    private var multiSelected = Set<Int>()
    private var confirmation: (id: String, text: String)?
    private var actionActive: Bool { answerKeysEnabled && model?.request != nil && confirmation == nil }
    private(set) var detailKind: DetailKind?
    private var detailTimer: DispatchWorkItem?
    private let gap: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer.plain()
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        allowedTouchTypes = [.direct]

        pressHighlight.backgroundColor = Theme.pressed.cgColor
        pressHighlight.cornerRadius = 7
        pressHighlight.opacity = 0
        main.addSublayer(pressHighlight)
        fallbackStatus.opacity = 0
        main.addSublayer(fallbackStatus)
        main.addSublayer(action)
        action.opacity = 0
        root.masksToBounds = true
        root.addSublayer(main)
        peek.contentsScale = Theme.scale
        peek.isHidden = true
        root.addSublayer(peek)
        root.addSublayer(edges)
        detail.opacity = 0
        detail.isHidden = true
        root.addSublayer(detail)
        rebuildWidgets()
    }

    private var statusWidgets: [StatusWidget] { widgets.compactMap { $0 as? StatusWidget } + [fallbackStatus] }
    private var usesFallbackStatus: Bool { actionActive && !barLayout.contains(.status) }

    private func rebuildWidgets() {
        let old = Dictionary(widgets.map { ($0.config.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = barLayout.widgets.map { c -> Widget in
            if let w = old[c.id], w.config == c { return w }
            return Widget.make(c)
        }
        CALayer.still {
            for w in widgets where !next.contains(where: { $0 === w }) { w.removeFromSuperlayer() }
            for w in next where w.superlayer == nil { main.insertSublayer(w, below: action) }
        }
        widgets = next
        keysSignature = ""
        if let model {
            let m = model
            self.model = nil
            render(m, animated: false)
        }
        needsLayout = true
    }

    func overflowedIDs() -> [String] {
        guard !actionActive else { return [] }
        return widgets.filter { $0.hasContent && $0.isHidden }.map(\.config.id)
    }

    func widgetImage(_ id: String) -> CGImage? {
        guard let w = widgets.first(where: { $0.config.id == id }), w.bounds.width > 0 else { return nil }
        let pad: CGFloat = 6
        let size = CGSize(width: w.bounds.width + pad * 2, height: bounds.height)
        return Glyphs.image(size: size) { ctx, rect in
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.translateBy(x: pad, y: 0)
            w.render(in: ctx)
        }
    }

    var diagnostics: [String] {
        widgets.map { "\($0.kind.rawValue) x=\(Int($0.frame.minX)) w=\(Int($0.frame.width)) preferred=\($0.preferredWidth) hidden=\($0.isHidden)" }
    }

    func widgetFrames() -> [(id: String, frame: CGRect)] {
        widgets.filter { !$0.isHidden && $0.opacity > 0 }.map { ($0.config.id, $0.frame.offsetBy(dx: edgeInset, dy: 0)) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.height) }

    func render(_ model: BarModel, now: Date = Date(), animated: Bool = true) {
        let previous = self.model
        self.model = model
        let switchedSession = previous?.sessionId != nil && model.sessionId != nil && previous?.sessionId != model.sessionId

        syncRequest(previous: previous, animated: animated && previous != nil && window != nil)
        let animate = animated && previous != nil && window != nil && detailKind == nil && !turningCommit
        let grew = previous.map { !$0.pages.isEmpty && model.pages.count > $0.pages.count } ?? false
        edges.update(pages: model.pages, pageIndex: model.pageIndex, nudge: grew)
        let content = statusContent(model)
        if switchedSession && animate {
            for w in widgets { w.update(model, animated: false) }
            for s in statusWidgets { s.status.replace(content) }
            slideIn(from: slideDirection(previous: previous, current: model))
        } else {
            for w in widgets { w.update(model, animated: animate) }
            for s in statusWidgets { s.status.update(content, animated: animate) }
        }
        tick(now: now, model: model, animated: animate)
        let answering = actionActive
        let fallback = usesFallbackStatus
        CALayer.animate(animate ? Theme.normal : 0) {
            for w in self.widgets { w.opacity = w.hasContent && !(answering && self.yieldsToKeys(w)) ? 1 : 0 }
            self.fallbackStatus.opacity = fallback ? 1 : 0
            self.action.opacity = answering ? 1 : 0
        }
        needsLayout = true
        if let kind = detailKind { detail.show(detailItems(kind, model: model, now: now)) }
    }

    private func syncRequest(previous: BarModel?, animated: Bool) {
        guard let model else { return }
        if let c = confirmation, !(model.phase.needsUser) || model.request?.id != c.id && model.request != nil {
            confirmation = nil
        }
        guard let r = model.request else { actionRequestId = nil; return }
        if r.id != actionRequestId {
            actionRequestId = r.id
            questionIndex = 0
            answers = [:]
            multiSelected = []
            if detailKind != nil { showDetail(nil) }
            keysAnimateIn = animated
            needsLayout = true
        }
    }

    private var keysSignature = ""
    private var keysAnimateIn = false

    private func refreshKeysIfNeeded() {
        guard actionActive, let r = model?.request else { keysSignature = ""; return }
        let sig = "\(r.id)|\(questionIndex)|\(multiSelected.sorted())|\(Int(action.bounds.width))"
        guard sig != keysSignature else { return }
        keysSignature = sig
        action.show(currentKeys(), animated: keysAnimateIn)
        keysAnimateIn = false
    }

    private func currentKeys() -> [ActionLayer.Key] {
        guard let r = model?.request else { return [] }
        switch r.kind {
        case .permission:
            var keys = [ActionLayer.Key(title: "Deny", action: .deny, style: .normal)]
            if r.canAlwaysAllow { keys.append(.init(title: "Always", action: .always, style: .normal)) }
            keys.append(.init(title: "Allow", action: .allow, style: .primary))
            return keys
        case .plan:
            return [.init(title: "Keep planning", action: .deny, style: .normal),
                    .init(title: "Approve", action: .allow, style: .primary)]
        case .question:
            guard questionIndex < r.questions.count else { return [] }
            let q = r.questions[questionIndex]
            var keys: [ActionLayer.Key] = q.options.enumerated().map { i, o in
                let recommended = o.label.localizedCaseInsensitiveContains("(recommended)")
                let title = o.label.replacingOccurrences(of: " (Recommended)", with: "").replacingOccurrences(of: " (recommended)", with: "")
                let style: ActionLayer.Style = q.multiSelect ? (multiSelected.contains(i) ? .selected : .normal) : (recommended ? .primary : .normal)
                return .init(title: title, action: .option(i), style: style)
            }
            if q.multiSelect { keys.append(.init(title: "Done", action: .submit, style: .primary)) }
            return keys
        }
    }

    private func layoutAction() {
        let w = main.bounds.width
        let lead = widgets.first { $0.kind == .session && !$0.isHidden }?.frame.maxX ?? 0
        let maxW = min(w * 0.58, w - lead - gap - 160)
        CALayer.still { action.frame = CGRect(x: w - maxW, y: 0, width: maxW, height: bounds.height) }
    }

    private func actionWidth() -> CGFloat {
        let keys = currentKeys()
        let natural = keys.reduce(0) { $0 + ActionLayer.width(of: $1) } + ActionLayer.gap * CGFloat(max(keys.count - 1, 0))
        return min(natural, action.bounds.width)
    }

    private func handleKey(_ key: ActionLayer.Key) {
        guard let r = model?.request else { return }
        switch key.action {
        case .allow: send(RequestResponse(id: r.id, action: .allow), confirm: r.kind == .plan ? "Plan approved" : "Allowed")
        case .always: send(RequestResponse(id: r.id, action: .always), confirm: "Always allowed")
        case .deny: send(RequestResponse(id: r.id, action: .deny), confirm: r.kind == .plan ? "Kept planning" : "Denied")
        case .more: onAction?(.openTerminal)
        case .option(let i):
            let q = r.questions[questionIndex]
            if q.multiSelect {
                if multiSelected.contains(i) { multiSelected.remove(i) } else { multiSelected.insert(i) }
                refreshKeysIfNeeded()
            } else {
                answers[q.question] = q.options[i].label
                nextQuestion(r)
            }
        case .submit:
            let q = r.questions[questionIndex]
            answers[q.question] = multiSelected.sorted().map { q.options[$0].label }.joined(separator: ", ")
            nextQuestion(r)
        }
    }

    private func nextQuestion(_ r: PendingRequest) {
        multiSelected = []
        if questionIndex + 1 < r.questions.count {
            questionIndex += 1
            for s in statusWidgets { s.status.update(statusContent(model!), animated: true) }
            keysAnimateIn = true
            refreshKeysIfNeeded()
            needsLayout = true
        } else {
            let summary = answers.count == 1 ? (answers.values.first ?? "Answered") : "Answered"
            send(RequestResponse(id: r.id, action: .answer, answers: answers), confirm: summary)
        }
    }

    private func send(_ response: RequestResponse, confirm: String) {
        confirmation = (response.id, confirm)
        onAction?(.respond(response))
        if let model { render(model) }
    }

    var pageModel: ((Int) -> BarModel?)?

    private var carouselLayers: [CALayer] { widgets.filter { !$0.isHidden }.map(\.slideLayer) + [fallbackStatus] }
    private var maskGeneration = 0
    private static let feather: CGFloat = 8

    private func installMasks() {
        maskGeneration += 1
        CALayer.still {
            for l in carouselLayers {
                let f = Self.feather
                let m = l.mask as? CAGradientLayer ?? CAGradientLayer()
                let w = l.bounds.width + 2 * f
                m.frame = CGRect(x: -f, y: 0, width: w, height: l.bounds.height)
                m.startPoint = CGPoint(x: 0, y: 0.5)
                m.endPoint = CGPoint(x: 1, y: 0.5)
                let clear = NSColor(white: 1, alpha: 0).cgColor, solid = NSColor.white.cgColor
                m.colors = [clear, solid, solid, clear]
                let edge = NSNumber(value: Double(w > 0 ? f / w : 0))
                m.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
                l.mask = m
            }
        }
    }

    private func removeMasks(after delay: TimeInterval) {
        let generation = maskGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.maskGeneration == generation else { return }
            CALayer.still { for l in self.carouselLayers { l.mask = nil } }
        }
    }

    private func slideDirection(previous: BarModel?, current: BarModel) -> CGFloat {
        guard let p = previous else { return 1 }
        return current.pageIndex >= p.pageIndex ? 1 : -1
    }

    private func slideIn(from direction: CGFloat) {
        let start = direction * 34
        installMasks()
        for l in carouselLayers {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = start
            move.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = 0.38
            g.timingFunction = Theme.easeOut
            l.add(g, forKey: "slide")
            let counter = CABasicAnimation(keyPath: "transform.translation.x")
            counter.fromValue = -start
            counter.toValue = 0
            counter.duration = 0.38
            counter.timingFunction = Theme.easeOut
            l.mask?.add(counter, forKey: "slide")
        }
        removeMasks(after: 0.45)
    }

    private let peek = CALayer.plain()
    private lazy var peekRenderer = BarView(frame: .zero)
    private var peekDirection: CGFloat = 0
    private var pageOffset: CGFloat = 0
    private var turning = false
    private var turningCommit = false
    private var arrowsSuppressed = false
    private static let pageGap: CGFloat = 28
    private static let edgeSlot: CGFloat = 16
    private var edgeInset: CGFloat = 0
    private var pageStride: CGFloat { main.bounds.width + Self.pageGap }

    @discardableResult
    private func preparePeek(_ direction: CGFloat) -> Bool {
        if direction == peekDirection { return peek.contents != nil }
        peekDirection = direction
        var image: CGImage?
        if let m = model, m.pages.count > 1, let next = pageModel?(m.pageIndex + Int(direction)) { image = pageImage(next) }
        CALayer.still {
            peek.contents = image
            peek.bounds = main.bounds
            peek.position = main.position
            peek.isHidden = image == nil
        }
        return image != nil
    }

    private func pageImage(_ m: BarModel) -> CGImage? {
        let r = peekRenderer
        r.barLayout = barLayout
        r.answerKeysEnabled = answerKeysEnabled
        r.frame = bounds
        r.render(m, animated: false)
        r.layout()
        func layoutTree(_ l: CALayer) { l.layoutIfNeeded(); l.sublayers?.forEach(layoutTree) }
        layoutTree(r.main)
        let size = r.main.bounds.size, scale = Theme.scale
        guard size.width > 0,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        r.main.render(in: ctx)
        return ctx.makeImage()
    }

    private func setPage(offset: CGFloat) {
        pageOffset = offset
        CALayer.still {
            main.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
            peek.setAffineTransform(CGAffineTransform(translationX: offset + peekDirection * pageStride, y: 0))
        }
    }

    private func animatePage(to target: CGFloat, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let from = pageOffset
        let base = peekDirection * pageStride
        turning = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.turning = false
            completion()
        }
        for (l, shift) in [(main as CALayer, CGFloat(0)), (peek, base)] {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = from + shift
            a.toValue = target + shift
            a.duration = duration
            a.timingFunction = Theme.easeOut
            l.add(a, forKey: "page")
        }
        setPage(offset: target)
        CATransaction.commit()
    }

    private func turnPage(_ direction: CGFloat) {
        guard preparePeek(direction) else { bounce(direction); return }
        setArrowsSuppressed(true)
        let target = -direction * pageStride
        let remaining = Double(abs(target - pageOffset) / max(pageStride, 1))
        animatePage(to: target, duration: 0.16 + 0.22 * remaining) { [weak self] in
            guard let self else { return }
            self.turningCommit = true
            self.onAction?(direction > 0 ? .nextSession : .previousSession)
            self.turningCommit = false
            self.resetPage()
        }
    }

    private func settlePage() {
        animatePage(to: 0, duration: 0.32) { [weak self] in self?.resetPage() }
    }

    private func resetPage() {
        setPage(offset: 0)
        peekDirection = 0
        CALayer.still {
            peek.isHidden = true
            peek.contents = nil
        }
        setArrowsSuppressed(false)
    }

    private func bounce(_ direction: CGFloat) {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -direction * 8, 0]
        a.keyTimes = [0, 0.35, 1]
        a.duration = 0.34
        a.timingFunctions = [Theme.easeOut, Theme.easeInOut]
        main.add(a, forKey: "bounce")
    }

    private func setArrowsSuppressed(_ on: Bool) {
        arrowsSuppressed = on
        CALayer.animate(on ? Theme.quick : Theme.normal) { edges.opacity = on || detailKind != nil ? 0 : 1 }
    }

    func tick(now: Date, model: BarModel? = nil, animated: Bool = true) {
        guard let model = model ?? self.model else { return }
        let animated = animated && detailKind == nil
        let elapsed = elapsedText(model, now: now)
        for s in statusWidgets { s.status.setElapsed(elapsed) }
        var resized = false
        for w in widgets {
            let before = w.preferredWidth
            w.tick(model, now: now, animated: animated)
            if w.preferredWidth != before { resized = true }
        }
        if resized { needsLayout = true }
    }

    private func statusContent(_ m: BarModel) -> StatusLayer.Content {
        if let c = confirmation, m.phase.needsUser {
            return .init(phase: .completed, title: c.text, detail: nil)
        }
        if let r = m.request {
            switch r.kind {
            case .question:
                let q = r.questions[min(questionIndex, r.questions.count - 1)]
                let step = r.questions.count > 1 ? "\(questionIndex + 1)/\(r.questions.count)" : nil
                return .init(phase: .waiting, title: q.question, detail: step ?? (q.multiSelect ? "choose any" : nil))
            case .plan:
                return .init(phase: .waiting, title: r.title, detail: r.detail)
            case .permission:
                return .init(phase: .attention, title: r.title, detail: r.detail)
            }
        }
        var detail: String?
        switch m.phase {
        case .working: detail = m.detail
        case .completed: detail = m.lastTurnDuration.map { "in " + Format.duration($0, seconds: true) }
        case .waiting, .attention, .error: detail = m.message
        case .idle, .offline: detail = nil
        }
        return .init(phase: m.phase, title: m.statusTitle, detail: detail)
    }

    private func elapsedText(_ m: BarModel, now: Date) -> String? {
        guard m.phase == .working || m.phase.needsUser, let start = m.turnStartedAt else { return nil }
        return Format.elapsed(now.timeIntervalSince(start))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(!animatesLayout)
        CATransaction.setAnimationDuration(Theme.normal)
        CATransaction.setAnimationTimingFunction(Theme.easeOut)
        defer { CATransaction.commit() }
        do {
            edgeInset = showsPageArrows && (model?.pages.count ?? 0) > 1 ? Self.edgeSlot : 0
            main.bounds = CGRect(x: 0, y: 0, width: bounds.width - 2 * edgeInset, height: bounds.height)
            main.position = CGPoint(x: bounds.midX, y: bounds.midY)
            peek.bounds = main.bounds
            peek.position = main.position
            edges.frame = bounds
            edges.leftArrow.position = CGPoint(x: edgeInset / 2 + 1, y: bounds.midY)
            edges.rightArrow.position = CGPoint(x: bounds.width - edgeInset / 2 - 1, y: bounds.midY)
            detail.frame = bounds
            let w = main.bounds.width, h = bounds.height
            for x in widgets + [fallbackStatus] { x.adapt(to: adaptWidth ?? w) }
            var limit = w
            if actionActive {
                layoutAction()
                refreshKeysIfNeeded()
                limit = w - actionWidth() - gap
            }
            let answering = actionActive
            var shown = widgets.filter { $0.hasContent && !(answering && yieldsToKeys($0)) }
            if usesFallbackStatus {
                let at = shown.lastIndex { $0.kind == .session || $0.kind == .divider }.map { $0 + 1 } ?? 0
                shown.insert(fallbackStatus, at: at)
            }
            let frames = arrange(shown, limit: limit, answering: answering)
            for x in widgets + [fallbackStatus] {
                if let f = frames[ObjectIdentifier(x)] {
                    let target = CGRect(x: f.minX, y: 0, width: f.width, height: h)
                    if x.isHidden || x.frame.width == 0 { CALayer.still { x.frame = target } } else { x.frame = target }
                    x.isHidden = false
                } else if !(answering && yieldsToKeys(x)) {
                    x.isHidden = x !== fallbackStatus || !usesFallbackStatus
                }
                x.setNeedsLayout()
            }
        }
    }

    private func yieldsToKeys(_ w: Widget) -> Bool {
        guard let statusIndex = widgets.firstIndex(where: { $0.kind == .status }) else {
            return !(w.kind == .session || w.kind == .divider)
        }
        guard let i = widgets.firstIndex(where: { $0 === w }) else { return false }
        return i > statusIndex
    }

    private func spacing(_ a: Widget, _ b: Widget) -> CGFloat {
        a.kind == .divider || b.kind == .divider ? gap / 2 : gap
    }

    private func arrange(_ input: [Widget], limit: CGFloat, answering: Bool) -> [ObjectIdentifier: CGRect] {
        let leading: CGFloat = 6
        var list = input
        func trimDividers() {
            while list.first?.kind == .divider { list.removeFirst() }
            while list.last?.kind == .divider { list.removeLast() }
        }
        func gaps() -> CGFloat { zip(list, list.dropFirst()).reduce(0) { $0 + spacing($1.0, $1.1) } }
        func fixed() -> CGFloat { list.filter { !$0.kind.isFlexible }.reduce(0) { $0 + $1.preferredWidth } }
        func flexMinimum() -> CGFloat { list.filter { $0.kind.isFlexible }.reduce(0) { $0 + $1.minimumWidth } }
        trimDividers()
        while list.count > 1 && leading + fixed() + gaps() + flexMinimum() > limit {
            if let i = list.lastIndex(where: { !$0.kind.isFlexible && $0.kind != .session && $0.kind != .divider }) {
                list.remove(at: i)
            } else if let i = list.lastIndex(where: { $0.kind == .flexSpace }) {
                list.remove(at: i)
            } else {
                list.removeLast()
            }
            trimDividers()
        }
        var remaining = max(limit - leading - fixed() - gaps(), 0)
        var widths: [ObjectIdentifier: CGFloat] = [:]
        let spaces = list.filter { $0.kind == .flexSpace }
        for s in list where s.kind == .status {
            let want = spaces.isEmpty || answering ? remaining : min(max(s.preferredWidth, s.minimumWidth), remaining)
            widths[ObjectIdentifier(s)] = want
            remaining -= want
        }
        for s in spaces { widths[ObjectIdentifier(s)] = remaining / CGFloat(spaces.count) }
        var frames: [ObjectIdentifier: CGRect] = [:]
        var x = leading
        for (i, item) in list.enumerated() {
            if i > 0 { x += spacing(list[i - 1], item) }
            let width = widths[ObjectIdentifier(item)] ?? item.preferredWidth
            frames[ObjectIdentifier(item)] = CGRect(x: round(x), y: 0, width: round(width), height: 0)
            x += width
        }
        return frames
    }

    func showDetail(_ kind: DetailKind?) {
        guard kind != detailKind else { return }
        detailKind = kind
        detailTimer?.cancel()
        setArrowsSuppressed(arrowsSuppressed)
        if let kind, let model {
            CALayer.still {
                detail.isHidden = false
                detail.frame = bounds
                detail.show(detailItems(kind, model: model, now: Date()))
            }
            transition(show: detail, hide: main)
            scheduleDetailTimeout()
        } else {
            transition(show: main, hide: detail) { [weak self] in
                if self?.detailKind == nil { self?.detail.isHidden = true }
            }
        }
    }

    private func scheduleDetailTimeout() {
        detailTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showDetail(nil) }
        detailTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func transition(show: CALayer, hide: CALayer, completion: (() -> Void)? = nil) {
        CALayer.still {
            show.opacity = 1
            hide.opacity = 0
        }
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        let scaleIn = CABasicAnimation(keyPath: "transform.scale")
        scaleIn.fromValue = 1.035
        scaleIn.toValue = 1
        let inGroup = CAAnimationGroup()
        inGroup.animations = [fadeIn, scaleIn]
        inGroup.duration = Theme.normal
        inGroup.beginTime = CACurrentMediaTime() + 0.06
        inGroup.fillMode = .backwards
        inGroup.timingFunction = Theme.easeOut
        show.add(inGroup, forKey: "transition")

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        let scaleOut = CABasicAnimation(keyPath: "transform.scale")
        scaleOut.fromValue = 1
        scaleOut.toValue = 0.97
        let outGroup = CAAnimationGroup()
        outGroup.animations = [fadeOut, scaleOut]
        outGroup.duration = Theme.quick
        outGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        hide.add(outGroup, forKey: "transition")
        CATransaction.commit()
    }

    private func detailItems(_ kind: DetailKind, model m: BarModel, now: Date) -> [DetailLayer.Item] {
        switch kind {
        case .usage:
            guard let u = m.usage else { return [.text(NSAttributedString("No usage data yet", font: Theme.status, color: Theme.secondary))] }
            let title = u.isEstimate ? "\(Format.hours(u.window)) window · estimated" : "\(Format.hours(u.window)) limit"
            var items: [DetailLayer.Item] = [
                .text(NSAttributedString(title, font: Theme.small, color: Theme.secondary)),
                .bar(fill: u.fillFraction(at: now), ghost: u.usedFraction != nil ? u.timeFraction(at: now) : nil,
                     tint: Theme.usageTint(u.fillFraction(at: now))),
            ]
            if let used = u.usedFraction { items.append(.pair(Format.percent(used), "used", Theme.usageTint(used))) }
            items.append(.pair(Format.duration(u.elapsed(at: now)), "elapsed"))
            if let reset = u.resetsAt, u.windowStart != nil {
                items.append(.pair(Format.duration(u.remaining(at: now)), "to reset · \(Format.clock(reset))"))
            } else {
                items.append(.pair("—", "no active window"))
            }
            if let weekly = u.weeklyFraction { items += [.separator, .pair(Format.percent(weekly), "this week")] }
            return items

        case .project:
            guard let p = m.project else { return [.text(NSAttributedString("No project", font: Theme.status, color: Theme.secondary))] }
            var items: [DetailLayer.Item] = [
                .text(NSAttributedString(p.name, font: Theme.status, color: Theme.primary)),
                .text(NSAttributedString(p.displayPath, font: Theme.small, color: Theme.tertiary)),
            ]
            if let branch = p.branch { items += [.separator, .pair(branch, "branch")] }
            if let n = p.changedFiles { items.append(.pair("\(n)", n == 1 ? "file changed" : "files changed")) }
            if let a = m.linesAdded, let r = m.linesRemoved, a + r > 0 {
                items.append(.pair("+\(a) −\(r)", "lines this session"))
            }
            if m.sessionCount > 1 { items.append(.pair("\(m.pageIndex + 1)/\(m.sessionCount)", "sessions")) }
            items += [.button("Finder", symbol: "folder", action: .openFinder),
                      .button("Terminal", symbol: "terminal", action: .openTerminal)]
            return items

        case .status:
            var items: [DetailLayer.Item] = []
            if let topic = m.topic { items += [.text(NSAttributedString(topic, font: Theme.topic, color: Theme.secondary)), .separator] }
            items += [
                .glyph(m.phase),
                .text(NSAttributedString(m.statusTitle, font: Theme.status, color: Theme.primary)),
            ]
            let detail = m.phase == .working ? m.detail : m.message
            if let detail { items.append(.text(NSAttributedString(detail, font: Theme.statusDetail, color: Theme.secondary))) }
            items.append(.separator)
            if let start = m.turnStartedAt {
                items.append(.pair(Format.duration(now.timeIntervalSince(start), seconds: true), "this turn"))
            } else if let last = m.lastTurnDuration {
                items.append(.pair(Format.duration(last, seconds: true), "last turn"))
            }
            if m.toolCount > 0 { items.append(.pair("\(m.toolCount)", m.toolCount == 1 ? "tool call" : "tool calls")) }
            if let ctx = m.contextPercent {
                let f = ctx / 100
                items.append(.pair(Format.percent(f), "context", f >= 0.85 ? Theme.amber : Theme.primary))
            }
            if let model = m.modelName { items.append(.pair(model, m.effort.map { "· \($0)" } ?? "")) }
            if m.source == .basic { items.append(.pair("basic", "connect hooks for detail", Theme.secondary)) }
            items.append(.button("Terminal", symbol: "terminal", action: .openTerminal))
            return items
        }
    }

    private enum Target: Equatable { case widget(String), detail(Int), key(Int), previous, next }
    private var active: Target?
    private var startPoint: CGPoint = .zero
    private var swiped = false

    private func target(at p: CGPoint) -> Target? {
        if detailKind != nil {
            if let t = detail.target(at: p), let i = detail.targets.firstIndex(where: { $0.frame == t.frame }) { return .detail(i) }
            return .detail(-1)
        }
        if actionActive, let i = action.key(at: action.convert(p, from: layer)) { return .key(i) }
        if p.x < edgeInset + 4 && edges.hasLeft { return .previous }
        if p.x > bounds.width - edgeInset - 4 && edges.hasRight { return .next }
        let x = p.x - edgeInset
        let live = (widgets + [fallbackStatus]).filter { !$0.isHidden && $0.opacity > 0 }
        let hit = live.first { $0.frame.insetBy(dx: -gap / 2, dy: 0).contains(CGPoint(x: x, y: $0.frame.midY)) }
            ?? live.min { abs($0.frame.midX - x) < abs($1.frame.midX - x) }
        return hit.map { .widget($0.config.id) }
    }

    private func widget(_ id: String) -> Widget? {
        id == fallbackStatus.config.id ? fallbackStatus : widgets.first { $0.config.id == id }
    }

    private func setPressed(_ t: Target?, _ on: Bool) {
        guard let t else { return }
        switch t {
        case .widget(let id):
            guard let w = widget(id), w.tap != .none else { return }
            if w.usesKeyPress {
                w.setPressed(on)
            } else {
                CALayer.still { pressHighlight.frame = w.frame.insetBy(dx: -8, dy: 1) }
                CALayer.animate(on ? 0.08 : Theme.normal) { pressHighlight.opacity = on ? 1 : 0 }
            }
        case .key(let i):
            action.setPressed(i, on)
        case .previous, .next:
            let arrow = t == .previous ? edges.leftArrow : edges.rightArrow
            CALayer.animate(on ? 0.06 : Theme.normal) { arrow.setAffineTransform(on ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity) }
        case .detail(let i):
            guard i >= 0, i < detail.targets.count, let h = detail.targets[i].highlight else { return }
            CALayer.animate(on ? 0.08 : Theme.normal) {
                h.backgroundColor = (on ? Theme.keyPressed : Theme.key).cgColor
            }
        }
    }

    private func began(at p: CGPoint) {
        active = turning ? nil : target(at: p)
        startPoint = p
        swiped = false
        velocity = 0
        lastMove = (p.x, CACurrentMediaTime())
        setPressed(active, true)
        if detailKind != nil { scheduleDetailTimeout() }
    }

    private var dragging = false
    private var lastMove: (x: CGFloat, time: CFTimeInterval) = (0, 0)
    private var velocity: CGFloat = 0

    private var canDrag: Bool {
        switch active {
        case .widget?, .previous?, .next?: return true
        default: return false
        }
    }

    private func moved(to p: CGPoint) {
        guard canDrag, !turning else { return }
        let dx = p.x - startPoint.x
        if !dragging && abs(dx) > 8 {
            dragging = true
            swiped = true
            setPressed(active, false)
            setArrowsSuppressed(true)
        }
        guard dragging else { return }
        let now = CACurrentMediaTime()
        if now - lastMove.time > 0.001 {
            let v = (p.x - lastMove.x) / CGFloat(now - lastMove.time)
            velocity = velocity * 0.4 + v * 0.6
        }
        lastMove = (p.x, now)
        let direction: CGFloat = dx < 0 ? 1 : -1
        setPage(offset: preparePeek(direction) ? dx : 14 * tanh(dx / 70))
    }

    private func finishDrag() {
        dragging = false
        let direction: CGFloat = pageOffset < 0 ? 1 : -1
        let flick = abs(velocity) > 350 && (velocity < 0) == (direction > 0) && abs(pageOffset) > 24
        let far = abs(pageOffset) > main.bounds.width * 0.3
        if peek.contents != nil && peekDirection == direction && (far || flick) {
            turnPage(direction)
        } else {
            settlePage()
        }
    }

    private func ended(at p: CGPoint?) {
        guard let t = active else { return }
        active = nil
        setPressed(t, false)
        if dragging { finishDrag(); return }
        guard !swiped, let p, target(at: p) == t else { return }
        switch t {
        case .widget(let id):
            guard let w = widget(id) else { return }
            switch w.tap {
            case .none: break
            case .action(let a): onAction?(a)
            case .detail(let kind):
                if actionActive && w is StatusWidget { onAction?(.openTerminal) } else { showDetail(kind) }
            }
        case .key(let i): if i < action.keys.count { handleKey(action.keys[i].key) }
        case .previous: turnPage(-1)
        case .next: turnPage(1)
        case .detail(let i):
            if i >= 0, i < detail.targets.count {
                let action = detail.targets[i].action
                if action == .closeDetail { showDetail(nil) } else { onAction?(action) }
            } else {
                showDetail(nil)
            }
        }
    }

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        began(at: touch.location(in: self))
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = event.touches(matching: .moved, in: self).first else { return }
        moved(to: touch.location(in: self))
    }

    override func touchesEnded(with event: NSEvent) {
        let touch = event.touches(matching: .ended, in: self).first
        ended(at: touch?.location(in: self))
    }

    override func touchesCancelled(with event: NSEvent) {
        swiped = true
        ended(at: nil)
    }

    override func mouseDown(with event: NSEvent) { began(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { moved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { ended(at: convert(event.locationInWindow, from: nil)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
