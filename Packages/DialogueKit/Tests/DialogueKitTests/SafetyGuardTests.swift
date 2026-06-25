import XCTest
@testable import DialogueKit

final class SafetyGuardTests: XCTestCase {
    private let guardian = SafetyGuard(bannedKeywords: ["욕설", "bomb"], maxTurns: 8)

    func test_cleanText_isAllowed() {
        XCTAssertEqual(guardian.screen("아메리카노 한 잔 주세요"), .allow)
    }
    func test_bannedKeyword_isBlocked_caseInsensitive() {
        if case .block = guardian.screen("BOMB 어쩌고") { } else { XCTFail("should block") }
        if case .block = guardian.screen("이건 욕설이야") { } else { XCTFail("should block") }
    }
    func test_turnCap_allowsBelowLimit_blocksAtOrAbove() {
        XCTAssertTrue(guardian.allowTurn(count: 7))
        XCTAssertFalse(guardian.allowTurn(count: 8))
        XCTAssertFalse(guardian.allowTurn(count: 9))
    }
}
