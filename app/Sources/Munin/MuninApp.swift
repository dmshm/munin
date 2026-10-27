import AppKit
import SwiftUI

@main
struct MuninApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    init() {
        Snapshot.runIfRequested()
        Showcase.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Munin") {
            ContentView()
                .environmentObject(model)
                .tint(Theme.ember)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.chooseFile() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.worlds.filter { $0.lastOpened != nil }) { world in
                        Button(world.name) { model.open(world.url) }
                    }
                }
                Divider()
                Button("Export Map…") { model.exportMap() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportMap)
            }
            CommandGroup(after: .appInfo) {
                Button("Set Up Game Assets…") { model.showSetup = true }
            }
        }
    }
}

/// Files that ship with the app. bundle.sh puts them in the app's Resources; SwiftPM's
/// own resource bundle is only a fallback for `swift run`, because its accessor looks
/// for it at the app's top level and then in this machine's build folder.
enum Resource {
    static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
}

/// The app's colours, taken from its icon: a rune glowing like an ember on a night sky.
enum Theme {
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.24)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run` there is no bundle to say this is a GUI app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
