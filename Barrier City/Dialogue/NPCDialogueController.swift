//
//  NPCDialogueController.swift
//  WheelchairXR
//
//  Realtime WebRTC NPC 대화와 트랜스크립트·미션 상태를 연결하는 앱 측 코디네이터.
//

import Foundation
import OSLog
import DialogueKit
import DialogueKitOpenAI

@MainActor
@Observable
final class NPCDialogueController {
    private static let lifecycleLogger = Logger(
        subsystem: "com.Television.Barrier-City",
        category: "ConversationLifecycle"
    )
    enum Status: String { case idle = "대기", listening = "듣는 중", thinking = "생각 중", speaking = "말하는 중" }

    /// 버튼 없이 이어지는 공간 대화의 음성 구간 판정값.
    /// 첫 발화는 충분히 기다리되, 말을 시작한 뒤에는 자연스러운 짧은 쉼을 한 턴의 끝으로 본다.
    private enum RealtimeConversationTuning {
        /// NPC 발화가 끝난 뒤 사용자가 첫 말을 시작할 때까지 기다리는 시간.
        static let responseTimeout: TimeInterval = 30
        /// 주문이 확정된 직후에는 "감사합니다" 같은 짧은 반응이 있을 수 있으니 잠깐만 더
        /// 듣고, 없으면 자연스럽게 대화를 마친다. 주문 확정 대사가 끝난 시점부터 잰다.
        static let postOrderFarewellTimeout: TimeInterval = 1.0
        /// 응답 생성이나 도구 후속 응답이 시작되지 않을 때 무한 대기를 끊는 시간.
        static let generationTimeout: TimeInterval = 30
        static let inactivityFarewell = "그럼 전 일하러 갈게요. 필요하면 다시 부르세요."
    }

    // 화면에 보여줄 상태
    var status: Status = .idle
    var userText: String = ""      // 내 확정 발화
    var npcSubtitle: String = ""   // NPC 자막(현재 문장)
    var lastEvent: String = ""     // orderPlaced / helpRequested / exited
    private(set) var isEncounterActive = false
    private(set) var animationRequest: NPCAnimationRequest?
    private(set) var lastMissionEvent: MissionEvent?
    private(set) var missionEventSequence = 0
    private(set) var realtimeSpeechDetected = false

    var liveText: String { realtimeLiveText }
    /// 부분 transcript는 실시간으로, 확정 transcript는 다음 발화 전까지 유지한다.
    /// UI가 listening 상태에만 의존하면 speechStopped 직후 도착하는 확정문을 놓칠 수 있다.
    var visibleUserTranscript: String {
        let finalized = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalized.isEmpty { return finalized }
        return liveText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var userTranscriptIsFinal: Bool {
        !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isBusy: Bool { status == .thinking || status == .speaking }

    private let orderSession: CafeOrderSession
    private let accessibilityAttitude: AccessibilityAttitude
    private let clerkPersonality: ClerkPersonality
    private var animationSequence = 0
    private var hasRequestedGreetingAnimation = false
    private var pendingOrderAcceptanceReaction = false
    private var realtimeSession: RealtimeNPCConversationSession?
    private var realtimeCommandTask: Task<Void, Never>?
    private var realtimeResponseTimeoutTask: Task<Void, Never>?
    private var realtimeGenerationTimeoutTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var orderReadyAnnouncementTask: Task<Void, Never>?
    private var cleanupGeneration = 0
    private var realtimeLiveText = ""
    private var realtimeMission = RealtimeMissionCoordinator()
    /// Realtime 연결보다 오래 살며, 새 immersive generation에서만 초기화된다.
    private var conversationMemory = ConversationMemory()
    private var realtimeOutputIsPlaying = false
    private var realtimeResponseDonePending = false
    private var realtimeMicrophoneIsReady = false
    private var realtimeCanAcceptInput = false
    private var realtimeInputTurnIsActive = false
    private var realtimeSuppressesCurrentInputTurn = false
    /// 주문 확정 대사 직후 한 번만 짧은 유예 시간(postOrderFarewellTimeout)을 쓰라는 표시.
    /// beginRealtimeListeningIfReady가 소비하는 즉시 꺼져, 그 다음 턴부터는 평소 30초
    /// 타임아웃으로 돌아간다.
    private var pendingPostOrderFarewell = false
    private var orderReadyAnnouncementGate = OrderReadyAnnouncementGate()
    private var orderReadyRealtimeSession: RealtimeNPCConversationSession?
    /// 같은 immersive session에서 몇 번째로 연결한 encounter인지 나타낸다.
    private var encounterCount = 0

    private var fulfillmentContext: RainbowSmoothieFulfillmentContext {
        orderSession.phase.dialogueFulfillmentContext
    }

    var orderReadyAnnouncementPresentation: OrderReadyAnnouncementPresentationState {
        OrderReadyAnnouncementPresentationState(
            hasPendingAnnouncement: orderReadyAnnouncementGate.hasPendingAnnouncement,
            hasActiveTask: orderReadyAnnouncementTask != nil
        )
    }

    var blocksConversationForOrderReadyAnnouncement: Bool {
        orderReadyAnnouncementPresentation.isPresented
    }

    init(
        orderSession: CafeOrderSession = CafeOrderSession(),
        accessibilityAttitude: AccessibilityAttitude = .ableist,
        clerkPersonality: ClerkPersonality? = nil
    ) {
        let resolvedPersonality = clerkPersonality ?? .random()
        self.orderSession = orderSession
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = resolvedPersonality
        realtimeMission = RealtimeMissionCoordinator()
    }

    private static func makePersona(
        accessibilityAttitude: AccessibilityAttitude,
        clerkPersonality: ClerkPersonality
    ) -> NPCPersona {
        NPCPersona(
            id: "staff",
            role: "카페 직원",
            systemBase: "지금 이 카페 카운터에서 일하는 직원은 당신뿐이다 — 매니저도, 동료도, 주변에 다른 사람도 없다. 휠체어 이용자에게는 손이 닿지 않는 높이의 주문용 키오스크 옆에 서 있다.",
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: clerkPersonality)
    }

    /// 몰입 공간 재진입 시 이전 대화·미션 이벤트를 초기 상태로 되돌린다.
    func resetImmersiveProgress() {
        orderReadyAnnouncementTask?.cancel()
        orderReadyAnnouncementTask = nil
        orderReadyAnnouncementGate.reset()
        cancelEncounter()
        status = .idle
        userText = ""
        npcSubtitle = ""
        lastEvent = ""
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.resetImmersiveProgress()
        conversationMemory.reset()
        resetRealtimeTurnState()
        animationSequence = 0
        hasRequestedGreetingAnimation = false
        pendingOrderAcceptanceReaction = false
        animationRequest = nil
        lastMissionEvent = nil
        missionEventSequence = 0
        encounterCount = 0
    }

    func requestOrderReadyAnnouncement() {
        let busy = isEncounterActive || status != .idle || orderReadyAnnouncementTask != nil
        switch orderReadyAnnouncementGate.request(isChannelBusy: busy) {
        case .speakNow:
            startOrderReadyAnnouncement()
        case .queued, .ignored:
            break
        }
    }

    func deliverPendingOrderReadyAnnouncementIfPossible() {
        let busy = isEncounterActive || status != .idle || orderReadyAnnouncementTask != nil
        guard orderReadyAnnouncementGate.takePendingIfAvailable(isChannelBusy: busy) else { return }
        startOrderReadyAnnouncement()
    }

    private func startOrderReadyAnnouncement() {
        guard orderReadyAnnouncementTask == nil else { return }
        orderReadyAnnouncementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = RealtimeNPCConversationSession()
            self.orderReadyRealtimeSession = session
            let didComplete = await OrderReadyAnnouncementPresentationTiming.perform(
                present: {
                    self.status = .speaking
                    self.npcSubtitle = OrderReadyAnnouncementContent.line
                },
                speak: {
                    await self.speakRealtimeOrderReadyAnnouncement(session: session)
                },
                waitForMinimumVisibility: {
                    try await Task.sleep(
                        for: OrderReadyAnnouncementPresentationTiming.minimumVisibleDuration
                    )
                }
            )
            await session.stop()
            self.orderReadyRealtimeSession = nil
            guard didComplete else { return }
            self.status = .idle
            self.orderReadyAnnouncementTask = nil
        }
    }

    private func speakRealtimeOrderReadyAnnouncement(session: RealtimeNPCConversationSession) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasResumed = false
            let resumeOnce: @MainActor () -> Void = {
                if !hasResumed {
                    hasResumed = true
                    continuation.resume()
                }
            }

            Task { @MainActor in
                do {
                    try await session.start(
                        instructions: """
                        당신은 친절한 카페 바리스타 점원입니다.
                        손님이 주문한 음료가 완성되었음을 카운터 너머로 밝고 명확하게 안내하세요.
                        """,
                        openingInstructions: """
                        오직 다음 한 문장만 정확하고 밝게 외쳐서 말하세요:
                        주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요.
                        """,
                        tools: []
                    ) { [weak self] event in
                        guard let self else { return }
                        switch event {
                        case .outputTranscriptDone(let text):
                            self.npcSubtitle = text
                        case .outputAudioStopped, .responseDone:
                            resumeOnce()
                        case .failure:
                            resumeOnce()
                        default:
                            break
                        }
                    }
                } catch {
                    resumeOnce()
                }
            }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                resumeOnce()
            }
        }
    }

    /// ImmersiveSpace가 실제로 닫히는 순간 네트워크 연결과 대화 문맥을 폐기한다.
    /// 미션 전체 초기화는 다음 immersive generation 진입점에서 수행한다.
    func endImmersiveSession() {
        let readySession = orderReadyRealtimeSession
        orderReadyRealtimeSession = nil
        Task { @MainActor in
            await readySession?.stop()
        }
        orderReadyAnnouncementTask?.cancel()
        orderReadyAnnouncementTask = nil
        orderReadyAnnouncementGate.reset()
        cancelEncounter()
        conversationMemory.reset()
        encounterCount = 0
    }

    /// Realtime WebRTC 세션을 열고 NPC의 첫 인사부터 자동 음성 대화를 시작한다.
    ///
    /// 방문자가 이미 키오스크 접근성 배리어를 만나 "직원 호출"까지 요청한 뒤에 이 대화에
    /// 도달했더라도, 대화 안에서의 첫 주문 시도는 여전히 키오스크로 되돌려보낸다 — 이
    /// 리다이렉트 자체가 "그 배리어를 다시 한번 몸으로 느끼게 하는" 의도된 장치라
    /// 게임 상태로 건너뛰면 안 된다.
    func startEncounter() async {
        await startRealtimeEncounter()
    }

    /// 거리 이탈·씬 종료처럼 공간 상태가 대화를 끝낼 때 호출한다.
    /// 마이크를 즉시 닫고 진행 중인 자동 턴을 취소하되, 미션 결과는 보존한다.
    func cancelEncounter() {
#if DEBUG
        Self.lifecycleLogger.debug(
            "[CONVERSATION_LIFECYCLE] cancel active=\(self.isEncounterActive, privacy: .public) realtime=\(self.realtimeSession != nil, privacy: .public) status=\(self.status.rawValue, privacy: .public)"
        )
#endif
        isEncounterActive = false
        realtimeCommandTask?.cancel()
        realtimeCommandTask = nil
        realtimeResponseTimeoutTask?.cancel()
        realtimeResponseTimeoutTask = nil
        realtimeGenerationTimeoutTask?.cancel()
        realtimeGenerationTimeoutTask = nil
        let realtime = realtimeSession
        realtimeSession = nil
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.clearEncounterTransientState()
        resetRealtimeTurnState()
        cleanupGeneration &+= 1
        let generation = cleanupGeneration
        let previousCleanup = cleanupTask
        cleanupTask = Task { @MainActor [weak self] in
            await previousCleanup?.value
            if let realtime { await realtime.stop() }
            guard let self else { return }
            if self.status == .listening { self.status = .idle }
            if self.cleanupGeneration == generation { self.cleanupTask = nil }
        }

        if status == .listening { status = .idle }
    }

    private func publishMissionEvent(_ event: MissionEvent) {
        lastEvent = String(describing: event)
        lastMissionEvent = event
        missionEventSequence += 1
#if DEBUG
        Self.lifecycleLogger.notice(
            "[ORDER_EVENT] event=\(String(describing: event), privacy: .public) sequence=\(self.missionEventSequence, privacy: .public) active=\(self.isEncounterActive, privacy: .public)"
        )
#endif
    }

    // MARK: - Realtime speech-to-speech conversation

    private func startRealtimeEncounter() async {
        await finishPendingCleanup()
        guard !Task.isCancelled else { return }
        guard !isEncounterActive else { return }
        lastEvent = ""
        lastMissionEvent = nil
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.clearEncounterTransientState()
        resetRealtimeTurnState()
        realtimeResponseTimeoutTask?.cancel()
        realtimeResponseTimeoutTask = nil
        userText = ""
        npcSubtitle = "연결 중..."
        status = .thinking
        isEncounterActive = true
        let isReturningEncounter = encounterCount > 0
        encounterCount += 1

        if hasRequestedGreetingAnimation {
            requestAnimation(.idle)
        } else {
            hasRequestedGreetingAnimation = true
            requestAnimation(.greet)
        }

        // 몰입 공간 진입 시 미리 연결해둔 클라이언트가 있으면 재사용해 연결 지연 없이
        // 바로 시작한다. 없으면(아직 준비 중이거나 프리커넥트 실패) 평소대로 새로 만든다.
        let session = RealtimePreconnect.shared.takeClient().map(RealtimeNPCConversationSession.init)
            ?? RealtimeNPCConversationSession()
        realtimeSession = session
        do {
            try await session.start(
                instructions: realtimeInstructions(
                    memory: conversationMemory
                ),
                openingInstructions: RealtimeConversationGuide.openingInstructions(
                    memory: conversationMemory,
                    isReturningEncounter: isReturningEncounter
                ),
                tools: []
            ) { [weak self] event in
                self?.handleRealtimeEvent(event)
            }
        } catch {
            await session.stop()
            guard isEncounterActive, realtimeSession === session else { return }
            handleRealtimeEvent(.failure(error.localizedDescription))
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeNPCConversationSession.Event) {
        guard isEncounterActive else { return }
        switch event {
        case .sessionReady:
            break

        case .speechStarted:
            if realtimeInputTurnIsActive { return }
            guard realtimeCanAcceptInput else {
                // 서버가 음성을 받긴 했는데 앱이 무시한 경우 — 마이크 자체는 살아있다.
                Self.lifecycleLogger.notice("[MIC] speechStarted 무시됨 canAcceptInput=false")
                realtimeSuppressesCurrentInputTurn = true
                return
            }
            realtimeResponseTimeoutTask?.cancel()
            realtimeResponseTimeoutTask = nil
            realtimeLiveText = ""
            userText = ""
            realtimeCanAcceptInput = false
            realtimeInputTurnIsActive = true
            realtimeSuppressesCurrentInputTurn = false
            realtimeSpeechDetected = true
            status = .listening

        case .speechStopped:
            guard realtimeInputTurnIsActive, !realtimeSuppressesCurrentInputTurn else { return }
            realtimeSpeechDetected = false
            status = .thinking

        case .inputTranscriptDelta(let text):
            guard realtimeInputTurnIsActive, !realtimeSuppressesCurrentInputTurn else { return }
            realtimeLiveText += text

        case .inputTranscriptDone(let text):
            if realtimeSuppressesCurrentInputTurn {
                realtimeSuppressesCurrentInputTurn = false
                return
            }
            guard realtimeInputTurnIsActive else { return }
            realtimeInputTurnIsActive = false
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            userText = transcript
            realtimeLiveText = transcript
            guard !transcript.isEmpty else {
                status = .listening
                realtimeCanAcceptInput = realtimeMicrophoneIsReady
                if realtimeCanAcceptInput { armRealtimeResponseTimeout() }
                return
            }
            conversationMemory.append(.user, text: transcript)
            realtimeMission.registerVisitorTurn()
            realtimeMicrophoneIsReady = false
            status = .thinking
            guard let realtimeSession else { return }
            armRealtimeGenerationTimeout()
            realtimeCommandTask?.cancel()
            realtimeCommandTask = Task { @MainActor [weak self, realtimeSession] in
                do {
                    guard let self else { return }
                    try Task.checkCancellation()
                    guard self.isEncounterActive,
                          self.realtimeSession === realtimeSession else { return }
                    try await realtimeSession.requestResponse(
                        instructions: self.realtimeInstructions(),
                        toolChoice: .auto,
                        tools: self.fulfillmentContext.allowsOrderCompletion
                            ? [Self.reportOrderAttemptTool, Self.placeMissionOrderTool]
                            : []
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleRealtimeEvent(.failure(error.localizedDescription))
                }
            }

        case .outputTranscriptDelta(let text):
            cancelRealtimeGenerationTimeout()
            if status != .speaking { npcSubtitle = "" }
            status = .speaking
            npcSubtitle += text

        case .outputTranscriptDone(let text):
            cancelRealtimeGenerationTimeout()
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                npcSubtitle = transcript
                conversationMemory.append(.assistant, text: transcript)
            }

        case .outputAudioStarted:
            cancelRealtimeGenerationTimeout()
            realtimeOutputIsPlaying = true
            realtimeMicrophoneIsReady = false
            realtimeCanAcceptInput = false
            status = .speaking

        case .outputAudioStopped:
            realtimeOutputIsPlaying = false
#if DEBUG
            Self.lifecycleLogger.debug(
                "[CONVERSATION_LIFECYCLE] output_audio_stopped responseDonePending=\(self.realtimeResponseDonePending, privacy: .public)"
            )
#endif
            if realtimeResponseDonePending {
                realtimeResponseDonePending = false
                finishRealtimeResponse()
            }

        case .microphoneReady:
            realtimeMicrophoneIsReady = true
            beginRealtimeListeningIfReady()

        case .functionCall(let name, let callID, let arguments):
            let wasOrderPlacedBeforeThisCall = realtimeMission.snapshot.orderPlaced
            if let event = realtimeMission.register(
                name: name,
                callID: callID,
                arguments: arguments
            ) {
                publishMissionEvent(event)
            }
            // 이 호출이 방금 주문을 성립시켰다면(장벽 설명을 듣고 마지못해 받아준 순간),
            // 뒤이은 확인 대사와 함께 Angry 애니메이션이 나가도록 표시해 둔다. 실제 요청은
            // finishRealtimeResponse에서 하는데, 거기서 매번 걸리는 idle 리셋보다 나중에
            // 판단해야 이 표시가 그대로 덮이지 않는다.
            if !wasOrderPlacedBeforeThisCall, realtimeMission.snapshot.orderPlaced {
                pendingOrderAcceptanceReaction = true
            }

        case .responseDone:
            cancelRealtimeGenerationTimeout()
#if DEBUG
            Self.lifecycleLogger.debug(
                "[CONVERSATION_LIFECYCLE] response_done audioPlaying=\(self.realtimeOutputIsPlaying, privacy: .public)"
            )
#endif
            if realtimeOutputIsPlaying {
                realtimeResponseDonePending = true
                return
            }
            finishRealtimeResponse()

        case .failure(let message):
            let completedOrder = realtimeMission.takeCompletedEvent() == .orderPlaced
            cancelEncounter()
            status = .idle
            if completedOrder {
                // 검증된 tool이 주문을 확정했다. 최종 확인 음성 연결이 끊겨도 퀘스트와
                // 앱의 주문 상태가 서로 어긋나지 않도록 완료를 우선한다.
                npcSubtitle = "레인보우 마카롱 스무디 한 잔 주문됐어요. 준비되면 알려드릴게요."
                conversationMemory.append(.assistant, text: npcSubtitle)
                publishMissionEvent(.orderPlaced)
            } else {
                status = .idle
                npcSubtitle = "음성 연결 오류: \(message)"
                publishMissionEvent(.exited)
            }
        }
    }

    private func realtimeInstructions(
        memory: ConversationMemory? = nil
    ) -> String {
        """
        \(RealtimeConversationGuide().instructions(
            persona: Self.makePersona(
                accessibilityAttitude: accessibilityAttitude,
                clerkPersonality: clerkPersonality
            ),
            memory: memory,
            fulfillmentContext: fulfillmentContext
        ))

        # 앱이 관리하는 이번 응답의 주문 상태
        \(realtimeMission.snapshot.promptGuide)
        """
    }

    private func realtimeFollowUpInstructions(_ immediateInstructions: String) -> String {
        """
        \(RealtimeConversationGuide().instructions(
            persona: Self.makePersona(
                accessibilityAttitude: accessibilityAttitude,
                clerkPersonality: clerkPersonality
            ),
            memory: conversationMemory,
            fulfillmentContext: fulfillmentContext
        ))

        \(realtimeMission.snapshot.promptGuide)

        # 방금 나온 도구 호출 결과에 대한 응답
        \(immediateInstructions)
        """
    }

    /// `response.done`은 생성 완료일 뿐 실제 WebRTC 재생 완료가 아니다. 오디오가 재생
    /// 중이면 `output_audio_buffer.stopped` 뒤에만 이 메서드가 호출된다.
    private func finishRealtimeResponse() {
        realtimeSpeechDetected = false
        realtimeInputTurnIsActive = false
        realtimeSuppressesCurrentInputTurn = false
        if pendingOrderAcceptanceReaction {
            pendingOrderAcceptanceReaction = false
            requestAnimation(.angry)
        } else {
            requestAnimation(.idle)
        }
        let functionCalls = realtimeMission.takeFunctionCalls()
        if !functionCalls.isEmpty {
            realtimeCanAcceptInput = false
            realtimeMicrophoneIsReady = false
            status = .thinking
            guard let realtimeSession else { return }
            armRealtimeGenerationTimeout()
            realtimeCommandTask?.cancel()
            // 실제 서사에 영향을 주는 followUp은 첫 항목(진짜 처리된 호출)뿐이다. 모델이
            // 지침을 어기고 같은 응답에 함수를 더 불렀다면 나머지는 API 쪽 tool call을
            // 완결시키기 위한 빈 거절 응답이라 followUpInstructions가 비어 있다.
            let narrativeFollowUp = functionCalls.first { !$0.followUpInstructions.isEmpty }?.followUpInstructions
                ?? functionCalls[0].followUpInstructions
            let outputs = functionCalls.map { (callID: $0.callID, output: $0.output) }
            realtimeCommandTask = Task { @MainActor [weak self] in
                do {
                    guard let self else { return }
                    try await realtimeSession.completeFunctionCalls(
                        outputs,
                        responseInstructions: self.realtimeFollowUpInstructions(narrativeFollowUp)
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleRealtimeEvent(.failure(error.localizedDescription))
                }
            }
            return
        }
        if let event = realtimeMission.takeCompletedEvent() {
            publishMissionEvent(event)
            if event == .exited {
                cancelEncounter()
                status = .idle
                return
            }
            if event == .orderPlaced {
                // 승낙 대사가 막 끝난 참이다. 곧장 마이크를 끊는 대신, 유저가 "감사합니다"
                // 처럼 짧게 반응할 시간을 잠깐 주고 그래도 말이 없으면 자연스럽게 마친다
                // (beginRealtimeListeningIfReady가 이 표시를 한 번만 소비한다).
                pendingPostOrderFarewell = true
            }
        }
        status = .listening
        beginRealtimeListeningIfReady()
    }

    private func beginRealtimeListeningIfReady() {
        guard isEncounterActive,
              realtimeSession != nil,
              status == .listening,
              realtimeMicrophoneIsReady,
              !realtimeOutputIsPlaying,
              !realtimeResponseDonePending,
              !realtimeInputTurnIsActive else {
            // 초록불(status == .listening)은 '받을 준비'일 뿐 실제 입력과 무관하다.
            // 실기에서 음성이 안 들어갈 때 어느 조건에 걸렸는지 남긴다.
            Self.lifecycleLogger.notice(
                "[MIC] listening 차단 micReady=\(self.realtimeMicrophoneIsReady, privacy: .public) outputPlaying=\(self.realtimeOutputIsPlaying, privacy: .public) donePending=\(self.realtimeResponseDonePending, privacy: .public) inputTurn=\(self.realtimeInputTurnIsActive, privacy: .public) status=\(String(describing: self.status), privacy: .public)")
            return
        }
        realtimeCanAcceptInput = true
        if pendingPostOrderFarewell {
            pendingPostOrderFarewell = false
            armRealtimeResponseTimeout(
                duration: RealtimeConversationTuning.postOrderFarewellTimeout,
                onTimeout: { @MainActor [weak self] in
                    self?.finishRealtimeEncounterAfterOrderConfirmation()
                })
        } else {
            armRealtimeResponseTimeout()
        }
    }

    /// 주문 확정 뒤 짧은 유예 시간 동안 유저가 아무 반응이 없으면 조용히 대화를 마친다.
    /// 이미 승낙 대사로 자연스럽게 마무리됐으므로, 평소 무응답 종료와 달리 별도 작별
    /// 대사는 적용하지 않는다.
    private func finishRealtimeEncounterAfterOrderConfirmation() {
        guard isEncounterActive else { return }
        requestAnimation(.idle)
        cancelEncounter()
        status = .idle
    }

    private func resetRealtimeTurnState() {
        cancelRealtimeGenerationTimeout()
        realtimeOutputIsPlaying = false
        realtimeResponseDonePending = false
        realtimeMicrophoneIsReady = false
        realtimeCanAcceptInput = false
        realtimeInputTurnIsActive = false
        realtimeSuppressesCurrentInputTurn = false
        pendingPostOrderFarewell = false
    }

    private func finishPendingCleanup() async {
        let generation = cleanupGeneration
        guard let task = cleanupTask else { return }
        await task.value
        if cleanupGeneration == generation { cleanupTask = nil }
    }

    /// Realtime API의 서버 VAD에는 "아예 말하지 않음" 이벤트가 없으므로 NPC 응답이
    /// 끝난 시점부터 별도 타이머를 건다. 사용자가 발화를 시작하면 즉시 취소한다.
    /// 기본 동작(평소 무응답 종료)이 아닌 다른 마무리가 필요하면(예: 주문 확정 직후의
    /// 짧은 유예 시간) duration/onTimeout으로 바꿔 쓸 수 있다.
    private func armRealtimeResponseTimeout(
        duration: TimeInterval = RealtimeConversationTuning.responseTimeout,
        onTimeout: (@MainActor () async -> Void)? = nil
    ) {
        realtimeResponseTimeoutTask?.cancel()
        realtimeResponseTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard let self,
                  self.isEncounterActive,
                  self.realtimeSession != nil,
                  self.status == .listening else { return }
            self.realtimeResponseTimeoutTask = nil
            if let onTimeout {
                await onTimeout()
            } else {
                await self.finishRealtimeEncounterForInactivity()
            }
        }
    }

    /// `response.create` 이후 아무 출력도 시작되지 않는 경우 대화를 종료해
    /// 사용자가 영구적으로 "생각 중" 상태에 갇히지 않게 한다.
    private func armRealtimeGenerationTimeout() {
        realtimeGenerationTimeoutTask?.cancel()
        realtimeGenerationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(RealtimeConversationTuning.generationTimeout)
                )
            } catch {
                return
            }
            guard let self,
                  self.isEncounterActive,
                  self.realtimeSession != nil,
                  self.status == .thinking else { return }
            self.realtimeGenerationTimeoutTask = nil
            self.realtimeCommandTask?.cancel()
            self.realtimeCommandTask = nil
            self.npcSubtitle = "응답이 지연됐어요. 다시 말을 걸어 주세요."
            self.requestAnimation(.idle)
            self.cancelEncounter()
            self.status = .idle
            self.publishMissionEvent(.exited)
        }
    }

    private func cancelRealtimeGenerationTimeout() {
        realtimeGenerationTimeoutTask?.cancel()
        realtimeGenerationTimeoutTask = nil
    }

    private func finishRealtimeEncounterForInactivity() async {
        guard isEncounterActive, !Task.isCancelled else { return }
        npcSubtitle = RealtimeConversationTuning.inactivityFarewell
        requestAnimation(.idle)
        cancelEncounter()
        status = .idle
        publishMissionEvent(.exited)
    }

    private static let reportOrderAttemptTool = RealtimeFunctionTool(
        name: "report_order_attempt",
        description: "방문자가 어떤 식으로든 아무 품목이나 음료를 달라고/가져다 달라고/주문하려고 하는 그 순간 호출하라 — 미션 품목이 아닌 다른 품목이어도 상관없다. 서로 다른 주문 시도마다 한 번씩, place_mission_order보다 먼저, 말을 하기 전에 호출하라. place_mission_order와 같은 응답 안에서는 절대 호출하지 마라.",
        parameters: []
    )

    private static let placeMissionOrderTool = RealtimeFunctionTool(
        name: "place_mission_order",
        description: "방문자가 명확히 주문했고, 키오스크 리다이렉트 이후 본인이 직접 키오스크를 쓸 수 없는 이유(단순 반복 요청이 아니라 실제 접근성 장벽)를 설명했을 때 레인보우 마카롱 스무디를 정확히 한 잔 접수하라. 항상 호출 가능하지만, 품목·수량이 안 맞거나 이미 주문이 접수됐거나 이 만남에서 아직 첫 주문 시도의 키오스크 리다이렉트가 없었다면(그 경우엔 대신 report_order_attempt를 호출하라) 앱이 모든 호출을 검증해 거절한다. 주문이 확실하다고 판단되는 즉시 호출하라 — 추가 확인을 기다리지 마라.",
        parameters: [
            .init(
                name: "item",
                type: .string,
                description: "요청받은 표준 메뉴 품목.",
                allowedStringValues: [RainbowSmoothieMissionOrder.itemIdentifier]
            ),
            .init(
                name: "quantity",
                type: .integer,
                description: "명시적으로 요청받은 잔 수.",
                minimumIntegerValue: RainbowSmoothieMissionOrder.quantity,
                maximumIntegerValue: RainbowSmoothieMissionOrder.quantity
            ),
        ]
    )

    private func requestAnimation(_ cue: NPCAnimationCue) {
        animationSequence += 1
        animationRequest = NPCAnimationRequest(sequence: animationSequence, cue: cue)
    }
}
