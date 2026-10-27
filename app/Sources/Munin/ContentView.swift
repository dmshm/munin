import SwiftUI
import UniformTypeIdentifiers
import MuninCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
        }
        .task {
            // `Munin --open <path>`: start with a world or build already loaded.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), args.count > i + 1, model.scene == nil {
                model.open(URL(fileURLWithPath: args[i + 1]))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Munin").font(.title2.weight(.semibold))
                            Text("How your Valheim builds were put together")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                    // With nothing open, the welcome screen offers the same.
                    if model.scene != nil || model.map != nil || model.loading || model.statusIsError {
                        HStack {
                            Button("Open…") { model.chooseFile() }
                                .keyboardShortcut("o")
                            Button("Example tower") {
                                if let url = Bundle.module.url(forResource: "watchtower", withExtension: "json") { model.open(url) }
                            }
                        }
                        if model.loading { ProgressView().controlSize(.small) }
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(model.statusIsError ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                    if let warning = model.catalogError {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            if model.builds.count > 1 {
                Section("Builds in this world") {
                    Toggle("Hide builds under 10 pieces", isOn: $model.hideSmall)
                        .font(.caption)
                    ForEach(model.visibleBuilds) { build in
                        HStack {
                            Text(build.name)
                            Spacer()
                            Text("\(Int(build.size.x))×\(Int(build.size.z))×\(Int(build.size.y)) m")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(build.id)
                    }
                }
            }

            if let scene = model.scene {
                Section {
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
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.build.name)
                        Text(String(format: "%d pieces · %.1f × %.1f m, %.1f m tall — click a row to highlight",
                                    scene.build.pieces.count, scene.build.size.x, scene.build.size.z, scene.build.size.y))
                            .textCase(nil).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar {
            if model.scene != nil {
                Button("Save build…", systemImage: "square.and.arrow.down") { model.exportSelected() }
            }
        }
    }

    // MARK: - map and 3D

    @ViewBuilder private var detail: some View {
        Group {
            if model.mode == .map, let map = model.map {
                MapView(map: map, builds: model.visibleBuilds, radius: $model.regionRadius,
                        onPick: { model.openRegion(at: $0) },
                        onPickBuild: { model.select($0.id) })
            } else if let scene = model.scene {
                sceneView(scene)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Open a world")
                    } icon: {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    }
                } description: {
                    Text("Open your world save (⌘O), drop it here, or try the example tower.")
                } actions: {
                    Button("Open…") { model.chooseFile() }.buttonStyle(.borderedProminent)
                    Button("Example tower") {
                        if let url = Bundle.module.url(forResource: "watchtower", withExtension: "json") { model.open(url) }
                    }
                }
            }
        }
        .overlay { if dropTargeted { dropHint } }
        .overlay { if model.loading { ProgressView().controlSize(.large) } }
        .toolbar {
            if model.map != nil {
                Picker("View", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func sceneView(_ scene: BuildScene) -> some View {
        ZStack(alignment: .topLeading) {
            BuildView(scene: scene) { target, point in model.hover(target, at: point) }
                .id(ObjectIdentifier(scene))

            HStack(spacing: 6) {
                ForEach(ViewPreset.allCases) { preset in
                    Button(preset.rawValue) { scene.frame(preset) }
                }
                Toggle("Ghost above cut", isOn: $model.ghosts).toggleStyle(.button)
                if scene.region != nil {
                    Toggle("Surroundings", isOn: $model.surroundings).toggleStyle(.button)
                }
                Divider().frame(height: 18)
                Image(systemName: model.hour >= 6 && model.hour < 18 ? "sun.max" : "moon.stars")
                    .help("Time of day")
                Slider(value: $model.hour, in: 0...24).frame(width: 140)
                Text(String(format: "%02d:%02d", Int(model.hour) % 24, Int((model.hour - model.hour.rounded(.down)) * 60)))
                    .monospacedDigit().font(.caption)
                Spacer()
                Text("Drag to move · right-drag to rotate · scroll to zoom · double-click to focus · WASD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)

            if let hovered = model.hovered {
                tooltip(hovered.piece, isProp: hovered.isProp)
                    .offset(x: hovered.at.x + 16, y: hovered.at.y + 16)
                    .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                if let ground = scene.region?.ground, !ground.isExact {
                    Text("Ground is estimated from where trees and rocks stand — the save does not store terrain.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                }
                layerBar(scene)
            }
        }
    }

    private func layerBar(_ scene: BuildScene) -> some View {
        HStack {
            Button { model.level = max(0, model.level - 1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: [])
            Slider(value: Binding(get: { Double(model.level) }, set: { model.level = Int($0.rounded()) }),
                   in: 0...Double(max(scene.levels.count - 1, 1)), step: 1)
            Button { model.level = min(scene.levels.count - 1, model.level + 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: [])
            Text(model.layerLabel).monospacedDigit().frame(minWidth: 230, alignment: .leading)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
        .disabled(scene.levels.count < 2 || scene.build.pieces.isEmpty)
    }

    private func tooltip(_ piece: Piece, isProp: Bool) -> some View {
        let p = piece.position
        let yaw = ((Int(piece.rotation.y.rounded()) % 360) + 360) % 360
        let tilted = abs(piece.rotation.x) + abs(piece.rotation.z) > 0.5
        return VStack(alignment: .leading, spacing: 2) {
            Text(piece.label + (isProp ? "" : " · built")).bold()
            Text(String(format: "%.2f m %@, %.2f m %@, %.2f m up",
                        abs(p.x), p.x >= 0 ? "E" : "W", abs(p.z), p.z >= 0 ? "N" : "S", p.y))
            Text("facing \(yaw)°" + (tilted ? String(format: " (tilt %.0f°, %.0f°)", piece.rotation.x, piece.rotation.z) : ""))
        }
        .font(.caption.monospacedDigit())
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Theme.ember, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .background(Theme.ember.opacity(0.08))
            .overlay(Text("Drop a world (.db or chunked folder) or a build .json").font(.title3))
            .padding(12)
    }
}
