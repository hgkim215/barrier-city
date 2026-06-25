import XCTest
@testable import DialogueKit

final class SmokeTests: XCTestCase {
    func test_message_holdsRoleAndContent() {
        let m = Message(role: .user, content: "안녕하세요")
        XCTAssertEqual(m.role, .user)
        XCTAssertEqual(m.content, "안녕하세요")
    }
}
