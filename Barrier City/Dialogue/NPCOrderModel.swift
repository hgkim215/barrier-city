//
//  NPCOrderModel.swift
//  Barrier City
//
//  몰입 씬 NPC 주문의 상태 단일 진실원. NPCDialogueController(STT→AI→TTS)를 감싸고
//  ① orderPlaced/helpRequested 이벤트 → 퀘스트 3단계 완료
//  ② STT·네트워크 실패 → 선택지 폴백(오프라인에서도 완주 가능)
//  을 담당한다.
//

import Observation
import DialogueKitOpenAI

@Observable
@MainActor
final class NPCOrderModel {

    static let shared = NPCOrderModel()

    let controller = NPCDialogueController()
    private let voice = VoiceOutput(config: AppConfig.proxy)

    /// 음성 대신 선택지 버튼으로 진행 중인가(STT 실패 시 자동, 수동 전환도 가능).
    var fallbackMode = false
    /// 주문 완료(퀘스트 발행됨). 완료 후 패널은 안내만 표시.
    private(set) var completed = false

    struct Choice: Identifiable {
        var id: String { label }
        let label: String
        let reply: String
    }

    /// 폴백 선택지 — 고정 응답이 매핑되어 LLM 없이도 주문이 끝난다.
    let choices: [Choice] = [
        Choice(label: "아메리카노 한 잔 주세요",
               reply: "네, 아메리카노 한 잔 준비해드릴게요."),
        Choice(label: "키오스크가 너무 높아서요… 주문을 도와주시겠어요?",
               reply: "그럼요, 제가 도와드릴게요. 어떤 메뉴로 하시겠어요?"),
        Choice(label: "따뜻한 카페라떼 하나 부탁드려요",
               reply: "따뜻한 카페라떼 한 잔, 바로 준비해드릴게요."),
    ]

    /// push-to-talk 시작. STT 시작에 실패하면 폴백 모드로 전환.
    func beginListening() async {
        await controller.beginListening()
        if controller.status != .listening { fallbackMode = true }
    }

    /// push-to-talk 종료 → AI 응답 → 완료 이벤트 확인.
    func endTurn() async {
        await controller.endTurn()
        // orderPlaced(주문 확정)·helpRequested(도움 요청) 모두 3단계 완료로 인정.
        if controller.lastEvent.contains("orderPlaced")
            || controller.lastEvent.contains("helpRequested") {
            complete()
        }
    }

    /// 폴백 선택지 주문: 고정 응답을 자막+TTS로 내보내고 완료 처리.
    func selectFallback(_ choice: Choice) {
        guard !completed else { return }
        controller.userText = choice.label
        controller.npcSubtitle = choice.reply
        Task { await voice.speak(sentences: [choice.reply]) { _ in } }   // 실패 시 자막만
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        NPCSetup.playAnimation(named: "Happy")
        QuestModel.shared.advance(on: .npcHelpDone)
    }

    /// 몰입 공간 재진입 시 초기화.
    func reset() {
        fallbackMode = false
        completed = false
    }
}
