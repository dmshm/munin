import SwiftUI

/// The 3D view's controls in one compact bar: camera presets, the two visibility
/// toggles, time of day, and the navigation help. Sized to its content, so it never
/// squeezes its labels however narrow the window gets.
struct SceneControls: View {
    @EnvironmentObject var model: AppModel
    let scene: BuildScene
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ViewPreset.allCases) { preset in
                    Button(preset.title) { scene.frame(preset) }
                }
                Divider()
                Toggle("Full Resolution", isOn: $model.fullResolution)
                    .help("Render every pixel of a large window: sharper, but fewer frames per second")
            } label: {
                Label("View", systemImage: "camera")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Frame the area from a fixed direction")

            Divider().frame(height: 16)

            Toggle(isOn: $model.ghosts) { Label("Ghosts above the cut", systemImage: "square.3.layers.3d.down.right") }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help("Show the layers above the cut as ghosts")
            if scene.region != nil {
                Toggle(isOn: $model.surroundings) { Label("Surroundings", systemImage: "tree") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .help("Show the ground, water, trees and rocks")
            }

            Divider().frame(height: 16)

            Image(systemName: model.hour >= 6 && model.hour < 18 ? "sun.max" : "moon.stars")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: $model.hour, in: 0...24)
                .controlSize(.small)
                .frame(width: 110)
                .help("Time of day")
            Text(String(format: "%02d:%02d", Int(model.hour) % 24, Int((model.hour - model.hour.rounded(.down)) * 60)))
                .monospacedDigit().font(.caption)
                .frame(width: 36, alignment: .leading)

            Divider().frame(height: 16)

            Button { showHelp.toggle() } label: { Label("Navigation help", systemImage: "questionmark.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("How to move around")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) { NavigationHelp() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

/// The mouse, trackpad and keyboard controls, in a popover.
struct NavigationHelp: View {
    private let rows: [(String, String)] = [
        ("Move", "Drag, and let go to glide · arrows or W A S D"),
        ("Zoom", "Scroll or pinch, toward the cursor · + and −"),
        ("Zoom in on a spot", "Double-click"),
        ("Rotate and tilt", "⌃-drag, ⌥-drag or right-drag · ⇧-arrows"),
        ("North up", "Click the compass, bottom right"),
        ("Look straight down", "The 2D / 3D button, bottom right"),
        ("Layers", "[ and ], or the slider below"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).fontWeight(.medium)
                    Text(row.1).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(14)
    }
}

extension ViewPreset {
    var title: String {
        switch self {
        case .iso: return "Perspective"
        case .north: return "From the North"
        case .east: return "From the East"
        case .south: return "From the South"
        case .west: return "From the West"
        case .top: return "From Above"
        }
    }
}
