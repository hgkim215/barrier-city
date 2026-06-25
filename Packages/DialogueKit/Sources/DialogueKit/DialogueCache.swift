import Foundation

/// ⑨ 시연 결정론·오프라인·폴백용 사전 작성 대사. audioKey는 사전 생성 음성 파일 키(앱 레이어에서 사용).
public enum Situation: String, Sendable { case greeting, timeout, blockedContent, orderConfirm, turnLimitReached }

public struct CannedLine: Equatable, Sendable {
    public let text: String
    public let audioKey: String
    public init(text: String, audioKey: String) { self.text = text; self.audioKey = audioKey }
}

public struct DialogueCache: Sendable {
    private let lines: [Situation: CannedLine]
    public init(lines: [Situation: CannedLine]) { self.lines = lines }
    public func line(for situation: Situation) -> CannedLine? { lines[situation] }
}
