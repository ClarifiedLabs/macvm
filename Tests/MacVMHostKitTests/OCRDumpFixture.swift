import CoreGraphics
import Foundation
@testable import MacVMHostKit

/// Parses the OCR dumps `SetupStepRunner.dumpScreenshot` writes next to failure
/// screenshots (`<label>.txt`) into a `SetupPolicy.Screen`, so real-guest
/// failures can be replayed as policy regression tests. Copy the artifact from
/// `<vm>.macvm/Setup/screenshots/` into `Tests/MacVMHostKitTests/Fixtures/`.
///
/// Format (one observation per line, sizes in framebuffer pixels):
///     confidence  x,y wxh  text (framebuffer 2560x1440)
///     0.98  1042,268 476x40  Transfer Your Data to This Mac
enum OCRDumpFixture {
    static func parse(_ dump: String) throws -> SetupPolicy.Screen {
        let lines = dump.components(separatedBy: .newlines)
        guard let header = lines.first else {
            throw FixtureError.malformed("empty dump")
        }
        guard let sizeMatch = try NSRegularExpression(pattern: "framebuffer (\\d+)x(\\d+)")
            .firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
            let widthRange = Range(sizeMatch.range(at: 1), in: header),
            let heightRange = Range(sizeMatch.range(at: 2), in: header),
            let width = Double(header[widthRange]),
            let height = Double(header[heightRange]) else {
            throw FixtureError.malformed("header has no framebuffer size: \(header)")
        }

        let line = try NSRegularExpression(pattern: "^(\\d+(?:\\.\\d+)?)  (\\d+),(\\d+) (\\d+)x(\\d+)  (.+)$")
        var observations: [TextObservation] = []
        for row in lines.dropFirst() where !row.isEmpty {
            let range = NSRange(row.startIndex..., in: row)
            guard let match = line.firstMatch(in: row, range: range) else {
                throw FixtureError.malformed("unparseable observation line: \(row)")
            }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: row).map { String(row[$0]) } ?? ""
            }
            observations.append(TextObservation(
                string: group(6),
                rectInPixels: CGRect(
                    x: Double(group(2)) ?? 0,
                    y: Double(group(3)) ?? 0,
                    width: Double(group(4)) ?? 0,
                    height: Double(group(5)) ?? 0
                ),
                confidence: Float(group(1)) ?? 0
            ))
        }
        return SetupPolicy.Screen(observations: observations, size: CGSize(width: width, height: height))
    }

    /// Loads `Fixtures/<name>.txt` relative to the calling test file.
    static func load(_ name: String, file: StaticString = #filePath) throws -> SetupPolicy.Screen {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).txt")
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    enum FixtureError: Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case .malformed(let details): return "malformed OCR dump fixture: \(details)"
            }
        }
    }
}

/// Drives the pure policy over a scripted sequence of screens, computing "did
/// the action advance" with the real `SetupPolicy.didAdvance` — the same
/// feedback loop the runner provides, with no VM and no I/O. Each act or wait
/// consumes the next scripted screen; the last screen repeats once the script
/// is exhausted.
func runPolicy(
    target: String,
    screens: [SetupPolicy.Screen],
    maxSteps: Int = 24
) -> [SetupPolicy.Decision] {
    precondition(!screens.isEmpty)
    var state = SetupPolicy.PolicyState()
    var decisions: [SetupPolicy.Decision] = []
    var index = 0

    for _ in 0..<maxSteps {
        let current = screens[index]
        let (decision, nextState) = SetupPolicy.decide(target: target, screen: current, state: state)
        state = nextState
        decisions.append(decision)

        switch decision {
        case .reachedTarget, .stuck:
            return decisions
        case .wait:
            index = min(index + 1, screens.count - 1)
        case .act(_, let ladderKey, _):
            index = min(index + 1, screens.count - 1)
            state.lastActionAdvanced = SetupPolicy.didAdvance(
                from: current,
                to: screens[index],
                anchor: SetupPolicy.anchor(forLadderKey: ladderKey)
            )
        }
    }
    return decisions
}
