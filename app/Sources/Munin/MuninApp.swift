import AppKit
import SwiftUI

@main
struct MuninApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    init() {
        Snapshot.runIfRequested()
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
            }
        }
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
