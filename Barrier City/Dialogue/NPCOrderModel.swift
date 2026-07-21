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

    /// 선택지 버튼을 제공 중인가(STT 실패 시 자동, 수동 전환도 가능).
    /// 음성 입력과 배타적이지 않다 — 둘 다 켜질 수 있다.
    private(set) var fallbackMode = false
    /// 마이크(STT)를 쓸 수 없는 상태. 이때만 push-to-talk을 숨긴다.
    private(set) var sttUnavailable = false
    /// 주문 완료(퀘스트 발행됨). 완료 후 패널은 안내만 표시.
    private(set) var completed = false
    /// 선택지로 완료했을 때의 응답. 완료 화면이 진행 중이던 음성 턴의 자막과
    /// 뒤섞이지 않고 실제로 고른 응답을 그대로 인용하게 한다.
    private(set) var completedReply: String?

    /// 이전 턴(누르기/떼기)이 끝날 때까지 다음 턴을 미루는 직렬화 핸들.
    private var turnTask: Task<Void, Never>?
    /// 세션 구분자. reset()마다 증가하며, 이전 세션에서 남은 턴이 뒤늦게 끝나도
    /// 새 세션의 상태를 건드리지 못하게 막는다.
    private var sessionEpoch = 0
    /// 완료 이벤트 없이 끝난 연속 턴 수. 일정 횟수 이상이면 선택지를 함께 제공한다.
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

    /// push-to-talk 버튼을 누른 순간. MainActor에서 동기적으로 체인에 연결하므로
    /// 뷰의 누르기/떼기 순서가 그대로 턴 실행 순서가 된다(빠른 탭에서도 역전 없음).
    func press() {
        chain { [weak self] epoch in
            guard let self else { return }
            await self.controller.beginListening()
            guard epoch == self.sessionEpoch else { return }
            // .idle로 돌아왔다 = 마이크를 켜려다 실패했다(권한·인식기 오류). 그 경우에만
            // 음성 UI를 내린다 — .thinking·.speaking은 아직 이전 턴이 끝나지 않은 것뿐이라
            // 여기서 STT를 못 쓰는 상태로 단정하면 남은 세션 내내 마이크가 사라진다.
            if self.controller.status == .idle { self.enterSTTUnavailable() }
        }
    }

    /// push-to-talk 버튼을 뗀 순간 → AI 응답 → 완료 이벤트 확인.
    func release() {
        chain { [weak self] epoch in
            guard let self else { return }
            // endTurn 직전에 비워둔다 — 이전 세션에서 남은 턴이 reset() 이후에 뒤늦게
            // lastEvent를 써도, 그 값이 다음 세션 첫 발화의 완료 판정에 남지 않도록.
            self.controller.lastEvent = ""
            // 이미 완료됐더라도 endTurn은 반드시 호출한다. 이것이 인식기를 멈추는 유일한
            // 경로라, 선택지로 주문을 마치느라 떼기 이벤트를 놓친 경우 여기서 건너뛰면
            // 마이크가 켜진 채 남아 오디오 세션이 .record로 고착되고 이후 재생이 모두 막힌다.
            await self.controller.endTurn()
            // 이전 세션의 잔여 턴이거나 이미 완료됐으면 진행 판정은 하지 않는다.
            guard epoch == self.sessionEpoch, !self.completed else { return }
            // orderPlaced(주문 확정)·helpRequested(도움 요청) 모두 3단계 완료로 인정.
            if self.controller.lastEvent.contains("orderPlaced")
                || self.controller.lastEvent.contains("helpRequested") {
                self.complete()
                return
            }
            // 완료 이벤트 없이 끝난 턴 — 인식 결과가 비어도(마이크가 못 알아들은 경우)
            // 사용자 입장에선 똑같이 진전이 없으므로 같은 카운터로 센다.
            self.consecutiveIncompleteTurns += 1
            if self.consecutiveIncompleteTurns >= 3 { self.offerChoices() }
        }
    }

    /// 턴 본문을 직렬화 체인에 잇는다. 프롤로그(이전 턴 확보 + 세션 기록)는 동기 실행.
    private func chain(_ body: @escaping (Int) async -> Void) {
        let previous = turnTask
        let epoch = sessionEpoch
        turnTask = Task { [weak self] in
            await previous?.value
            guard let self, epoch == self.sessionEpoch else { return }
            await body(epoch)
        }
    }

    /// 폴백 선택지 주문: 고정 응답을 자막+TTS로 내보내고 완료 처리.
    func selectFallback(_ choice: Choice) {
        guard !completed else { return }
        controller.userText = choice.label
        controller.npcSubtitle = choice.reply
        completedReply = choice.reply
        Task { await voice.speak(sentences: [choice.reply]) { _ in } }   // 실패 시 자막만
        complete()
    }

    /// 선택지를 화면에 제공한다. 대화 맥락(자막·내 발화)은 그대로 둔다.
    /// 사용자가 직접 누르는 "선택지로 주문하기"와 대화 정체 시 자동 유도가 함께 쓰는 경로.
    func offerChoices() {
        fallbackMode = true
    }

    /// STT를 쓸 수 없을 때. 마이크가 무용지물이므로 음성 UI를 내리고,
    /// 화면에 남은 STT 에러 문구를 지운 뒤 선택지만 남긴다.
    private func enterSTTUnavailable() {
        sttUnavailable = true
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
        sessionEpoch += 1        // 진행 중이던 이전 세션 턴을 무효화
        turnTask = nil
        fallbackMode = false
        sttUnavailable = false
        completed = false
        completedReply = nil
        consecutiveIncompleteTurns = 0
        controller.lastEvent = ""
        controller.userText = ""
        controller.npcSubtitle = ""
    }
}
