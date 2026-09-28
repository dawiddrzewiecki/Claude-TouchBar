import AppKit
import ClaudeBarCore

enum Theme {
    static let height: CGFloat = 30
    static let scale: CGFloat = 2

    static let primary = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.56)
    static let tertiary = NSColor(white: 1, alpha: 0.34)
    static let topicInk = NSColor(white: 1, alpha: 0.64)
    static let quaternary = NSColor(white: 1, alpha: 0.18)
    static let hairline = NSColor(white: 1, alpha: 0.13)
    static let surface = NSColor(white: 1, alpha: 0.075)
    static let key = NSColor(white: 1, alpha: 0.2)
    static let keyPressed = NSColor(white: 1, alpha: 0.32)
    static let keyBlue = NSColor(srgbRed: 0.04, green: 0.46, blue: 0.96, alpha: 1)
    static let pressed = NSColor(white: 1, alpha: 0.17)

    static let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let claude = NSColor(srgbRed: 0.878, green: 0.357, blue: 0.251, alpha: 1)
    static let green = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
    static let amber = NSColor(srgbRed: 1.000, green: 0.702, blue: 0.251, alpha: 1)
    static let red = NSColor(srgbRed: 1.000, green: 0.420, blue: 0.380, alpha: 1)
    static let diffAdd = NSColor(srgbRed: 0.40, green: 0.82, blue: 0.50, alpha: 0.95)
    static let diffRemove = NSColor(srgbRed: 1.0, green: 0.50, blue: 0.47, alpha: 0.95)
    static let blue = NSColor(srgbRed: 0.392, green: 0.647, blue: 1.000, alpha: 1)

    static let status = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let statusDetail = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let topic = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let project = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let small = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    static let digitsSmall = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    static let meter = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    static let meterSmall = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    static let cardTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let cardLine = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let tag = NSFont.systemFont(ofSize: 8.5, weight: .bold)

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let easeInOut = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
    static let quick: CFTimeInterval = 0.18
    static let normal: CFTimeInterval = 0.32
    static let slow: CFTimeInterval = 0.6

    static func accent(for phase: Phase) -> NSColor {
        switch phase {
        case .working: return clay
        case .waiting: return blue
        case .attention: return amber
        case .completed: return green
        case .error: return red
        case .idle: return secondary
        case .offline: return tertiary
        }
    }

    static let meterNeutral = NSColor(white: 0.8, alpha: 1)

    static func usageTint(_ fraction: Double, warn: Double? = 0.8) -> NSColor {
        guard let warn else { return meterNeutral }
        if fraction >= max(0.95, warn) { return red }
        if fraction >= warn { return amber }
        return meterNeutral
    }
}

extension NSAttributedString {
    convenience init(_ string: String, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        self.init(string: string, attributes: attributes)
    }

    var width: CGFloat { ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(self), nil, nil, nil)) }
}

final class TextLayer: CATextLayer {
    override init() {
        super.init()
        contentsScale = Theme.scale
        truncationMode = .end
        isWrapped = false
        alignmentMode = .left
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    var text: NSAttributedString? {
        didSet { string = text }
    }

    private func fitted(to width: CGFloat) -> NSAttributedString? {
        guard let text, text.width > width else { return text }
        let ellipsis = NSAttributedString("…", font: (text.attribute(.font, at: max(text.length - 1, 0), effectiveRange: nil) as? NSFont) ?? Theme.status,
                                          color: (text.attribute(.foregroundColor, at: max(text.length - 1, 0), effectiveRange: nil) as? NSColor) ?? Theme.primary)
        var n = text.length
        while n > 0 {
            n -= 1
            let candidate = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: n)))
            while candidate.string.hasSuffix(" ") { candidate.deleteCharacters(in: NSRange(location: candidate.length - 1, length: 1)) }
            candidate.append(ellipsis)
            if candidate.width <= width { return n == 0 ? nil : candidate }
        }
        return nil
    }

    func place(x: CGFloat, midY: CGFloat, width: CGFloat? = nil) {
        guard let text, text.length > 0 else {
            string = nil
            frame = CGRect(x: x, y: midY, width: 0, height: 0)
            return
        }
        string = width.map { fitted(to: $0) } ?? text
        let font = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Theme.status
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let w = width ?? text.width
        let capCenter = -font.descender + font.capHeight / 2
        frame = CGRect(x: x, y: round((midY - capCenter) * 2) / 2, width: w, height: lineHeight)
    }
}

extension CALayer {
    static func plain() -> CALayer {
        let layer = CALayer()
        layer.contentsScale = Theme.scale
        return layer
    }

    static func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    static func animate(_ duration: CFTimeInterval, _ timing: CAMediaTimingFunction = Theme.easeOut, _ body: () -> Void, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock(completion)
        body()
        CATransaction.commit()
    }
}

enum Format {
    static func duration(_ t: TimeInterval, seconds: Bool = false) -> String {
        let total = Int(max(t, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return seconds && m < 10 ? "\(m)m \(s)s" : "\(m)m" }
        return seconds ? "\(s)s" : "0m"
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    static func hours(_ t: TimeInterval) -> String {
        let h = t / 3600
        return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
