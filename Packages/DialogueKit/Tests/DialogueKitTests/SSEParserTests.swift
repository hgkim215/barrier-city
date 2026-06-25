import XCTest
@testable import DialogueKit

final class SSEParserTests: XCTestCase {
    func test_parsesContentToken() {
        let line = #"data: {"choices":[{"delta":{"content":"어서"}}]}"#
        XCTAssertEqual(parseSSELine(line), .token("어서"))
    }
    func test_parsesIntentFragment_fromToolCallArguments() {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"kind\":\"or"}}]}}]}"#
        XCTAssertEqual(parseSSELine(line), .intentFragment(#"{"kind":"or"#))
    }
    func test_parsesDone() {
        XCTAssertEqual(parseSSELine("data: [DONE]"), .done)
    }
    func test_ignoresNonDataOrEmptyDelta() {
        XCTAssertNil(parseSSELine(": keep-alive"))
        XCTAssertNil(parseSSELine(#"data: {"choices":[{"delta":{}}]}"#))
    }
    func test_emptyDataPayload_returnsNil() {
        XCTAssertNil(parseSSELine("data: "))
    }

    // 누적 후 DialogueIntent 복원(파서+스키마 통합 검증)
    func test_intentFragments_assembleInto_decodableIntent() {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"kind\":\"orderComplete\","}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"politeness\":2}"}}]}}]}"#,
        ]
        var acc = ""
        for l in lines { if case .intentFragment(let f) = parseSSELine(l) { acc += f } }
        XCTAssertEqual(DialogueIntent.decode(fromJSON: acc),
                       DialogueIntent(kind: .orderComplete, politeness: 2))
    }
}
