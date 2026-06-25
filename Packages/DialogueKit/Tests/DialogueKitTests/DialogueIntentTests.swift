import XCTest
@testable import DialogueKit

final class DialogueIntentTests: XCTestCase {
    func test_decodes_validJSON() {
        let json = #"{"kind":"orderComplete","politeness":2}"#
        let intent = DialogueIntent.decode(fromJSON: json)
        XCTAssertEqual(intent, DialogueIntent(kind: .orderComplete, politeness: 2))
    }

    func test_unknownKindString_fallsBackTo_unknown() {
        let json = #"{"kind":"explode","politeness":0}"#
        XCTAssertEqual(DialogueIntent.decode(fromJSON: json).kind, .unknown)
    }

    func test_malformedJSON_fallsBackTo_unknown() {
        XCTAssertEqual(DialogueIntent.decode(fromJSON: "not json {").kind, .unknown)
    }

    func test_missingPoliteness_isNil_kindParsed() {
        let intent = DialogueIntent.decode(fromJSON: #"{"kind":"leave"}"#)
        XCTAssertEqual(intent.kind, .leave)
        XCTAssertNil(intent.politeness)
    }
}
