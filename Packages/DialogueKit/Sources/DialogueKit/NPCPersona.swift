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
    /// 한국어 실시간 음성 발화 프롬프트. 지시문 자체를 한국어로 줘야 발음·억양이
    /// 자연스럽다(영어 지시문 위에서 한국어를 말하게 하면 어색해진다).
    public let systemBase: String
    public let accessibilityAttitude: AccessibilityAttitude
    public let clerkPersonality: ClerkPersonality

    public init(id: String, role: String, systemBase: String,
                accessibilityAttitude: AccessibilityAttitude = .inclusive,
                clerkPersonality: ClerkPersonality = .hurried) {
        self.id = id
        self.role = role
        self.systemBase = systemBase
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = clerkPersonality
    }
}
