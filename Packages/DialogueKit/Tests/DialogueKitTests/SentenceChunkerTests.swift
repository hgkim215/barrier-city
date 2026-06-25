import XCTest
@testable import DialogueKit

final class SentenceChunkerTests: XCTestCase {
    func test_emitsSentence_whenTerminatorArrives() {
        var ch = SentenceChunker()
        XCTAssertEqual(ch.feed("어서"), [])
        XCTAssertEqual(ch.feed(" 오세요"), [])
        XCTAssertEqual(ch.feed("."), ["어서 오세요."])
    }

    func test_multipleSentences_inOneToken() {
        var ch = SentenceChunker()
        XCTAssertEqual(ch.feed("네. 알겠습니다! 또"), ["네.", " 알겠습니다!"])
        XCTAssertEqual(ch.flush(), " 또")
    }

    func test_flush_returnsNil_whenEmpty() {
        var ch = SentenceChunker()
        _ = ch.feed("끝.")
        XCTAssertNil(ch.flush())
    }
}
