import AppKit
import ClaudeBarCore

enum DetailKind: Equatable { case status, usage, project }

enum BarAction: Equatable {
    case openTerminal
    case openFinder
    case showDetail(DetailKind)
    case closeDetail
    case nextSession
    case previousSession
    case respond(RequestResponse)
}

final class DetailLayer: CALayer {
    enum Item {
        case glyph(Phase)
        case text(NSAttributedString)
        case pair(String, String, NSColor = Theme.primary)
        case bar(fill: Double, ghost: Double?, tint: NSColor)
        case button(String, symbol: String, action: BarAction)
        case separator
    }

    struct HitTarget {
        let frame: CGRect
        let action: BarAction
        let highlight: CALayer?
    }

    private(set) var targets: [HitTarget] = []
    private var items: [Item] = []

    override init() {
        super.init()
        contentsScale = Theme.scale
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [Item]) {
        self.items = items
        rebuild()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        rebuild()
    }

    private func rebuild() {
        CALayer.still {
            sublayers?.forEach { $0.removeFromSuperlayer() }
            targets = []
            let mid = bounds.midY
            let gap: CGFloat = 16

            let back = CALayer.plain()
            back.frame = CGRect(x: 0, y: 1, width: 36, height: bounds.height - 2)
            back.cornerRadius = UsageLayer.radius
            back.backgroundColor = Theme.key.cgColor
            let chevron = CAShapeLayer()
            chevron.path = Glyphs.chevronLeftPath(in: CGRect(x: 14, y: mid - 6, width: 8, height: 12))
            chevron.strokeColor = Theme.secondary.cgColor
            chevron.fillColor = nil
            chevron.lineWidth = 2
            chevron.lineCap = .round
            chevron.lineJoin = .round
            back.addSublayer(chevron)
            addSublayer(back)
            targets.append(HitTarget(frame: back.frame, action: .closeDetail, highlight: back))

            func fixedWidth(_ item: Item) -> CGFloat {
                switch item {
                case .glyph: return 16
                case .text(let t): return t.width
                case .pair(let v, let c, _): return pairStrings(v, c).0.width + 5 + pairStrings(v, c).1.width
                case .bar: return 0
                case .button(let title, _, _): return buttonTitle(title).width + 22 + 13
                case .separator: return 1
                }
            }
            let barCount = CGFloat(items.filter { if case .bar = $0 { return true }; return false }.count)
            let fixed = items.reduce(0) { $0 + fixedWidth($1) } + gap * CGFloat(items.count)
            let startX: CGFloat = 36 + gap
            let flexible = barCount > 0 ? max((bounds.width - startX - fixed) / barCount, 60) : 0

            var x = startX
            for item in items {
                switch item {
                case .glyph(let phase):
                    let g = StateGlyphLayer()
                    g.show(phase, animated: false)
                    g.position = CGPoint(x: x + 8, y: mid)
                    addSublayer(g)
                    x += 16
                case .text(let t):
                    let l = TextLayer()
                    l.text = t
                    l.place(x: x, midY: mid)
                    addSublayer(l)
                    x += t.width
                case .pair(let v, let c, let color):
                    let (value, caption) = pairStrings(v, c, color)
                    let a = TextLayer()
                    a.text = value
                    a.place(x: x, midY: mid)
                    addSublayer(a)
                    let b = TextLayer()
                    b.text = caption
                    b.place(x: x + value.width + 5, midY: mid)
                    addSublayer(b)
                    x += value.width + 5 + caption.width
                case .bar(let fill, let ghost, let tint):
                    let w = flexible
                    let track = CALayer.plain()
                    let t: CGFloat = 14
                    track.frame = CGRect(x: x, y: mid - t / 2, width: w, height: t)
                    track.cornerRadius = 4.5
                    track.masksToBounds = true
                    track.backgroundColor = Theme.quaternary.cgColor
                    addSublayer(track)
                    track.backgroundColor = Theme.key.cgColor
                    if let ghost {
                        let gl = CALayer.plain()
                        gl.frame = CGRect(x: 0, y: 0, width: w * min(max(ghost, 0), 1), height: t)
                        gl.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
                        track.addSublayer(gl)
                    }
                    let f = CALayer.plain()
                    f.frame = CGRect(x: 0, y: 0, width: w * min(max(fill, 0), 1), height: t)
                    f.backgroundColor = tint.cgColor
                    track.addSublayer(f)
                    x += w
                case .button(let title, let symbol, let action):
                    let t = buttonTitle(title)
                    let b = CALayer.plain()
                    b.frame = CGRect(x: x, y: 1, width: t.width + 22 + 13, height: bounds.height - 2)
                    b.cornerRadius = UsageLayer.radius
                    b.backgroundColor = Theme.key.cgColor
                    let icon = CALayer.plain()
                    icon.contents = Glyphs.symbol(symbol, pointSize: 11, weight: .semibold, color: Theme.secondary)
                    icon.contentsGravity = .center
                    icon.frame = CGRect(x: 9, y: 0, width: 14, height: b.bounds.height)
                    b.addSublayer(icon)
                    let l = TextLayer()
                    l.text = t
                    l.place(x: 26, midY: b.bounds.midY)
                    b.addSublayer(l)
                    addSublayer(b)
                    targets.append(HitTarget(frame: b.frame, action: action, highlight: b))
                    x += b.bounds.width
                case .separator:
                    let s = CALayer.plain()
                    s.frame = CGRect(x: x, y: mid - 7, width: 1, height: 14)
                    s.backgroundColor = Theme.hairline.cgColor
                    addSublayer(s)
                    x += 1
                }
                x += gap
            }
        }
    }

    private func pairStrings(_ v: String, _ c: String, _ color: NSColor = Theme.primary) -> (NSAttributedString, NSAttributedString) {
        (NSAttributedString(v, font: Theme.digits, color: color), NSAttributedString(c, font: Theme.small, color: Theme.tertiary))
    }

    private func buttonTitle(_ s: String) -> NSAttributedString {
        NSAttributedString(s, font: .systemFont(ofSize: 12, weight: .medium), color: Theme.primary)
    }

    func target(at point: CGPoint) -> HitTarget? {
        targets.first { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }
    }
}
