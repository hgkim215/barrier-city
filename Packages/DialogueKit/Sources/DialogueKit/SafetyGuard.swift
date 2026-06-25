import Foundation

/// ⑧ 1차 가드: 스트리밍 청크/입력 키워드 필터 + 턴 상한. (전체 Moderation은 앱 레이어에서 비차단 비동기로 별도 수행)
public enum Verdict: Equatable, Sendable { case allow; case block(reason: String) }

public struct SafetyGuard: Sendable {
    private let banned: [String]
    private let maxTurns: Int
    public init(bannedKeywords: [String], maxTurns: Int) {
        self.banned = bannedKeywords.map { $0.lowercased() }
        self.maxTurns = maxTurns
    }

    public func screen(_ text: String) -> Verdict {
        let lower = text.lowercased()
        for kw in banned where lower.contains(kw) {
            return .block(reason: "banned keyword: \(kw)")
        }
        return .allow
    }

    public func allowTurn(count: Int) -> Bool { count < maxTurns }
}
