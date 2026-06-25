import Foundation

/// ⑥ 의도를 게임 상태머신이 소비할 이벤트로 변환. smalltalk/unknown은 게임 진행에 영향 없음(nil).
public enum MissionEvent: Equatable, Sendable { case orderPlaced, helpRequested, exited }

public struct IntentRouter: Sendable {
    public init() {}
    public func route(_ intent: DialogueIntent) -> MissionEvent? {
        switch intent.kind {
        case .orderComplete: return .orderPlaced
        case .helpRequest:   return .helpRequested
        case .leave:         return .exited
        case .smalltalk, .unknown: return nil
        }
    }
}
