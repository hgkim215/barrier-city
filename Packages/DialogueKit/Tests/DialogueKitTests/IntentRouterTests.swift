import XCTest
@testable import DialogueKit

final class IntentRouterTests: XCTestCase {
    private let r = IntentRouter()

    func test_orderComplete_mapsTo_orderPlaced() {
        XCTAssertEqual(r.route(DialogueIntent(kind: .orderComplete)), .orderPlaced)
    }
    func test_helpRequest_mapsTo_helpRequested() {
        XCTAssertEqual(r.route(DialogueIntent(kind: .helpRequest)), .helpRequested)
    }
    func test_leave_mapsTo_exited() {
        XCTAssertEqual(r.route(DialogueIntent(kind: .leave)), .exited)
    }
    func test_smalltalk_and_unknown_mapTo_nil() {
        XCTAssertNil(r.route(DialogueIntent(kind: .smalltalk)))
        XCTAssertNil(r.route(DialogueIntent(kind: .unknown)))
    }
}
