import XCTest
@testable import AgentMicro

final class ChatGPTRepairPromptTests: XCTestCase {
    func testPromptContainsDetectedBuildAndCanonicalGuide() {
        let prompt = ChatGPTRepairPrompt.make(
            version: "26.999.12345",
            build: "9999",
            bundleIdentifier: "com.openai.codex",
            patchState: "incompatible-pristine",
            reason: "Expected one service bundle; found zero."
        )

        XCTAssertTrue(prompt.contains("26.999.12345"))
        XCTAssertTrue(prompt.contains("9999"))
        XCTAssertTrue(prompt.contains("com.openai.codex"))
        XCTAssertTrue(prompt.contains("Expected one service bundle; found zero."))
        XCTAssertTrue(prompt.contains(ChatGPTRepairPrompt.repositoryURL))
        XCTAssertTrue(prompt.contains(ChatGPTRepairPrompt.compatibilityGuideURL))
        XCTAssertTrue(prompt.contains("Do not modify or replace the user's installed ChatGPT app"))
        XCTAssertTrue(prompt.contains("leave the scanner fail-closed"))
    }

    func testPromptUsesExplicitFallbacksForMissingMetadata() {
        let prompt = ChatGPTRepairPrompt.make(
            version: "",
            build: "",
            bundleIdentifier: "",
            patchState: "incompatible-pristine",
            reason: ""
        )

        XCTAssertEqual(prompt.components(separatedBy: "unknown").count - 1, 3)
        XCTAssertTrue(prompt.contains("compatibility scanner rejected"))
    }
}
