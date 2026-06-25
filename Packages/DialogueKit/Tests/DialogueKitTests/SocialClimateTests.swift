import XCTest
@testable import DialogueKit

final class SocialClimateTests: XCTestCase {
    func test_politeTurns_raiseRapport_andWarmTone() {
        var c = SocialClimate()
        c.apply(PlayerTurn(text: "안녕하세요, 부탁드려요", polite: true, impatient: false))
        c.apply(PlayerTurn(text: "감사합니다", polite: true, impatient: false))
        XCTAssertGreaterThan(c.rapport, 0.2)
        XCTAssertEqual(c.tone, .warm)
    }

    func test_rudeTurns_lowerRapport_andCurtTone() {
        var c = SocialClimate()
        c.apply(PlayerTurn(text: "야 빨리", polite: false, impatient: true))
        c.apply(PlayerTurn(text: "아 좀", polite: false, impatient: true))
        XCTAssertLessThan(c.rapport, -0.2)
        XCTAssertEqual(c.tone, .curt)
    }

    func test_rapport_isClampedTo_minusOne_one() {
        var c = SocialClimate()
        for _ in 0..<50 { c.apply(PlayerTurn(text: "x", polite: false, impatient: true)) }
        XCTAssertEqual(c.rapport, -1.0, accuracy: 0.0001)
    }

    func test_helpChance_growsWithPositiveRapport() {
        var c = SocialClimate()
        XCTAssertEqual(c.helpChance, 0.3, accuracy: 0.0001) // 중립
        c.rapport = 1.0
        XCTAssertEqual(c.helpChance, 0.8, accuracy: 0.0001)
    }
}
