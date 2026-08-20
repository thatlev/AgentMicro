import Foundation

/// Builds the self-contained request copied from AgentMicro when a future
/// ChatGPT bundle no longer matches the fail-closed patch rules.
struct ChatGPTRepairPrompt {
    static let repositoryURL = "https://github.com/thatlev/AgentMicro"
    static let compatibilityGuideURL = repositoryURL
        + "/blob/main/docs/CHATGPT-COMPATIBILITY.md"

    static func make(
        version: String,
        build: String,
        bundleIdentifier: String,
        patchState: String,
        reason: String
    ) -> String {
        let safeVersion = version.isEmpty ? "unknown" : version
        let safeBuild = build.isEmpty ? "unknown" : build
        let safeBundleIdentifier = bundleIdentifier.isEmpty
            ? "unknown"
            : bundleIdentifier
        let safeReason = reason.isEmpty
            ? "AgentMicro's compatibility scanner rejected the installed bundle."
            : reason

        return """
        Repair AgentMicro compatibility for this unsupported ChatGPT desktop build.

        Detected installation
        - ChatGPT version: \(safeVersion)
        - ChatGPT build: \(safeBuild)
        - Bundle identifier: \(safeBundleIdentifier)
        - AgentMicro patch state: \(patchState)
        - Scanner reason: \(safeReason)

        Repository: \(repositoryURL)
        Required compatibility and release guide: \(compatibilityGuideURL)

        Read the complete compatibility guide and every GitHub source/document it links before changing code. Work in the AgentMicro repository. Inspect the exact installed ChatGPT app or the matching official release in a staging directory. Update the fail-closed scanner and patch implementation only as narrowly as this build requires, add regression fixtures for both pristine and patched states, and keep all signature, integrity, backup, normal-quit, rollback, and exact-match safeguards intact.

        Run every test and release gate in the guide, including the Node scanner tests, wire-contract tests, a clean macOS Release build, staged pristine-to-patched inspection, restore verification, code-signature verification, and a launch smoke test. Do not modify or replace the user's installed ChatGPT app while investigating. Do not claim support, update the tested-build documentation, merge, tag, or release unless all required checks pass. If a safe compatible patch cannot be established, leave the scanner fail-closed and explain the blocker precisely.
        """
    }
}
