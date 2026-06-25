import Foundation

public enum IntentKind: String, Codable, Sendable {
    case orderComplete, helpRequest, leave, smalltalk, unknown
}

/// ⑥ LLM 구조화 출력으로 받는 의도. 스키마 밖/깨진 값은 .unknown으로 안전 강등.
public struct DialogueIntent: Codable, Equatable, Sendable {
    public let kind: IntentKind
    public let politeness: Int?
    public init(kind: IntentKind, politeness: Int? = nil) {
        self.kind = kind; self.politeness = politeness
    }

    private struct Raw: Codable { let kind: String; let politeness: Int? }

    public static func decode(fromJSON json: String) -> DialogueIntent {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return DialogueIntent(kind: .unknown)
        }
        let kind = IntentKind(rawValue: raw.kind) ?? .unknown
        return DialogueIntent(kind: kind, politeness: raw.politeness)
    }
}
