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

}

/// 접근성 태도와 별개로 점원의 말투와 반응 리듬을 결정하는 성격.
public enum ClerkPersonality: String, CaseIterable, Sendable {
    case hurried
    case chatty
    case cautious
    case blunt

    public static func random() -> Self {
        allCases.randomElement() ?? .hurried
    }

}

public struct NPCPersona: Sendable {
    public let id: String
    public let role: String
    public let englishSystemBase: String   // 영어 시스템 프롬프트(토큰 절감)
    public let accessibilityAttitude: AccessibilityAttitude
    public let clerkPersonality: ClerkPersonality

    public init(id: String, role: String, englishSystemBase: String,
                accessibilityAttitude: AccessibilityAttitude = .inclusive,
                clerkPersonality: ClerkPersonality = .hurried) {
        self.id = id
        self.role = role
        self.englishSystemBase = englishSystemBase
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = clerkPersonality
    }
}
