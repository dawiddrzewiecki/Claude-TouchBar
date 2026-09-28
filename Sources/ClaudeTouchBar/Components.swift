import AppKit
import ClaudeBarCore

final class StateGlyphLayer: CALayer {
    private let spinner = CALayer.plain()
    private let dot = CAShapeLayer()
    private let check = CAShapeLayer()
    private let alert = CALayer.plain()
    private let alertDisc = CAShapeLayer()
    private let alertMark = TextLayer()
    private let dash = CAShapeLayer()
    private var shownPhase: Phase?
    private static var frames: [CGImage] = Glyphs.spinnerFrames(size: 16, color: Theme.clay)

    override init() {
        super.init()
        contentsScale = Theme.scale
        bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        let r = bounds
        for l in [spinner, dot, check, alert, dash] as [CALayer] {
            l.frame = r
            l.opacity = 0
            addSublayer(l)
        }
        spinner.contents = Self.frames[4]
        spinner.contentsGravity = .center
        spinner.contentsScale = Theme.scale

        dot.path = CGPath(ellipseIn: r.insetBy(dx: 4.5, dy: 4.5), transform: nil)
        dot.contentsScale = Theme.scale

        check.path = Glyphs.checkPath(in: r.insetBy(dx: 2, dy: 2.5))
        check.fillColor = nil
        check.strokeColor = Theme.green.cgColor
        check.lineWidth = 2.1
        check.lineCap = .round
        check.lineJoin = .round
        check.contentsScale = Theme.scale

        alertDisc.path = CGPath(ellipseIn: r.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        alertDisc.fillColor = Theme.red.cgColor
        alertDisc.frame = r
        alert.addSublayer(alertDisc)
        alertMark.text = NSAttributedString("!", font: .systemFont(ofSize: 11, weight: .heavy), color: .black)
        alertMark.alignmentMode = .center
        alertMark.place(x: 0, midY: 8, width: 16)
        alert.addSublayer(alertMark)

        let d = CGMutablePath()
        d.move(to: CGPoint(x: 4.5, y: 8))
        d.addLine(to: CGPoint(x: 11.5, y: 8))
        dash.path = d
        dash.strokeColor = Theme.tertiary.cgColor
        dash.lineWidth = 1.6
        dash.lineCap = .round
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ phase: Phase, animated: Bool) {
        guard phase != shownPhase else { return }
        let previous = shownPhase
        shownPhase = phase

        let target: CALayer
        switch phase {
        case .working: target = spinner
        case .waiting, .attention, .idle: target = dot
        case .completed: target = check
        case .error: target = alert
        case .offline: target = dash
        }

        CALayer.still {
            dot.fillColor = Theme.accent(for: phase).cgColor
            if phase == .idle { dot.fillColor = Theme.secondary.cgColor }
        }

        let all: [CALayer] = [spinner, dot, check, alert, dash]
        CALayer.animate(animated ? Theme.quick : 0) {
            for l in all { l.opacity = (l === target) ? 1 : 0 }
        }

        if phase == .working {
            if spinner.animation(forKey: "spin") == nil {
                let a = CAKeyframeAnimation(keyPath: "contents")
                a.values = Self.frames
                a.calculationMode = .discrete
                a.duration = 0.12 * Double(Self.frames.count)
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                spinner.add(a, forKey: "spin")
            }
        } else {
            spinner.removeAnimation(forKey: "spin")
        }

        dot.removeAnimation(forKey: "breathe")
        if phase.needsUser {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = phase == .attention ? 0.9 : 1.4
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = Theme.easeInOut
            dot.add(a, forKey: "breathe")
        }

        if phase == .completed && animated && previous != nil {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.42
            draw.beginTime = CACurrentMediaTime() + 0.06
            draw.fillMode = .backwards
            draw.timingFunction = Theme.easeOut
            check.add(draw, forKey: "draw")
        }
    }
}

final class ClaudeMarkLayer: CALayer {
    private var rays: [CAShapeLayer] = []
    private let size: CGFloat
    private var mode: Mode = .still
    var motion: Motion = .lively {
        didSet {
            guard motion != oldValue else { return }
            let current = mode
            mode = .still
            set(current)
        }
    }

    enum Mode { case still, working, waiting, offline }
    enum Motion: String { case lively, calm, off }

    private static let lengths: [CGFloat] = [1.0, 0.8, 0.94, 0.76, 0.98, 0.84, 0.92, 0.78, 1.0, 0.82, 0.9, 0.77]

    init(size: CGFloat) {
        self.size = size
        super.init()
        contentsScale = Theme.scale
        bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let r = size / 2
        let c = CGPoint(x: r, y: r)
        for (i, k) in Self.lengths.enumerated() {
            let holder = CALayer.plain()
            holder.frame = bounds
            holder.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(i) / CGFloat(Self.lengths.count) * .pi * 2))
            let ray = CAShapeLayer()
            ray.contentsScale = Theme.scale
            ray.frame = bounds
            let line = CGMutablePath()
            line.move(to: CGPoint(x: c.x, y: c.y + r * 0.2))
            line.addLine(to: CGPoint(x: c.x, y: c.y + r * k))
            ray.path = line.copy(strokingWithWidth: r * 0.21, lineCap: .round, lineJoin: .round, miterLimit: 1)
            holder.addSublayer(ray)
            addSublayer(holder)
            rays.append(ray)
        }
        let core = CAShapeLayer()
        core.path = CGPath(ellipseIn: CGRect(x: c.x - r * 0.26, y: c.y - r * 0.26, width: r * 0.52, height: r * 0.52), transform: nil)
        core.frame = bounds
        core.name = "core"
        addSublayer(core)
        setColor(Theme.claude)
    }

    override init(layer: Any) {
        size = (layer as? ClaudeMarkLayer)?.size ?? 16
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ color: NSColor) {
        for ray in rays { ray.fillColor = color.cgColor }
        (sublayers?.first { $0.name == "core" } as? CAShapeLayer)?.fillColor = color.cgColor
    }

    func set(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        for ray in rays { ray.removeAnimation(forKey: "breathe") }
        removeAnimation(forKey: "turn")
        let now = CACurrentMediaTime()
        guard motion != .off else { return }
        switch new {
        case .working where motion == .calm:
            breatheUniformly(to: 0.84, duration: 2.1, now: now)
        case .working:
            for (i, ray) in rays.enumerated() {
                let a = CAKeyframeAnimation(keyPath: "transform.scale")
                let lo = 0.62 + 0.08 * Double(i % 3)
                a.values = [1, lo, 1.1, 0.86, 1]
                a.keyTimes = [0, 0.3, 0.55, 0.8, 1]
                a.duration = 1.25 + Double((i * 7) % 5) * 0.17
                a.beginTime = now - Double((i * 5) % 12) * 0.11
                a.repeatCount = .infinity
                a.timingFunctions = Array(repeating: Theme.easeInOut, count: 4)
                ray.add(a, forKey: "breathe")
            }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -CGFloat.pi * 2
            turn.duration = 16
            turn.repeatCount = .infinity
            add(turn, forKey: "turn")
        case .waiting:
            breatheUniformly(to: 0.78, duration: 1.3, now: now)
        case .still, .offline:
            break
        }
    }

    private func breatheUniformly(to scale: CGFloat, duration: CFTimeInterval, now: CFTimeInterval) {
        for ray in rays {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1
            a.toValue = scale
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = Theme.easeInOut
            a.beginTime = now
            ray.add(a, forKey: "breathe")
        }
    }

    func pulse() {
        guard motion != .off else { return }
        let p = CAKeyframeAnimation(keyPath: "transform.scale")
        p.values = [1, 1.16, 1]
        p.keyTimes = [0, 0.35, 1]
        p.duration = 0.6
        p.timingFunctions = [Theme.easeOut, Theme.easeInOut]
        add(p, forKey: "pulse")
    }
}

final class IdentityLayer: CALayer {
    let mark = ClaudeMarkLayer(size: 18)
    let badge = CAShapeLayer()
    let carousel = CALayer.plain()
    let title = TextLayer()
    let tag = CALayer.plain()
    let tagText = TextLayer()
    private var dots: [CAShapeLayer] = []
    var showsTitle = true
    var showsDots = true
    var markColor: MarkColor = .claude
    var maxTitleWidth: CGFloat = 200
    var isDemo = false

    enum MarkColor: String { case claude, white, status }
    private var phase: Phase = .offline
    private var pages: [SessionPage] = []
    private var pageIndex = 0

    override init() {
        super.init()
        contentsScale = Theme.scale
        addSublayer(mark)

        badge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 7, height: 7), transform: nil)
        badge.lineWidth = 1.5
        badge.strokeColor = NSColor.black.cgColor
        badge.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        badge.opacity = 0
        addSublayer(badge)

        addSublayer(carousel)
        title.text = NSAttributedString("Claude", font: Theme.label, color: Theme.primary)
        carousel.addSublayer(title)

        tag.backgroundColor = Theme.quaternary.cgColor
        tag.cornerRadius = 3
        tagText.text = NSAttributedString("DEMO", font: Theme.tag, color: Theme.secondary, kern: 0.6)
        tag.addSublayer(tagText)
        carousel.addSublayer(tag)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private var tagWidth: CGFloat { (tagText.text?.width ?? 0) + 8 }
    private static let dotSize: CGFloat = 4.5
    private static let dotGap: CGFloat = 5
    private var dotsWidth: CGFloat {
        pages.count > 1 ? CGFloat(pages.count) * Self.dotSize + CGFloat(pages.count - 1) * Self.dotGap : 0
    }
    private var titleWidth: CGFloat { min(title.text?.width ?? 0, maxTitleWidth) }

    private var hasLabel: Bool { showsTitle || isDemo }

    var contentWidth: CGFloat {
        var inner: CGFloat = 0
        if showsTitle { inner += titleWidth }
        if isDemo { inner += (showsTitle ? 6 : 0) + tagWidth }
        if dotsWidth > 0 { inner += (hasLabel ? 9 : 0) + dotsWidth }
        return ceil(18 + (inner > 0 ? 8 + inner : 0))
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still {
            let mid = bounds.midY
            mark.position = CGPoint(x: 9, y: mid)
            badge.position = CGPoint(x: 16.5, y: mid - 6.5)
            carousel.frame = CGRect(x: 26, y: 0, width: max(bounds.width - 26, 0), height: bounds.height)
            var x: CGFloat = 0
            title.isHidden = !showsTitle
            if showsTitle {
                title.place(x: x, midY: mid, width: titleWidth)
                x += titleWidth
            }
            tag.isHidden = !isDemo
            if isDemo {
                let tx = x + (showsTitle ? 6 : 0)
                tag.frame = CGRect(x: tx, y: mid - 6.5, width: tagWidth, height: 13)
                tagText.place(x: 4, midY: 6.5)
                x = tx + tagWidth
            }
            if hasLabel { x += 9 }
            for (i, d) in dots.enumerated() {
                d.position = CGPoint(x: x + Self.dotSize / 2 + CGFloat(i) * (Self.dotSize + Self.dotGap), y: mid)
            }
        }
    }

    func update(phase: Phase, topic: String?, pages: [SessionPage], pageIndex: Int, animated: Bool) {
        let previous = self.phase
        self.phase = phase
        CALayer.still {
            title.text = NSAttributedString(topic ?? "Claude", font: topic == nil ? Theme.label : Theme.topic,
                                            color: phase == .offline ? Theme.tertiary : (topic == nil ? Theme.primary : Theme.topicInk))
        }
        updateDots(showsDots ? pages : [], pageIndex)

        mark.set({
            switch phase {
            case .working: return .working
            case .waiting, .attention: return .waiting
            case .offline: return .offline
            default: return .still
            }
        }())
        let badgeColor: NSColor? = {
            switch phase {
            case .waiting: return Theme.blue
            case .attention: return Theme.amber
            case .error: return Theme.red
            default: return nil
            }
        }()
        CALayer.animate(animated ? Theme.normal : 0) {
            mark.setColor(markTint(phase))
            if let badgeColor { badge.fillColor = badgeColor.cgColor }
            badge.opacity = badgeColor == nil ? 0 : 1
        }
        if animated && previous == .working && phase == .completed { mark.pulse() }
    }

    private func markTint(_ phase: Phase) -> NSColor {
        if phase == .offline { return Theme.tertiary }
        switch markColor {
        case .claude: return Theme.claude
        case .white: return Theme.primary
        case .status: return phase == .working ? Theme.claude : Theme.accent(for: phase)
        }
    }

    private func updateDots(_ pages: [SessionPage], _ index: Int) {
        let countChanged = pages.count != self.pages.count
        self.pages = pages
        self.pageIndex = index
        setNeedsLayout()
        if countChanged {
            dots.forEach { $0.removeFromSuperlayer() }
            dots = pages.count > 1 ? pages.map { _ in
                let d = CAShapeLayer()
                d.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize), transform: nil)
                d.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
                d.contentsScale = Theme.scale
                carousel.addSublayer(d)
                return d
            } : []
            setNeedsLayout()
        }
        for (i, d) in dots.enumerated() {
            let color: NSColor
            if i == index {
                color = NSColor(white: 1, alpha: 0.9)
            } else {
                switch pages[i].phase {
                case .attention: color = Theme.amber
                case .waiting: color = Theme.blue
                case .working: color = Theme.claude.withAlphaComponent(0.85)
                case .completed: color = Theme.green.withAlphaComponent(0.85)
                case .error: color = Theme.red
                default: color = Theme.quaternary
                }
            }
            d.fillColor = color.cgColor
            d.setAffineTransform(i == index ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity)
        }
    }
}

final class PageArrowsLayer: CALayer {
    let leftArrow = CAShapeLayer()
    let rightArrow = CAShapeLayer()
    private var pages: [SessionPage] = []
    private var pageIndex = 0
    var hasLeft: Bool { pageIndex > 0 && pages.count > 1 }
    var hasRight: Bool { pageIndex < pages.count - 1 && pages.count > 1 }

    override init() {
        super.init()
        contentsScale = Theme.scale
        for (arrow, pointsLeft) in [(leftArrow, true), (rightArrow, false)] {
            let r = CGRect(x: 0, y: 0, width: 6, height: 11)
            let p = CGMutablePath()
            if pointsLeft {
                p.move(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            } else {
                p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            }
            arrow.path = p
            arrow.bounds = r
            arrow.fillColor = nil
            arrow.lineWidth = 1.9
            arrow.lineCap = .round
            arrow.lineJoin = .round
            arrow.opacity = 0
            arrow.contentsScale = Theme.scale
            addSublayer(arrow)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func urgency(_ p: Phase) -> Int {
        switch p {
        case .attention: return 5
        case .waiting: return 4
        case .error: return 3
        case .completed: return 2
        case .working: return 1
        default: return 0
        }
    }

    private func arrowColor(_ side: ArraySlice<SessionPage>) -> NSColor {
        guard let top = side.max(by: { urgency($0.phase) < urgency($1.phase) }) else { return Theme.secondary }
        switch top.phase {
        case .attention: return Theme.amber
        case .waiting: return Theme.blue
        case .error: return Theme.red
        default: return Theme.secondary
        }
    }

    func update(pages: [SessionPage], pageIndex: Int, nudge: Bool) {
        self.pages = pages
        self.pageIndex = pageIndex
        let left = pages.prefix(max(pageIndex, 0))
        let right = pages.count > pageIndex + 1 ? pages.suffix(from: pageIndex + 1) : []
        let leftColor = arrowColor(left), rightColor = arrowColor(right)
        CALayer.animate(Theme.normal) {
            leftArrow.opacity = hasLeft ? 1 : 0
            rightArrow.opacity = hasRight ? 1 : 0
            leftArrow.strokeColor = leftColor.cgColor
            rightArrow.strokeColor = rightColor.cgColor
        }
        for (arrow, color, dir) in [(leftArrow, leftColor, CGFloat(-1)), (rightArrow, rightColor, CGFloat(1))] {
            let urgent = color == Theme.amber || color == Theme.blue
            let key = "nudge"
            if (nudge || urgent) && arrow.opacity > 0 {
                guard arrow.animation(forKey: key) == nil else { continue }
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                a.values = [0, 3 * dir, 0, 2 * dir, 0]
                a.keyTimes = [0, 0.2, 0.45, 0.65, 1]
                a.duration = 0.9
                a.timingFunctions = Array(repeating: Theme.easeInOut, count: 4)
                if urgent {
                    let g = CAAnimationGroup()
                    g.animations = [a]
                    g.duration = 2.6
                    g.repeatCount = .infinity
                    arrow.add(g, forKey: key)
                } else {
                    arrow.add(a, forKey: key)
                }
            } else if !urgent {
                arrow.removeAnimation(forKey: key)
            }
        }
    }
}

final class UsageLayer: CALayer {
    enum Style: String, CaseIterable {
        case key, segmented, slim, ring, text
        var usesKey: Bool { self == .key || self == .segmented }
    }

    private let clip = CALayer.plain()
    private let bars = CALayer.plain()
    private let track = CALayer.plain()
    private let ghost = CALayer.plain()
    private let fill = CALayer.plain()
    private let segments = CALayer.plain()
    private let lightText = CALayer.plain()
    private let darkText = CALayer.plain()
    private let lightMask = CALayer.plain()
    private let darkMask = CALayer.plain()
    private let leftLight = TextLayer(), rightLight = TextLayer()
    private let leftDark = TextLayer(), rightDark = TextLayer()
    private let plainLeft = TextLayer(), plainRight = TextLayer()
    private let slimTrack = CALayer.plain(), slimGhost = CALayer.plain(), slimFill = CALayer.plain()
    private let ringTrack = CAShapeLayer(), ring = CAShapeLayer()

    var barWidth: CGFloat = 240
    var meterStyle: Style = .key { didSet { if meterStyle != oldValue { applyStyle(); setNeedsLayout() } } }
    var warn: Double? = 0.8
    var showsRightLabel = true
    private(set) var fraction: Double = 0
    private var ghostFraction: Double = 0
    private var tint = Theme.usageTint(0)
    private var pressed = false
    private var left = "", right: String?

    static let radius: CGFloat = 6.5
    static let ringSize: CGFloat = 18

    override init() {
        super.init()
        contentsScale = Theme.scale
        clip.masksToBounds = true
        clip.cornerRadius = Self.radius
        addSublayer(clip)
        track.backgroundColor = Theme.key.cgColor
        clip.addSublayer(track)
        clip.addSublayer(bars)
        ghost.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        for l in [ghost, fill] { bars.addSublayer(l) }

        lightMask.backgroundColor = NSColor.black.cgColor
        darkMask.backgroundColor = NSColor.black.cgColor
        lightText.mask = lightMask
        darkText.mask = darkMask
        lightText.addSublayer(leftLight); lightText.addSublayer(rightLight)
        darkText.addSublayer(leftDark); darkText.addSublayer(rightDark)
        clip.addSublayer(lightText)
        clip.addSublayer(darkText)
        rightLight.alignmentMode = .right
        rightDark.alignmentMode = .right

        slimTrack.backgroundColor = Theme.key.cgColor
        slimTrack.masksToBounds = true
        slimGhost.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        slimTrack.addSublayer(slimGhost)
        slimTrack.addSublayer(slimFill)
        addSublayer(slimTrack)
        for r in [ringTrack, ring] {
            r.fillColor = nil
            r.lineWidth = 2.6
            r.lineCap = .round
            r.contentsScale = Theme.scale
            addSublayer(r)
        }
        ringTrack.strokeColor = NSColor(white: 1, alpha: 0.16).cgColor
        ringTrack.strokeEnd = 1
        addSublayer(plainLeft)
        addSublayer(plainRight)
        applyStyle()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        CALayer.still {
            clip.isHidden = !meterStyle.usesKey
            slimTrack.isHidden = meterStyle != .slim
            ringTrack.isHidden = meterStyle != .ring
            ring.isHidden = meterStyle != .ring
            plainLeft.isHidden = meterStyle.usesKey
            plainRight.isHidden = meterStyle.usesKey
        }
    }

    private var plainRightShown: Bool { showsRightLabel && (plainRight.text?.length ?? 0) > 0 }
    private var plainTextWidth: CGFloat { (plainLeft.text?.width ?? 0) + (plainRightShown ? 6 + (plainRight.text?.width ?? 0) : 0) }

    var contentWidth: CGFloat {
        switch meterStyle {
        case .key, .segmented, .slim: return barWidth
        case .ring: return Self.ringSize + 7 + plainTextWidth
        case .text: return plainTextWidth
        }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still {
            layoutMeter()
            layoutLabels()
            layoutSegments()
        }
    }

    private var keyRect: CGRect { CGRect(x: 0, y: 0, width: barWidth, height: bounds.height).insetBy(dx: 0, dy: 1) }

    private func layoutMeter() {
        let r = keyRect
        clip.frame = r
        let local = CGRect(origin: .zero, size: r.size)
        lightText.frame = local
        darkText.frame = local
        track.frame = local
        track.backgroundColor = (pressed ? Theme.keyPressed : Theme.key).cgColor
        if meterStyle == .segmented {
            let x = 10 + (leftLight.text?.width ?? 0) + 9
            let h: CGFloat = 12
            bars.frame = CGRect(x: x, y: (local.height - h) / 2, width: max(local.width - x - 9, 0), height: h)
        } else {
            bars.frame = local
        }
        let bw = bars.bounds.width, bh = bars.bounds.height
        ghost.frame = CGRect(x: 0, y: 0, width: bw * ghostFraction, height: bh)
        fill.frame = CGRect(x: 0, y: 0, width: bw * fraction, height: bh)
        fill.backgroundColor = tint.cgColor
        let fw = meterStyle == .segmented ? 0 : local.width * fraction
        darkMask.frame = CGRect(x: 0, y: 0, width: fw, height: local.height)
        lightMask.frame = CGRect(x: fw, y: 0, width: max(local.width - fw, 0), height: local.height)

        let tw = slimTrack.bounds.width
        slimGhost.frame = CGRect(x: 0, y: 0, width: tw * ghostFraction, height: slimTrack.bounds.height)
        slimFill.frame = CGRect(x: 0, y: 0, width: tw * fraction, height: slimTrack.bounds.height)
        slimFill.backgroundColor = tint.cgColor
        slimFill.cornerRadius = slimTrack.cornerRadius
        ring.strokeEnd = CGFloat(fraction)
        ring.strokeColor = tint.cgColor
    }

    private func layoutLabels() {
        let w = keyRect.width, mid = keyRect.height / 2, pad: CGFloat = 10
        for (l, r) in [(leftLight, rightLight), (leftDark, rightDark)] {
            l.place(x: pad, midY: mid)
            let rw = r.text?.width ?? 0
            let room = w - pad * 2 - (l.text?.width ?? 0) - 12
            r.isHidden = !showsRightLabel || rw > room || meterStyle == .segmented
            r.place(x: w - pad - rw, midY: mid, width: rw)
        }

        let bmid = bounds.midY
        let lw = plainLeft.text?.width ?? 0, rw = plainRight.text?.width ?? 0
        switch meterStyle {
        case .key, .segmented:
            break
        case .slim:
            plainLeft.place(x: 0, midY: bmid, width: lw)
            let showRight = plainRightShown && barWidth - lw - rw - 16 >= 40
            plainRight.isHidden = !showRight
            let trackEnd = showRight ? barWidth - rw - 8 : barWidth
            plainRight.place(x: barWidth - rw, midY: bmid, width: rw)
            let t: CGFloat = 5
            let trackX = lw + 8
            slimTrack.frame = CGRect(x: trackX, y: bmid - t / 2, width: max(trackEnd - trackX, 0), height: t)
            slimTrack.cornerRadius = t / 2
            layoutMeter()
        case .ring:
            let rect = CGRect(x: 0, y: bmid - Self.ringSize / 2, width: Self.ringSize, height: Self.ringSize).insetBy(dx: 1.4, dy: 1.4)
            var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
            let path = CGPath(ellipseIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), transform: &t)
            ringTrack.path = path
            ring.path = path
            plainLeft.place(x: Self.ringSize + 7, midY: bmid, width: lw)
            plainRight.isHidden = !plainRightShown
            plainRight.place(x: Self.ringSize + 7 + lw + 6, midY: bmid, width: rw)
        case .text:
            plainLeft.place(x: 0, midY: bmid, width: lw)
            plainRight.isHidden = !plainRightShown
            plainRight.place(x: lw + 6, midY: bmid, width: rw)
        }
    }

    private func layoutSegments() {
        guard meterStyle == .segmented else { bars.mask = nil; return }
        let size = bars.bounds.size
        let gap: CGFloat = 2.5
        let count = max(Int((size.width + gap) / 11), 5)
        let cell = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        segments.frame = bars.bounds
        segments.sublayers?.forEach { $0.removeFromSuperlayer() }
        for i in 0..<count {
            let c = CALayer.plain()
            c.backgroundColor = NSColor.black.cgColor
            c.frame = CGRect(x: CGFloat(i) * (cell + gap), y: 0, width: cell, height: size.height)
            c.cornerRadius = 1.5
            segments.addSublayer(c)
        }
        bars.mask = segments
    }

    func update(fraction: Double, ghost: Double?, left: String, right: String?, animated: Bool) {
        let changed = abs(fraction - self.fraction) > 0.0005 || abs((ghost ?? 0) - ghostFraction) > 0.0005
        self.fraction = min(max(fraction, 0), 1)
        self.ghostFraction = min(max(ghost ?? 0, 0), 1)
        let newTint = Theme.usageTint(fraction, warn: warn)
        let tintChanged = newTint != tint
        self.tint = newTint
        let textChanged = left != self.left || right != self.right
        self.left = left
        self.right = right
        if textChanged || tintChanged {
            let warned = newTint != Theme.usageTint(0, warn: warn)
            CALayer.still {
                leftLight.text = NSAttributedString(left, font: Theme.meter, color: Theme.primary)
                leftDark.text = NSAttributedString(left, font: Theme.meter, color: NSColor(white: 0, alpha: 0.86))
                rightLight.text = right.map { NSAttributedString($0, font: Theme.meterSmall, color: Theme.secondary) }
                rightDark.text = right.map { NSAttributedString($0, font: Theme.meterSmall, color: NSColor(white: 0, alpha: 0.55)) }
                plainLeft.text = NSAttributedString(left, font: Theme.meter, color: warned && meterStyle != .slim ? newTint : Theme.primary)
                plainRight.text = right.map { NSAttributedString($0, font: Theme.meterSmall, color: Theme.secondary) }
                layoutLabels()
            }
        }
        CALayer.animate(animated && changed ? Theme.slow : 0, Theme.easeOut) { layoutMeter() }
    }

    func setPressed(_ on: Bool) {
        guard on != pressed else { return }
        pressed = on
        CALayer.animate(on ? 0.08 : Theme.normal) {
            track.backgroundColor = (on ? Theme.keyPressed : Theme.key).cgColor
        }
    }
}

final class ProjectLayer: CALayer {
    let background = CALayer.plain()
    let content = CALayer.plain()
    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let nameText = TextLayer()
    private let branchIcon = CALayer.plain()
    private let secondLine = TextLayer()
    var showsBranch = true
    var lineMode = "both"
    var showsRing = true
    var maxWidth: CGFloat = 220
    private var model: BarModel?
    private var hasRing = false
    private static let branchImage = Glyphs.symbol("arrow.triangle.branch", pointSize: 8.5, weight: .semibold, color: Theme.secondary)
    private let pad: CGFloat = 10
    private let ringSize: CGFloat = 17

    override init() {
        super.init()
        contentsScale = Theme.scale
        background.backgroundColor = Theme.key.cgColor
        background.cornerRadius = UsageLayer.radius
        addSublayer(background)
        content.masksToBounds = true
        addSublayer(content)
        for r in [ringTrack, ring] {
            r.fillColor = nil
            r.lineWidth = 2.4
            r.lineCap = .round
            r.contentsScale = Theme.scale
            content.addSublayer(r)
        }
        ringTrack.strokeColor = NSColor(white: 1, alpha: 0.16).cgColor
        branchIcon.contents = Self.branchImage
        branchIcon.contentsGravity = .center
        for l in [nameText, branchIcon, secondLine] as [CALayer] { content.addSublayer(l) }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private var textWidth: CGFloat { max(nameText.text?.width ?? 0, (secondLine.text?.width ?? 0) + (branchVisible ? 12 : 0)) }
    private var branchVisible: Bool { showsBranch && (lineMode == "both" || lineMode == "branch") && model?.project?.branch != nil }
    private var twoLines: Bool { (secondLine.text?.length ?? 0) > 0 }

    var preferredWidth: CGFloat {
        guard model?.project != nil else { return 0 }
        return min(ceil(pad * 2 + (hasRing ? ringSize + 8 : 0) + textWidth), maxWidth)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still { layoutContent() }
    }

    private func layoutContent() {
        background.frame = bounds.insetBy(dx: 0, dy: 1)
        content.frame = bounds.insetBy(dx: pad, dy: 0)
        let h = content.bounds.height, mid = h / 2
        var x: CGFloat = 0
        ringTrack.isHidden = !hasRing
        ring.isHidden = !hasRing
        if hasRing {
            let rect = CGRect(x: 0, y: mid - ringSize / 2, width: ringSize, height: ringSize).insetBy(dx: 1.4, dy: 1.4)
            var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
            let path = CGPath(ellipseIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), transform: &t)
            ringTrack.path = path
            ring.path = path
            x = ringSize + 8
        }
        let avail = max(content.bounds.width - x, 0)
        if twoLines {
            nameText.place(x: x, midY: mid + 6.5, width: min(nameText.text?.width ?? 0, avail))
            var lx = x
            branchIcon.isHidden = !branchVisible
            if branchVisible {
                branchIcon.frame = CGRect(x: lx, y: mid - 12, width: 9, height: 11)
                lx += 12
            }
            secondLine.place(x: lx, midY: mid - 6.5, width: min(secondLine.text?.width ?? 0, max(avail - (lx - x), 0)))
        } else {
            branchIcon.isHidden = true
            nameText.place(x: x, midY: mid, width: min(nameText.text?.width ?? 0, avail))
        }
    }

    @discardableResult
    func update(_ m: BarModel, animated: Bool) -> Bool {
        let old = model
        let changed = old?.project != m.project || old?.linesAdded != m.linesAdded || old?.linesRemoved != m.linesRemoved
            || old?.contextPercent != m.contextPercent || old?.phase == .offline || m.phase == .offline
        model = m
        guard changed else { return false }
        let identityChanged = old?.project?.path != m.project?.path
        let dimmed = m.phase == .offline
        let apply = {
            self.nameText.text = NSAttributedString(m.project?.name ?? "", font: Theme.cardTitle, color: dimmed ? Theme.secondary : Theme.primary)
            self.secondLine.text = self.secondLineText(m)
            self.hasRing = self.showsRing && m.contextPercent != nil && !dimmed
            self.opacity = m.project == nil ? 0 : 1
        }
        CALayer.still { apply() }
        if let ctx = m.contextPercent {
            let f = min(max(ctx / 100, 0), 1)
            CALayer.animate(animated ? Theme.slow : 0) {
                ring.strokeEnd = CGFloat(f)
                ring.strokeColor = (f >= 0.85 ? Theme.amber : NSColor(white: 1, alpha: 0.85)).cgColor
            }
        }
        if animated && identityChanged && m.project != nil {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 10
            slide.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [slide, fade]
            group.duration = Theme.normal + 0.1
            group.timingFunction = Theme.easeOut
            content.add(group, forKey: "switch")
        }
        setNeedsLayout()
        return true
    }

    private func secondLineText(_ m: BarModel) -> NSAttributedString? {
        let s = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { s.append(NSAttributedString(t, font: Theme.cardLine, color: c)) }
        if branchVisible, let b = m.project?.branch { add(b, Theme.secondary) }
        guard lineMode == "both" || lineMode == "diff" else { return s.length > 0 ? s : nil }
        if let a = m.linesAdded, let r = m.linesRemoved, a + r > 0 {
            if s.length > 0 { add("  ", Theme.secondary) }
            add("+\(a)", Theme.diffAdd)
            add(" −\(r)", Theme.diffRemove)
        } else if let n = m.project?.changedFiles, n > 0 {
            if s.length > 0 { add("  ", Theme.secondary) }
            add("±\(n)", Theme.tertiary)
        }
        return s.length > 0 ? s : nil
    }

    func setPressed(_ on: Bool) {
        CALayer.animate(on ? 0.08 : Theme.normal) {
            background.backgroundColor = (on ? Theme.keyPressed : Theme.key).cgColor
        }
    }
}
