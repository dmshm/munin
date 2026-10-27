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
            // `Munin --open <path>`: start with that; otherwise with what was open last time.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                model.open(URL(fileURLWithPath: args[i + 1]))
            } else {
                model.openLastWorld()
            }
        }
        .sheet(isPresented: $model.showSetup) { SetupSheet(setup: model.setup) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }

    // MARK: - sidebar

    private var sidebar: some View { Sidebar() }

    // MARK: - map and 3D

    @ViewBuilder private var detail: some View {
        Group {
            if model.mode == .map, let map = model.map {
                MapView(map: map, builds: model.visibleBuilds, radius: $model.regionRadius,
                        onPick: { model.openRegion(at: $0) },
                        onPickBuild: { model.select($0.id) })
            } else if let scene = model.scene {
                sceneView(scene)
            } else if !model.loading {
                WelcomeView()
            } else {
                // Something to hang the spinner on while the first area opens.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .help("The whole world as a map, or the open area in 3D")
            }
        }
    }

    private func sceneView(_ scene: BuildScene) -> some View {
        ZStack(alignment: .topLeading) {
            BuildView(scene: scene, fullResolution: model.fullResolution) { target, point in model.hover(target, at: point) }
                .id(ObjectIdentifier(scene))

            SceneControls(scene: scene).padding(10)

            if FrameCounter.enabled {
                FrameRateBadge()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }

            CameraControls(camera: scene.cameraState, scene: scene)
                .padding(.trailing, 12)
                .padding(.bottom, scene.build.pieces.isEmpty ? 12 : 78)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

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
                if !scene.build.pieces.isEmpty { layerBar(scene) }
            }
        }
    }

    private func layerBar(_ scene: BuildScene) -> some View {
        HStack {
            Button { model.level = max(0, model.level - 1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: [])
                .help("One layer down ( [ )")
            Slider(value: Binding(get: { Double(model.level) }, set: { model.level = Int($0.rounded()) }),
                   in: 0...Double(max(scene.levels.count - 1, 1)), step: 1)
            Button { model.level = min(scene.levels.count - 1, model.level + 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: [])
                .help("One layer up ( ] )")
            Text(model.layerLabel).monospacedDigit().frame(minWidth: 230, alignment: .leading)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
        .disabled(scene.levels.count < 2)
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
            .overlay(Text("Drop a shared map (.zip), a world or a build .json").font(.title3))
            .padding(12)
    }
}
