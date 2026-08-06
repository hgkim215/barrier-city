import Foundation

/// 장애 접근성을 대하는 NPC의 고정 성향. 관계 점수와 달리 대화 중 바뀌지 않는다.
public enum AccessibilityAttitude: String, Sendable {
    case inclusive
    case ableist

    public var initialRapport: Float {
        switch self {
        case .inclusive: 0.35
        case .ableist: -0.45
        }
    }

    var promptRule: String {
        switch self {
        case .inclusive:
            "Always provide equal service. Acknowledge access barriers without pity, speak directly to the wheelchair user, and ask before helping. Even when annoyed, never become ableist."
        case .ableist:
            "You begin with ableist assumptions. Unless rapport has become warm, resist reasonable accessibility accommodations and treat equal access as a special favor that disrupts store procedure. Never use slurs, threats, or violence."
        }
    }
}

public struct NPCPersona: Sendable {
    public let id: String
    public let role: String
    public let englishSystemBase: String   // 영어 시스템 프롬프트(토큰 절감)
    public let accessibilityAttitude: AccessibilityAttitude

    public init(id: String, role: String, englishSystemBase: String,
                accessibilityAttitude: AccessibilityAttitude = .inclusive) {
        self.id = id
        self.role = role
        self.englishSystemBase = englishSystemBase
        self.accessibilityAttitude = accessibilityAttitude
    }
}
