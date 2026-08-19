import XCTest
@testable import DialogueKit

final class ConversationMemoryTests: XCTestCase {
    func test_finalizedTurns_areKeptInOrderAndInjectedIntoPrompt() {
        var memory = ConversationMemory()
        memory.append(.user, text: "오늘 원두가 다 떨어졌어요?")
        memory.append(.assistant, text: "네, 아침에 다 써 버렸어요.")

        XCTAssertEqual(memory.turns.count, 2)
        XCTAssertTrue(memory.promptContext.contains("Visitor: 오늘 원두가 다 떨어졌어요?"))
        XCTAssertTrue(memory.promptContext.contains("Clerk: 네, 아침에 다 써 버렸어요."))
    }

    func test_duplicateFinalTranscript_isStoredOnce() {
        var memory = ConversationMemory()
        memory.append(.assistant, text: "잠시만요.")
        memory.append(.assistant, text: "잠시만요.")

        XCTAssertEqual(memory.turns.count, 1)
    }

    func test_reset_clearsImmersiveConversationContext() {
        var memory = ConversationMemory()
        memory.append(.user, text: "아까 얘기 기억해요?")

        memory.reset()

        XCTAssertTrue(memory.isEmpty)
        XCTAssertTrue(memory.promptContext.contains("no earlier conversation"))
    }

    func test_returningOpening_resumesMemoryWithoutRestartingServiceFlow() {
        var memory = ConversationMemory()
        memory.append(.user, text: "오늘 진짜 바빠 보이네요.")

        let opening = RealtimeConversationGuide.openingInstructions(
            memory: memory,
            isReturningEncounter: true
        )

        XCTAssertTrue(opening.contains("same visitor"))
        XCTAssertTrue(opening.contains("resume"))
        XCTAssertTrue(opening.contains("Do not restart a service script"))
    }
}
