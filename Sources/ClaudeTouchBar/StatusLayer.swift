import AppKit
import ClaudeBarCore

final class StatusLayer: CALayer {
    struct Content: Equatable {
        var phase: Phase
        var title: String
        var detail: String?
    }

    let glyph = StateGlyphLayer()
    private let clip = CALayer.plain()
    private var group: CALayer?
    private let elapsed = TextLayer()
    private var shown: Content?
    private var pending: Content?
    private var lastSwap: CFTimeInterval = 0
    private var pendingWork: DispatchWorkItem?
    static let minimumDwell: CFTimeInterval = 0.06
    private var glyphShown = true
    var showsDetail = true
    var showsElapsed = true
    var shimmer = true

    override init() {
        super.init()
        contentsScale = Theme.scale
        addSublayer(glyph)
        clip.masksToBounds = true
        addSublayer(clip)
        elapsed.alignmentMode = .right
        addSublayer(elapsed)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private static let elapsedSlot = NSAttributedString("00m 00s", font: Theme.digitsSmall, color: .white).width
    private var elapsedWidth: CGFloat { (elapsed.text?.length ?? 0) > 0 ? Self.elapsedSlot + 10 : 0 }

    override func layoutSublayers() {
        super.layoutSublayers()
        CALayer.still {
            let mid = bounds.midY
            glyph.position = CGPoint(x: 8, y: mid)
            layoutClip()
            let ew = elapsed.text?.width ?? 0
            elapsed.place(x: bounds.width - ew, midY: mid, width: ew)
        }
    }

    private func layoutClip() {
        let textX: CGFloat = glyphShown ? 25 : 0
        clip.frame = CGRect(x: textX, y: 0, width: max(bounds.width - textX - elapsedWidth, 0), height: bounds.height)
        if let group, let shown { relayout(group, for: shown) }
    }

    func replace(_ content: Content) {
        glyph.show(content.phase, animated: false)
        glyphShown = content.phase != .working
        CALayer.still {
            glyph.opacity = glyphShown ? 1 : 0
            layoutClip()
        }
        swap(to: content, animated: false)
    }

    func update(_ content: Content, animated: Bool) {
        glyph.show(content.phase, animated: animated)
        let wantsGlyph = content.phase != .working
        if wantsGlyph != glyphShown {
            glyphShown = wantsGlyph
            CALayer.animate(animated ? Theme.normal : 0) {
                glyph.opacity = wantsGlyph ? 1 : 0
                layoutClip()
            }
        }
        guard content != shown else { pending = nil; return }
        guard animated, shown != nil else { swap(to: content, animated: false); return }

        let wait = lastSwap + Self.minimumDwell - CACurrentMediaTime()
        if wait <= 0 || content.phase != shown?.phase {
            swap(to: content, animated: true)
        } else {
            pending = content
            if pendingWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingWork = nil
                    if let next = self.pending { self.pending = nil; self.swap(to: next, animated: true) }
                }
                pendingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
        }
    }

    var naturalWidth: CGFloat {
        guard let shown else { return 0 }
        let title = NSAttributedString(shown.title + (shown.phase == .working ? "…" : ""), font: Theme.status, color: .white).width
        let detail = showsDetail ? shown.detail.map { 8 + NSAttributedString($0, font: Theme.statusDetail, color: .white).width } ?? 0 : 0
        return ceil((glyphShown ? 25 : 0) + title + detail + elapsedWidth + 4)
    }

    func setElapsed(_ text: String?) {
        let text = showsElapsed ? text : nil
        let new = text.map { NSAttributedString($0, font: Theme.digitsSmall, color: Theme.tertiary) }
        guard new?.string != elapsed.text?.string else { return }
        let visibilityChanged = (new == nil) != (elapsed.text == nil)
        CALayer.still {
            elapsed.text = new
            let ew = new?.width ?? 0
            elapsed.place(x: bounds.width - ew, midY: bounds.midY, width: ew)
        }
        if visibilityChanged { setNeedsLayout() }
    }

    private func swap(to content: Content, animated: Bool) {
        pendingWork?.cancel()
        pendingWork = nil
        pending = nil
        let old = group
        let sameTitle = shown?.title == content.title && shown?.phase == content.phase
        shown = content
        lastSwap = CACurrentMediaTime()

        let new = makeGroup(for: content)
        CALayer.still {
            clip.addSublayer(new)
            relayout(new, for: content)
        }
        group = new

        guard animated, let old else {
            old?.removeFromSuperlayer()
            return
        }

        if sameTitle {
            new.add(fade(from: 0, to: 1, duration: Theme.quick), forKey: "in")
            CALayer.still { old.opacity = 0 }
            old.add(fade(from: 1, to: 0, duration: Theme.quick), forKey: "out")
        } else {
            let distance: CGFloat = 9
            let inGroup = CAAnimationGroup()
            inGroup.animations = [fade(from: 0, to: 1, duration: 0.24), move(from: -distance, to: 0)]
            inGroup.duration = 0.24
            inGroup.beginTime = CACurrentMediaTime() + 0.03
            inGroup.fillMode = .backwards
            inGroup.timingFunction = Theme.easeOut
            new.add(inGroup, forKey: "in")

            CALayer.still { old.opacity = 0 }
            let outGroup = CAAnimationGroup()
            outGroup.animations = [fade(from: 1, to: 0, duration: 0.16), move(from: 0, to: distance)]
            outGroup.duration = 0.16
            outGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
            old.add(outGroup, forKey: "out")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak old] in old?.removeFromSuperlayer() }
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        return a
    }

    private func move(from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = from
        a.toValue = to
        return a
    }

    private func titleColor(_ phase: Phase) -> NSColor {
        switch phase {
        case .offline: return Theme.tertiary
        case .idle: return Theme.secondary
        case .working: return NSColor(white: 1, alpha: 0.76)
        default: return Theme.primary
        }
    }

    private func makeGroup(for content: Content) -> CALayer {
        let g = CALayer.plain()
        let title = TextLayer()
        title.name = "title"
        title.text = NSAttributedString(content.title + (content.phase == .working ? "…" : ""), font: Theme.status, color: titleColor(content.phase))
        g.addSublayer(title)
        if showsDetail, let detail = content.detail, !detail.isEmpty {
            let d = TextLayer()
            d.name = "detail"
            d.text = NSAttributedString(detail, font: Theme.statusDetail, color: Theme.secondary)
            g.addSublayer(d)
        }
        return g
    }

    private func relayout(_ g: CALayer, for content: Content) {
        let avail = clip.bounds.width
        let mid = clip.bounds.midY
        if g.frame == clip.bounds && g.value(forKey: "laidOut") as? Bool == true { return }
        g.setValue(true, forKey: "laidOut")
        g.frame = clip.bounds
        g.removeAnimation(forKey: "marquee")
        g.sublayers?.first(where: { $0.name == "shine" })?.removeFromSuperlayer()
        guard let title = g.sublayers?.first(where: { $0.name == "title" }) as? TextLayer else { return }
        let detail = g.sublayers?.first(where: { $0.name == "detail" }) as? TextLayer

        let tw = title.text?.width ?? 0
        title.place(x: 0, midY: mid, width: tw)
        var contentWidth = tw
        if let detail {
            let dw = detail.text?.width ?? 0
            let room = avail - tw - 8
            detail.isHidden = room < min(dw, 56)
            if !detail.isHidden {
                detail.place(x: tw + 8, midY: mid, width: min(dw, room))
                contentWidth = tw + 8 + min(dw, room)
            }
        }

        if shimmer && content.phase == .working && tw <= avail { addShine(to: g, over: title) }

        let overflow = tw - avail
        if overflow > 0 {
            title.frame.size.width = tw
            let speed: CGFloat = 28
            let travel = Double((overflow + 6) / speed)
            let pause = 1.6
            let total = pause + travel + pause + travel
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = [0, 0, -(overflow + 6), -(overflow + 6), 0]
            a.keyTimes = [0, pause / total, (pause + travel) / total, (pause + travel + pause) / total, 1].map { NSNumber(value: $0) }
            a.timingFunctions = [CAMediaTimingFunction(name: .linear), Theme.easeInOut, CAMediaTimingFunction(name: .linear), Theme.easeInOut]
            a.duration = total
            a.repeatCount = .infinity
            g.add(a, forKey: "marquee")
        }
        _ = contentWidth
    }

    private func addShine(to g: CALayer, over title: TextLayer) {
        let shine = TextLayer()
        shine.name = "shine"
        let text = NSMutableAttributedString(attributedString: title.text ?? NSAttributedString())
        text.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: text.length))
        shine.text = text
        shine.frame = title.frame

        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = NSColor(white: 1, alpha: 0).cgColor
        let lit = NSColor(white: 1, alpha: 0.9).cgColor
        mask.colors = [clear, lit, clear]
        mask.locations = [0, 0.5, 1]
        let band: CGFloat = 46
        mask.frame = CGRect(x: -band, y: 0, width: band, height: title.bounds.height)
        shine.mask = mask
        g.addSublayer(shine)

        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -band / 2
        sweep.toValue = title.bounds.width + band / 2
        sweep.duration = max(1.1, Double(title.bounds.width) / 110)
        let cycle = CAAnimationGroup()
        cycle.animations = [sweep]
        cycle.duration = sweep.duration + 4.5
        cycle.repeatCount = .infinity
        sweep.timingFunction = Theme.easeInOut
        mask.add(cycle, forKey: "sweep")
    }
}
