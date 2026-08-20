import XCTest
@testable import AgentMicro

final class PatchProgressTimelineTests: XCTestCase {
    func testPatchPreparationOwnsTheFirstEightyPercent() {
        let stages = [
            ("starting", 0.06),
            ("preflight", 0.11),
            ("backup", 0.22),
            ("extracting", 0.35),
            ("patching", 0.47),
            ("packing", 0.61),
            ("staging", 0.80),
            ("quitting", 0.88),
            ("installing", 0.95),
            ("relaunching", 0.99),
        ]

        for (stage, expected) in stages {
            XCTAssertEqual(
                PatchProgressTimeline.target(for: .patch, stage: stage, reported: nil),
                expected,
                accuracy: 0.0001
            )
        }
    }

    func testRestoreHasACompleteMonotonicTimeline() {
        let targets = [
            PatchProgressTimeline.target(for: .restore, stage: "starting", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "validating-backup", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "staging", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "signing", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "quitting", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "restoring", reported: nil),
            PatchProgressTimeline.target(for: .restore, stage: "relaunching", reported: nil),
        ]

        XCTAssertEqual(targets, targets.sorted())
        XCTAssertEqual(targets.last, 0.99)
    }

    func testCompleteBackupRestoreUsesThePreparationRange() {
        XCTAssertEqual(
            PatchProgressTimeline.target(
                for: .restore,
                stage: "validating-complete-backup",
                reported: nil
            ),
            0.80,
            accuracy: 0.0001
        )
    }

    func testInterpolationMovesForwardWithoutOvershooting() {
        var value = 0.0
        for _ in 0..<300 {
            let next = PatchProgressTimeline.nextFraction(current: value, target: 0.8)
            XCTAssertGreaterThanOrEqual(next, value)
            XCTAssertLessThanOrEqual(next, 0.8)
            value = next
        }
        XCTAssertGreaterThan(value, 0.79)
    }
}
