import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshot") {
    let dir = arguments.count > i + 1 ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    Snapshot.renderAll(to: URL(fileURLWithPath: dir))
    exit(0)
}

if let i = arguments.firstIndex(of: "--snapshot-customizer") {
    let path = arguments.count > i + 1 ? arguments[i + 1] : "customizer.png"
    Snapshot.renderCustomizer(to: URL(fileURLWithPath: path))
    exit(0)
}

if let i = arguments.firstIndex(of: "--iconset"), arguments.count > i + 1 {
    Snapshot.renderIconSet(to: URL(fileURLWithPath: arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
