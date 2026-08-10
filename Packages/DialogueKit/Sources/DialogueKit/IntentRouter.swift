import Foundation

/// ⑥ 의도를 게임 상태머신이 소비할 이벤트로 변환. smalltalk/unknown은 게임 진행에 영향 없음(nil).
public enum MissionEvent: Equatable, Sendable { case orderPlaced, helpRequested, exited }

public struct IntentRouter: Sendable {
    public init() {}

    /// 제한된 게임 의도는 네트워크 LLM 대신 로컬에서 즉시 분류한다.
    public func infer(from text: String) -> DialogueIntent {
        let value = text.lowercased()

        if ["나갈게", "갈게", "가볼게", "그만", "주문 안", "안 살", "됐어요"].contains(where: value.contains) {
            return DialogueIntent(kind: .leave)
        }
        let describesKioskBarrier = value.contains("키오스크")
            && ["높", "못", "불편", "어려", "닿지", "안 닿"].contains(where: value.contains)
        if describesKioskBarrier {
            return DialogueIntent(kind: .orderRequest)
        }

        // 메뉴가 구체적으로 정해진 발화만 주문 완료 후보로 본다. 기존에는 "메뉴가 뭐예요?"나
        // "주문하고 싶어요"도 즉시 미션 완료로 처리되어 한두 마디 만에 대화가 끊겼다.
        let mentionsConcreteItem = [
            "아메리카노", "라떼", "에스프레소", "카푸치노", "모카",
            "콜드브루", "주스", "에이드", "차", "티",
        ].contains(where: value.contains)
        if mentionsConcreteItem {
            return DialogueIntent(kind: .orderComplete)
        }
        let mentionsOrderRequest = ["주문", "커피", "음료", "메뉴", "결제", "한 잔"]
            .contains(where: value.contains)
        if mentionsOrderRequest { return DialogueIntent(kind: .orderRequest) }
        if ["도와", "도움", "밀어", "잡아", "경사로", "문턱", "못 들어", "못 올라", "통과 못"].contains(where: value.contains) {
            return DialogueIntent(kind: .helpRequest)
        }
        if ["안녕", "감사", "날씨", "예쁘", "좋네요", "반가"].contains(where: value.contains) {
            return DialogueIntent(kind: .smalltalk)
        }
        return DialogueIntent(kind: .unknown)
    }

    public func route(_ intent: DialogueIntent) -> MissionEvent? {
        switch intent.kind {
        case .orderRequest: return nil
        case .orderComplete: return .orderPlaced
        case .helpRequest:   return .helpRequested
        case .leave:         return .exited
        case .smalltalk, .unknown: return nil
        }
    }
}
