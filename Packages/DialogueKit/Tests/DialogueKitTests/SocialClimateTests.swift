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
        c.apply(PlayerTurn(text: "야 빨리", polite: false, impatient: true, hostile: true))
        c.apply(PlayerTurn(text: "바보야", polite: false, impatient: false, hostile: true))
        XCTAssertLessThan(c.rapport, -0.2)
        XCTAssertEqual(c.tone, .hostile)
    }

    func test_plainOrAssertiveTurn_isNotAutomaticallyPenalized() {
        var c = SocialClimate()
        c.apply(PlayerTurn(text: "이 문턱 때문에 못 들어가요", polite: false, impatient: false))
        XCTAssertEqual(c.rapport, 0, accuracy: 0.0001)
        XCTAssertEqual(c.tone, .neutral)
    }

    func test_rapport_isClampedTo_minusOne_one() {
        var c = SocialClimate()
        for _ in 0..<50 { c.apply(PlayerTurn(text: "x", polite: false, impatient: true)) }
        XCTAssertEqual(c.rapport, -1.0, accuracy: 0.0001)
    }

    func test_helpChance_growsWithPositiveRapport() {
        var c = SocialClimate()
        XCTAssertEqual(c.helpChance, 0.5, accuracy: 0.0001) // 중립
        c.rapport = 1.0
        XCTAssertEqual(c.helpChance, 0.9, accuracy: 0.0001)
    }

    func test_ableistInitialRapport_canReachSupportiveWithinTurnLimit() {
        var c = SocialClimate(rapport: AccessibilityAttitude.ableist.initialRapport)
        for _ in 0..<7 {
            c.apply(PlayerTurn(text: "감사합니다", polite: true, impatient: false))
        }
        XCTAssertEqual(c.tone, .supportive)
    }
}
