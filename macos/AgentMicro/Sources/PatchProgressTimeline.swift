import Foundation

enum PatchProgressTimeline {
    static func target(
        for operation: PatchOperation,
        stage: String,
        reported: Double?
    ) -> Double {
        let mapped: Double?
        switch (operation, stage) {
        case (_, "starting"):
            mapped = 0.06
        case (.patch, "preflight"):
            mapped = 0.11
        case (.patch, "backup"):
            mapped = 0.22
        case (.patch, "extracting"):
            mapped = 0.35
        case (.patch, "patching"):
            mapped = 0.47
        case (.patch, "packing"):
            mapped = 0.61
        case (.patch, "staging"):
            mapped = 0.80
        case (.restore, "validating-backup"):
            mapped = 0.34
        case (.restore, "validating-complete-backup"):
            mapped = 0.80
        case (.restore, "staging"):
            mapped = 0.58
        case (.restore, "signing"):
            mapped = 0.78
        case (_, "quitting"):
            mapped = 0.88
        case (.patch, "installing"), (.restore, "restoring"):
            mapped = 0.95
        case (_, "relaunching"):
            mapped = 0.99
        case (_, "complete"):
            mapped = 1
        default:
            mapped = nil
        }

        return min(1, max(mapped ?? 0, reported ?? 0))
    }

    static func nextFraction(current: Double, target: Double) -> Double {
        guard current < target else { return current }
        let distance = target - current
        let step = max(distance * 0.055, 0.00025)
        return min(target, current + step)
    }
}
