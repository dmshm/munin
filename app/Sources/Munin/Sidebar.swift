import SwiftUI
import MuninCore

/// The left column: the open world as a card on top, then its builds and the pieces
/// of the open area, each a section that folds away.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var buildsExpanded = true
    @State private var piecesExpanded = true

    var body: some View {
        List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
            if model.builds.count > 1 {
                Section(isExpanded: $buildsExpanded) {
                    ForEach(model.visibleBuilds) { BuildRow(build: $0).tag($0.id) }
                    if model.smallBuildCount > 0 {
                        Button(model.hideSmall ? "Show \(model.smallBuildCount) smaller builds" : "Hide builds under 10 pieces") {
                            model.hideSmall.toggle()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ember)
                        .font(.caption)
                    }
                } header: {
                    SectionTitle(title: "Builds", count: model.builds.count)
                }
            }

            if let scene = model.scene, !scene.build.pieces.isEmpty {
                Section(isExpanded: $piecesExpanded) {
                    ForEach(scene.build.counts, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .foregroundStyle(row.label.hasPrefix("#") ? .pink : .primary)
                            Spacer()
                            Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.focus = model.focus == row.label ? nil : row.label }
                        .listRowBackground(model.focus == row.label ? Theme.ember.opacity(0.25) : nil)
                        .help("Click to highlight every \(row.label); click again to clear")
                    }
                } header: {
                    SectionTitle(title: "Pieces here", count: scene.build.pieces.count)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            WorldCard()
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .toolbar {
            if let scene = model.scene, !scene.build.pieces.isEmpty {
                Button("Save build…", systemImage: "square.and.arrow.down") { model.exportSelected() }
                    .help("Save these pieces as a build file that opens without the world")
            }
        }
    }
}

/// What is open, as a card: the world (a menu to switch to any other), its numbers,
/// and whether the ground is the game's own.
struct WorldCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switcher

            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the save…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let info = model.info {
                HStack(spacing: 0) {
                    Stat(value: info.pieces.formatted(), label: "pieces")
                    Divider().frame(height: 26)
                    Stat(value: info.builds.formatted(), label: info.builds == 1 ? "build" : "builds")
                    if let objects = info.objects {
                        Divider().frame(height: 26)
                        Stat(value: objects.formatted(.number.notation(.compactName)), label: "objects")
                            .help("\(objects.formatted()) objects in the save: trees, rocks, creatures, items…")
                    }
                }
                if let terrain = info.terrain { terrainLine(terrain) }
                ForEach(info.warnings, id: \.self) { note($0, symbol: "exclamationmark.triangle", color: .orange) }
            }

            if !model.status.isEmpty, !model.loading {
                note(model.status, symbol: model.statusIsError ? "xmark.octagon" : "info.circle",
                     color: model.statusIsError ? .red : .secondary)
            }
            if let warning = model.catalogError {
                note(warning, symbol: "exclamationmark.triangle", color: .orange)
                Button("Set Up Game Assets…") { model.showSetup = true }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }

    /// The world's name and where it comes from; a click lists every other world.
    private var switcher: some View {
        Menu {
            ForEach(model.worlds) { world in
                Button { model.open(world.url) } label: {
                    if world.id == model.current?.id { Label(world.name, systemImage: "checkmark") } else { Text(world.name) }
                }
            }
            Divider()
            Button("Open Other…") { model.chooseFile() }
            Button("Example Tower") { model.openExample() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: model.current?.symbol ?? "globe.europe.africa")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ember)
                    .frame(width: 32, height: 32)
                    .background(Theme.ember.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.opening ?? model.info?.name ?? "No world open")
                        .font(.headline)
                        .lineLimit(1).truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            // One button for VoiceOver, not an icon, two lines and a chevron.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("World: \(model.opening ?? model.info?.name ?? "none open"), \(subtitle)")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch to another world")
    }

    private var subtitle: String {
        if model.opening != nil { return "Opening…" }
        if let current = model.current { return current.origin }
        return model.info == nil ? "Pick one to open" : "Saved build"
    }

    private func terrainLine(_ terrain: WorldInfo.TerrainState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: terrain.isExact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(terrain.isExact ? Theme.ember : .orange)
            Text(terrain.isExact ? "Exact terrain" : "Estimated ground")
            if terrain.isExact, terrain.edited > 0 {
                Text("· \(terrain.edited) zones reshaped").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(terrain.isExact
              ? "The game's own terrain, from munin_export, with your levelling, digging and paths from the save."
              : "The save holds no terrain. Run munin_export in game for the real ground; until then it is estimated from where trees and rocks stand.")
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1...5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// One of the card's three figures.
private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A section header with its count on the right.
private struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted()).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
}

/// A build in the sidebar: how big it is and where it stands.
struct BuildRow: View {
    let build: Build

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Theme.ember.opacity(0.85))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(build.pieces.count.formatted()) pieces")
                    .foregroundStyle(.primary)
                Text(String(format: "%.0f × %.0f × %.0f m · at %d, %d", build.size.x, build.size.z, build.size.y,
                            Int(build.origin.x.rounded()), Int(build.origin.z.rounded())))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
