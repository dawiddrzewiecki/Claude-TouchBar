import Foundation
import ClaudeBarCore

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            "limitHours": 5.0,
            "demoMode": false,
            "autoPresent": true,
            "presentOnRequest": true,
            "hideWhenOffline": true,
            "answerKeys": true,
        ])
    }

    var limitHours: Double {
        get { max(d.double(forKey: "limitHours"), 0.25) }
        set { d.set(newValue, forKey: "limitHours") }
    }

    var limit: TimeInterval { limitHours * 3600 }

    var layout: BarLayout {
        get { BarLayout.decode(d.data(forKey: "barLayout")) ?? migratedLayout() }
        set { d.set(newValue.encoded(), forKey: "barLayout") }
    }

    private func migratedLayout() -> BarLayout {
        var layout = BarLayout.standard
        guard var usage = layout.widgets.first(where: { $0.kind == .usage }) else { return layout }
        if let label = d.string(forKey: "usageLabel") { usage = usage.setting("label", to: label) }
        if d.string(forKey: "usageBarStyle") == "segmented" { usage = usage.setting("style", to: "segmented") }
        layout.update(usage)
        return layout
    }

    var demoMode: Bool {
        get { d.bool(forKey: "demoMode") }
        set { d.set(newValue, forKey: "demoMode") }
    }

    var autoPresent: Bool {
        get { d.bool(forKey: "autoPresent") }
        set { d.set(newValue, forKey: "autoPresent") }
    }

    var presentOnRequest: Bool {
        get { d.bool(forKey: "presentOnRequest") }
        set { d.set(newValue, forKey: "presentOnRequest") }
    }

    var hideWhenOffline: Bool {
        get { d.bool(forKey: "hideWhenOffline") }
        set { d.set(newValue, forKey: "hideWhenOffline") }
    }

    var answerKeys: Bool {
        get { d.bool(forKey: "answerKeys") }
        set { d.set(newValue, forKey: "answerKeys") }
    }
}
