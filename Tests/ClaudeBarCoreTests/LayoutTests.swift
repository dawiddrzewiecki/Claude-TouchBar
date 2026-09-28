import Testing
import Foundation
@testable import ClaudeBarCore

@Suite struct LayoutTests {
    @Test func roundTrip() {
        var layout = BarLayout.standard
        layout.update(layout.widgets[3].setting("style", to: "ring"))
        let decoded = BarLayout.decode(layout.encoded())
        #expect(decoded == layout)
        #expect(decoded?.widgets[3].value("style") == "ring")
    }

    @Test func unknownKindsAndDuplicatesAreDropped() throws {
        let json = #"{"widgets":[{"id":"a","kind":"session","options":{}},{"id":"b","kind":"hologram","options":{}},{"id":"c","kind":"session","options":{}},{"id":"d","kind":"space","options":{}},{"id":"e","kind":"space","options":{}}]}"#
        let layout = try #require(BarLayout.decode(Data(json.utf8)))
        #expect(layout.widgets.map(\.id) == ["a", "d", "e"])
    }

    @Test func optionDefaultsAndInvalidValues() {
        let usage = WidgetConfig(.usage, options: ["style": "plasma", "warn": "70"])
        #expect(usage.value("style") == "key")
        #expect(usage.value("warn") == "70")
        #expect(usage.value("label") == "auto")
        #expect(WidgetConfig(.clock).isOn("date") == false)
        #expect(WidgetConfig(.status).isOn("timer"))
    }

    @Test func insertKeepsUniqueKindsUnique() {
        var layout = BarLayout.standard
        #expect(!layout.canInsert(.usage))
        #expect(layout.canInsert(.divider))
        layout.insert(WidgetConfig(.usage), at: 0)
        #expect(layout.widgets.filter { $0.kind == .usage }.count == 1)
        let project = layout.widgets.last!
        layout.insert(project, at: 0)
        #expect(layout.widgets.first?.id == project.id)
        #expect(layout.widgets.count == BarLayout.standard.widgets.count)
        layout.insert(WidgetConfig(.divider), at: 99)
        #expect(layout.widgets.last?.kind == .divider)
    }

    @Test func presetsAreValid() {
        for preset in BarLayout.presets {
            var normalized = preset.layout
            normalized.normalize()
            #expect(normalized == preset.layout, "\(preset.name)")
            for w in preset.layout.widgets {
                for (key, value) in w.options {
                    #expect(w.kind.options.first { $0.key == key }?.choices.contains { $0.value == value } == true, "\(preset.name) \(w.kind) \(key)")
                }
            }
        }
    }
}
