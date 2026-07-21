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

    /// 이전 턴(누르기/떼기)이 끝날 때까지 다음 턴을 미루는 직렬화 핸들.
    private var turnTask: Task<Void, Never>?
    /// 완료 이벤트 없이 끝난 연속 턴 수. 일정 횟수 이상이면 자동으로 선택지 폴백으로 유도.
    private var consecutiveIncompleteTurns = 0

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
    /// endTurn()과 같은 turnTask 체인에 올려, 누르기 직후 떼는 경우에도 실행 순서를 보장한다.
    func beginListening() async {
        let previous = turnTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.controller.beginListening()
            if self.controller.status != .listening { self.enterFallback() }
        }
        turnTask = task
        await task.value
    }

    /// push-to-talk 종료 → AI 응답 → 완료 이벤트 확인.
    func endTurn() async {
        let previous = turnTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.completed else { return }
            await self.controller.endTurn()
            // orderPlaced(주문 확정)·helpRequested(도움 요청) 모두 3단계 완료로 인정.
            if self.controller.lastEvent.contains("orderPlaced")
                || self.controller.lastEvent.contains("helpRequested") {
                self.complete()
                return
            }
            // 실제 발화가 있었는데도 완료 이벤트가 없으면(잡담 등) 미완료 턴으로 센다.
            guard !self.controller.userText.isEmpty else { return }
            self.consecutiveIncompleteTurns += 1
            if self.consecutiveIncompleteTurns >= 3 { self.enterFallback() }
        }
        turnTask = task
        await task.value
    }

    /// 폴백 선택지 주문: 고정 응답을 자막+TTS로 내보내고 완료 처리.
    func selectFallback(_ choice: Choice) {
        guard !completed else { return }
        controller.userText = choice.label
        controller.npcSubtitle = choice.reply
        Task { await voice.speak(sentences: [choice.reply]) { _ in } }   // 실패 시 자막만
        complete()
    }

    /// 폴백 진입 지점을 하나로 모은다. STT 에러 문구 등이 화면에 남지 않도록 지운다.
    func enterFallback() {
        fallbackMode = true
        controller.npcSubtitle = ""
        controller.userText = ""
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        NPCSetup.playAnimation(named: "Happy")
        QuestModel.shared.advance(on: .npcHelpDone)
    }

    /// 몰입 공간 재진입 시 초기화. 컨트롤러(장수명 객체)의 이전 세션 잔여 상태도 함께 지운다.
    func reset() {
        fallbackMode = false
        completed = false
        consecutiveIncompleteTurns = 0
        controller.lastEvent = ""
        controller.userText = ""
        controller.npcSubtitle = ""
    }
}
