import AppKit
import ClaudeBarCore

final class ActionLayer: CALayer {
    struct Key {
        var title: String
        var action: Action
        var style: Style
    }

    enum Style { case normal, primary, selected }

    enum Action: Equatable {
        case allow, always, deny
        case option(Int)
        case submit
        case more
    }

    private(set) var keys: [(frame: CGRect, key: Key, layer: CALayer)] = []
    static let gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    override init() {
        super.init()
        contentsScale = Theme.scale
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    static func width(of key: Key) -> CGFloat {
        max(NSAttributedString(key.title, font: font, color: .white).width + 26, 64)
    }

    @discardableResult
    func show(_ all: [Key], animated: Bool) -> CGFloat {
        var fitting: [Key] = []
        var used: CGFloat = 0
        let more = Key(title: "More…", action: .more, style: .normal)
        for (i, k) in all.enumerated() {
            let w = Self.width(of: k) + (fitting.isEmpty ? 0 : Self.gap)
            let reserve = i < all.count - 1 ? Self.width(of: more) + Self.gap : 0
            if used + w + reserve > bounds.width && !fitting.isEmpty {
                fitting.append(more)
                used += Self.width(of: more) + Self.gap
                break
            }
            fitting.append(k)
            used += w
        }

        CALayer.still {
            sublayers?.forEach { $0.removeFromSuperlayer() }
            keys = []
            var x = bounds.width - used
            for (i, k) in fitting.enumerated() {
                let w = Self.width(of: k)
                let b = CALayer.plain()
                b.frame = CGRect(x: x, y: 1, width: w, height: bounds.height - 2)
                b.cornerRadius = UsageLayer.radius
                b.backgroundColor = color(k.style).cgColor
                let t = TextLayer()
                t.text = NSAttributedString(k.title, font: Self.font, color: .white)
                t.alignmentMode = .center
                t.place(x: 0, midY: b.bounds.midY, width: w)
                b.addSublayer(t)
                addSublayer(b)
                keys.append((b.frame, k, b))
                if k.style == .primary { breathe(b) }
                if animated {
                    let slide = CABasicAnimation(keyPath: "transform.translation.x")
                    slide.fromValue = 24
                    slide.toValue = 0
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    let g = CAAnimationGroup()
                    g.animations = [slide, fade]
                    g.duration = 0.34
                    g.beginTime = CACurrentMediaTime() + 0.04 * Double(i)
                    g.fillMode = .backwards
                    g.timingFunction = Theme.easeOut
                    b.add(g, forKey: "in")
                }
                x += w + Self.gap
            }
        }
        return used
    }

    private func color(_ style: Style) -> NSColor {
        switch style {
        case .normal: return Theme.key
        case .primary: return Theme.keyBlue
        case .selected: return Theme.keyBlue.withAlphaComponent(0.7)
        }
    }

    private func breathe(_ layer: CALayer) {
        layer.shadowColor = Theme.keyBlue.cgColor
        layer.shadowRadius = 5
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        let a = CABasicAnimation(keyPath: "shadowOpacity")
        a.fromValue = 0
        a.toValue = 0.9
        a.duration = 1.2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = Theme.easeInOut
        layer.add(a, forKey: "breathe")
    }

    func key(at point: CGPoint) -> Int? {
        keys.firstIndex { $0.frame.insetBy(dx: -Self.gap / 2, dy: -4).contains(point) }
    }

    func setPressed(_ index: Int, _ on: Bool) {
        guard index < keys.count else { return }
        let entry = keys[index]
        CALayer.animate(on ? 0.06 : Theme.normal) {
            entry.layer.backgroundColor = (on ? Theme.keyPressed : color(entry.key.style)).cgColor
            entry.layer.setAffineTransform(on ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity)
        }
    }
}
