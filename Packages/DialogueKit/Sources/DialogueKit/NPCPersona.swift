import Foundation

public struct NPCPersona: Sendable {
    public let id: String
    public let role: String
    public let englishSystemBase: String   // 영어 시스템 프롬프트(토큰 절감)
    public init(id: String, role: String, englishSystemBase: String) {
        self.id = id; self.role = role; self.englishSystemBase = englishSystemBase
    }
}
