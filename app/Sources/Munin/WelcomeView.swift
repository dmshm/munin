import AppKit
import SwiftUI
import MuninCore

/// What the window shows with nothing open: every world Munin knows about, one
/// click each.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 88, height: 88)
                Text("Munin").font(.largeTitle.weight(.semibold))
                Text("Pick a world to see how its builds were put together.")
                    .foregroundStyle(.secondary)
            }

            if model.worlds.isEmpty {
                Text("No worlds found yet. Single-player saves show up here on their own, and server worlds once they are downloaded with tools/fetch_world.sh.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.worlds) { WorldRow(world: $0) }
                    }
                    .padding(2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: 520, maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Other…") { model.chooseFile() }
                Button("Example Tower") { model.openExample() }
            }
            Text("Or drop a world folder, a .db save or a build .json onto the window.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshWorlds() }
    }
}

/// One world in the list: a single click opens it.
struct WorldRow: View {
    @EnvironmentObject var model: AppModel
    let world: WorldEntry
    @State private var hovering = false

    var body: some View {
        Button { model.open(world.url) } label: {
            HStack(spacing: 12) {
                Image(systemName: world.symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.ember)
                    .frame(width: 36, height: 36)
                    .background(Theme.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(world.name).font(.headline)
                    Text(world.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(world.url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([world.url]) }
            if world.lastOpened != nil {
                Button("Remove from List") { model.forget(world) }
            }
        }
    }
}

extension WorldEntry {
    var symbol: String {
        if isBuildFile { return "doc.text" }
        switch source {
        case .server: return "server.rack"
        case .game: return "gamecontroller"
        case .other: return "globe.europe.africa"
        }
    }

    /// "Server copy · saved 2 hours ago"
    var origin: String {
        var parts = [isBuildFile ? "Saved build" : source.rawValue]
        if let modified { parts.append("saved " + modified.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    /// "Server copy · saved 2 hours ago · opened yesterday"
    var summary: String {
        guard let lastOpened else { return origin }
        return origin + " · opened " + lastOpened.formatted(.relative(presentation: .named))
    }
}
