import AppKit
import SwiftUI

/// Runs `setup_assets.sh`, which ships inside the app, to extract the game's meshes
/// and textures from this Mac's copy of Valheim, and follows its output.
@MainActor
final class AssetSetup: ObservableObject {
    enum State: Equatable { case idle, running, failed(String), finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var log: [String] = []
    private var process: Process?
    private var partial = ""
    private var cancelled = false

    static let game = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/steamapps/common/Valheim/valheim.app/Contents/Resources/Data")

    var gameFound: Bool {
        FileManager.default.fileExists(atPath: Self.game.appendingPathComponent("StreamingAssets/SoftRef/Bundles").path)
    }

    /// In the app bundle; when run with `swift run`, from the repository's tools/.
    private static var script: URL {
        Bundle.main.url(forResource: "setup_assets", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../tools/setup_assets.sh").standardizedFileURL
    }

    /// The last thing the script said, for a one-line status.
    var lastLine: String { log.last ?? "" }

    func start(worlds: [URL], finished: @escaping @MainActor () -> Void) {
        guard state != .running else { return }
        log = []
        partial = ""
        cancelled = false
        state = .running
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path] + worlds.map(\.path)
        var environment = ProcessInfo.processInfo.environment
        // A GUI app starts with a bare PATH; the script finds Python on its own.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self.append(text) }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.append(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) + "\n")
                self.process = nil
                if status == 0 {
                    self.state = .finished
                    finished()
                } else if self.cancelled {
                    self.state = .failed("Stopped.")
                } else {
                    let error = self.log.last { $0.hasPrefix("✗") }.map { String($0.dropFirst(2)) }
                    self.state = .failed(error ?? "The setup stopped with an error; the log below says where.")
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true
        // The script's children (Python, pip) first, then the script.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }

    func reset() { if state != .running { state = .idle } }

    private func append(_ text: String) {
        let lines = (partial + text).components(separatedBy: .newlines)
        partial = lines.last ?? ""
        log += lines.dropLast().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

/// Munin › Set Up Game Assets…: what it does, then its progress.
struct SetupSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var setup: AssetSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title2).foregroundStyle(Theme.ember)
                    .frame(width: 40, height: 40)
                    .background(Theme.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Game Assets").font(.title3.weight(.semibold))
                    Text("Valheim's own meshes and textures, from your copy of the game")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            switch setup.state {
            case .idle: intro
            case .running, .failed, .finished: progress
            }

            HStack {
                if case .running = setup.state {
                    Spacer()
                    Button("Stop") { setup.cancel() }
                } else if case .idle = setup.state {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Start") { model.runSetup() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!setup.gameFound)
                } else {
                    Button("Show Log in Finder") { revealLog() }.opacity(setup.log.isEmpty ? 0 : 1)
                    Spacer()
                    if case .failed = setup.state { Button("Try Again") { model.runSetup() } }
                    Button("Close") { setup.reset(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(setup.state == .running)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Munin ships without any of the game's files. This reads them from Valheim on this Mac and keeps them in Munin's own folder. It downloads two Python libraries the first time, then takes a few minutes and about 6 GB of memory.")
                .fixedSize(horizontal: false, vertical: true)
            Label(setup.gameFound ? "Valheim found" : "Valheim isn't installed through Steam on this Mac",
                  systemImage: setup.gameFound ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(setup.gameFound ? .green : .red)
            let worlds = model.worldsForSetup
            if !worlds.isEmpty {
                Label("Trees, rocks and creatures from \(ListFormatter.localizedString(byJoining: worlds.map(\.lastPathComponent)))",
                      systemImage: "tree")
                    .foregroundStyle(.secondary)
            }
            Text("Run it again after a game update, or after adding a world.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch setup.state {
            case .running:
                ProgressView().progressViewStyle(.linear)
                Text(setup.lastLine).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .finished:
                Label("Done. Builds now draw with the game's own meshes.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                EmptyView()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(setup.log.enumerated()), id: \.offset) { index, line in
                            Text(line).id(index)
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 180)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: setup.log.count) { proxy.scrollTo($1 - 1, anchor: .bottom) }
            }
        }
    }

    private func revealLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Munin setup.log")
        try? setup.log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
