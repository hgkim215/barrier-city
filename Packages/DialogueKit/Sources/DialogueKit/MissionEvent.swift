/// 게임 상태 머신이 소비하는 NPC 대화 이벤트.
public enum MissionEvent: Equatable, Sendable {
    case orderPlaced
    case helpRequested
    case exited
}
