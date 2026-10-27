import Foundation
import QuartzCore

/// How long each loading step takes, printed to stderr with `MUNIN_TIMING=1`;
/// otherwise it only runs the work.
enum Timing {
    static let enabled = ProcessInfo.processInfo.environment["MUNIN_TIMING"] != nil

    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = CACurrentMediaTime()
        let result = try work()
        report(label, since: start)
        return result
    }

    static func report(_ label: String, since start: CFTimeInterval) {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        FileHandle.standardError.write(Data((label.padding(toLength: 30, withPad: " ", startingAt: 0) + String(format: "%8.0f ms\n", ms)).utf8))
    }
}
