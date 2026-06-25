import XCTest
@testable import DialogueKit

final class DialogueCacheTests: XCTestCase {
    private let cache = DialogueCache(lines: [
        .greeting: CannedLine(text: "어서 오세요.", audioKey: "greeting_ko"),
        .timeout:  CannedLine(text: "잠시만요…", audioKey: "timeout_ko"),
    ])

    func test_returnsCachedLine_whenPresent() {
        XCTAssertEqual(cache.line(for: .greeting),
                       CannedLine(text: "어서 오세요.", audioKey: "greeting_ko"))
    }
    func test_returnsNil_whenAbsent() {
        XCTAssertNil(cache.line(for: .orderConfirm))
    }
}
