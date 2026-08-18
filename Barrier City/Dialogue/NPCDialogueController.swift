//
//  NPCDialogueController.swift
//  WheelchairXR
//
//  T6 — 앱-측 코디네이터: 발화(STT) → DialogueOrchestrator(AI) → 스트리밍 자막+음성.
//  MissionEvent / SocialClimate(태도 반영)도 노출. iOS·visionOS 공용.
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
    private enum AutomaticConversationTuning {
        /// NPC 발화가 끝난 뒤 사용자가 첫 말을 시작할 때까지 기다리는 시간.
        static let responseTimeout: TimeInterval = 30
        /// 응답 생성이나 도구 후속 응답이 시작되지 않을 때 무한 대기를 끊는 시간.
        static let generationTimeout: TimeInterval = 30
        /// 사용자가 말을 시작한 뒤 한 턴이 끝났다고 판단하는 무음 시간.
        static let endOfSpeechSilence: TimeInterval = 2.5
        static let maximumUtteranceDuration: TimeInterval = 30
        static let pollingInterval = Duration.milliseconds(120)
        static let maximumTurns = 14
        static let inactivityRapportPenalty: Float = 0.1
        static let inactivityFarewell = "필요하시면 다시 불러 주세요."
        static let turnLimitFarewell = "잠깐 일 좀 보고 올게요. 더 필요하시면 다시 불러 주세요."
    }

    private enum AutomaticListenResult {
        case utterance(String)
        case timedOut
        case unavailable
        case cancelled
    }

    // 화면에 보여줄 상태
    var status: Status = .idle
    var userText: String = ""      // 내 확정 발화
    var npcSubtitle: String = ""   // NPC 자막(현재 문장)
    var lastEvent: String = ""     // orderPlaced / helpRequested / exited
    var rapport: Float             // NPC 성향 기반 초기값 + 대화별 변화(AI#4)
    var tone: Tone
    private(set) var isEncounterActive = false
    private(set) var animationRequest: NPCAnimationRequest?
    private(set) var lastMissionEvent: MissionEvent?
    private(set) var missionEventSequence = 0
    private(set) var realtimeSpeechDetected = false

    var liveText: String {
        realtimeSession == nil ? speech.partialText : realtimeLiveText
    }
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
    var microphoneLevel: Float {
        speech.inputLevel
    }
    var showsMicrophoneLevel: Bool {
        realtimeSession == nil
    }
    var isBusy: Bool { status == .thinking || status == .speaking }

    private let speech = SpeechInput()
    private let voice: VoiceOutput
    private let realtimeFailureConfirmationVoice: VoiceOutput
    private let orderSession: CafeOrderSession
    private let accessibilityAttitude: AccessibilityAttitude
    private let clerkPersonality: ClerkPersonality
    private var orchestrator: DialogueOrchestrator
    private var history: [Message] = []
    private var animationSequence = 0
    private var hasRequestedGreetingAnimation = false
    private var automaticTurnCount = 0
    private var automaticConversationTask: Task<Void, Never>?
    private var realtimeSession: RealtimeNPCConversationSession?
    private var realtimeCommandTask: Task<Void, Never>?
    private var realtimeResponseTimeoutTask: Task<Void, Never>?
    private var realtimeGenerationTimeoutTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var orderReadyAnnouncementTask: Task<Void, Never>?
    private var cleanupGeneration = 0
    private var realtimeLiveText = ""
    private var realtimeMission = RealtimeMissionCoordinator()
    private var realtimeOutputIsPlaying = false
    private var realtimeResponseDonePending = false
    private var realtimeMicrophoneIsReady = false
    private var realtimeCanAcceptInput = false
    private var realtimeInputTurnIsActive = false
    private var realtimeSuppressesCurrentInputTurn = false
    /// 로컬 주문 판정은 끝났지만 최종 음성 응답 뒤까지 발행을 보류한 이벤트.
    private var realtimeTerminalEvent: MissionEvent?
    private var realtimeFailureConfirmationGeneration = 0
    private let realtimeFailureConfirmation = RealtimeFailureOrderConfirmationCoordinator()
    private var orderReadyAnnouncementGate = OrderReadyAnnouncementGate()

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
        self.orderSession = orderSession
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = clerkPersonality ?? .random()
        realtimeMission = RealtimeMissionCoordinator(personality: self.clerkPersonality)
        rapport = accessibilityAttitude.initialRapport
        tone = SocialClimate(rapport: accessibilityAttitude.initialRapport).tone
#if targetEnvironment(simulator)
        // Simulator의 AVSpeech voice catalog가 손상된 메타데이터를 반환하는 경우가 있어
        // 개발 환경에서는 프록시 TTS를 우선 사용한다.
        voice = VoiceOutput(config: AppConfig.proxy, mode: .cloud)
#else
        voice = VoiceOutput(config: AppConfig.proxy, mode: .lowLatency)
#endif
        realtimeFailureConfirmationVoice = VoiceOutput(
            config: AppConfig.proxy,
            mode: .lowLatency)
        orchestrator = Self.makeOrchestrator(
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: self.clerkPersonality
        )
    }

    private static func makeOrchestrator(
        accessibilityAttitude: AccessibilityAttitude,
        clerkPersonality: ClerkPersonality
    ) -> DialogueOrchestrator {
        let persona = makePersona(
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: clerkPersonality
        )
        return DialogueOrchestrator(
            persona: persona,
            llm: OpenAILLMClient(config: AppConfig.proxy),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: AutomaticConversationTuning.maximumTurns),
            cache: DialogueCache(lines: [
                .greeting: CannedLine(text: "어서 오세요.", audioKey: "greeting"),
                .timeout: CannedLine(text: "죄송해요, 다시 한 번 말씀해 주시겠어요?", audioKey: "timeout"),
                .blockedContent: CannedLine(text: "주문을 도와드릴게요.", audioKey: "blocked"),
                .orderConfirm: CannedLine(
                    text: RealtimeFailureOrderConfirmationContent.line,
                    audioKey: "order-confirm"
                ),
                .turnLimitReached: CannedLine(text: "이만 다음 손님을 받을게요. 좋은 하루 되세요.", audioKey: "turnlimit"),
            ]),
            turnLimit: AutomaticConversationTuning.maximumTurns)
    }

    private static func makePersona(
        accessibilityAttitude: AccessibilityAttitude,
        clerkPersonality: ClerkPersonality
    ) -> NPCPersona {
        NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are a busy cafe employee standing near an ordering kiosk whose touchscreen is too high for wheelchair users.",
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: clerkPersonality)
    }

    /// 몰입 공간 재진입 시 이전 대화·호감도·미션 이벤트를 초기 상태로 되돌린다.
    func reset() {
        orderReadyAnnouncementTask?.cancel()
        orderReadyAnnouncementTask = nil
        orderReadyAnnouncementGate.reset()
        cancelEncounter()
        status = .idle
        userText = ""
        npcSubtitle = ""
        lastEvent = ""
        rapport = accessibilityAttitude.initialRapport
        tone = SocialClimate(rapport: rapport).tone
        history = []
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.reset()
        realtimeTerminalEvent = nil
        resetRealtimeTurnState()
        automaticTurnCount = 0
        animationSequence = 0
        hasRequestedGreetingAnimation = false
        animationRequest = nil
        lastMissionEvent = nil
        missionEventSequence = 0
        orchestrator = Self.makeOrchestrator(
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: clerkPersonality
        )
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
            let didComplete = await OrderReadyAnnouncementPresentationTiming.perform(
                present: {
                    self.status = .speaking
                    self.npcSubtitle = OrderReadyAnnouncementContent.line
                },
                speak: { [weak self] in
                    guard let self else { return }
                    await self.voice.speak(OrderReadyAnnouncementContent.line) { [weak self] _ in
                        self?.npcSubtitle = OrderReadyAnnouncementContent.line
                    }
                },
                waitForMinimumVisibility: {
                    try await Task.sleep(
                        for: OrderReadyAnnouncementPresentationTiming.minimumVisibleDuration
                    )
                }
            )
            guard didComplete else { return }
            self.status = .idle
            self.orderReadyAnnouncementTask = nil
        }
    }

    /// 점원이 계산대에 도착했을 때 먼저 인사한 뒤 자동 음성 대화를 시작한다.
    /// 호출자는 인사가 끝나면 `.conversing` 상태로 전환할 수 있고, 이후 턴은 이 컨트롤러가
    /// 마이크 열기/닫기까지 반복하므로 별도의 push-to-talk 버튼이 필요 없다.
    func startEncounter() async {
#if targetEnvironment(simulator)
        if DevelopmentOptions.simulatorMicrophoneEnabled {
            await startRealtimeEncounter()
        } else {
            await startLegacyEncounter()
        }
#else
        await startRealtimeEncounter()
#endif
    }

    private func startLegacyEncounter() async {
        await finishPendingCleanup()
        guard !Task.isCancelled else { return }
        guard !isEncounterActive else { return }
        automaticConversationTask?.cancel()
        automaticConversationTask = nil
        if speech.isRecording { _ = await speech.stop() }

        // 새 만남의 턴 제한과 프롬프트 기록은 비우되, 같은 점원의 호감도와 누적 주문
        // 요청 횟수는 유지한다. 그래야 재접근 대화가 막히지 않으면서 미션 진행도 보존된다.
        await orchestrator.beginEncounter()
        history = []
        automaticTurnCount = 0
        lastEvent = ""
        lastMissionEvent = nil
        isEncounterActive = true
        userText = ""
        npcSubtitle = ""
        status = .speaking
        if hasRequestedGreetingAnimation {
            requestAnimation(.idle)
        } else {
            hasRequestedGreetingAnimation = true
            requestAnimation(.greet)
        }
        await voice.speak(RealtimeConversationGuide.legacyOpeningFallback) { [weak self] line in
            self?.npcSubtitle = line
        }
        guard isEncounterActive, !Task.isCancelled else {
            status = .idle
            return
        }
        requestAnimation(.idle)
        status = .idle

        automaticConversationTask = Task { @MainActor [weak self] in
            await self?.runAutomaticConversation()
        }
    }

    /// 거리 이탈·씬 종료처럼 공간 상태가 대화를 끝낼 때 호출한다.
    /// 마이크를 즉시 닫고 진행 중인 자동 턴을 취소하되, 호감도와 미션 결과는 보존한다.
    func cancelEncounter() {
        cancelEncounter(preservingRealtimeFailureConfirmation: false)
    }

    private func cancelEncounter(preservingRealtimeFailureConfirmation: Bool) {
#if DEBUG
        Self.lifecycleLogger.debug(
            "[CONVERSATION_LIFECYCLE] cancel active=\(self.isEncounterActive, privacy: .public) realtime=\(self.realtimeSession != nil, privacy: .public) terminal=\(String(describing: self.realtimeTerminalEvent), privacy: .public) status=\(self.status.rawValue, privacy: .public)"
        )
#endif
        isEncounterActive = false
        voice.stop()
        if !preservingRealtimeFailureConfirmation {
            realtimeFailureConfirmation.cancel()
            realtimeFailureConfirmationVoice.stop()
        }
        automaticConversationTask?.cancel()
        automaticConversationTask = nil
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
        realtimeMission.reset()
        realtimeTerminalEvent = nil
        resetRealtimeTurnState()
        cleanupGeneration &+= 1
        let generation = cleanupGeneration
        let previousCleanup = cleanupTask
        cleanupTask = Task { @MainActor [weak self] in
            await previousCleanup?.value
            if let realtime { await realtime.stop() }
            guard let self else { return }
            if self.speech.isRecording { _ = await self.speech.stop() }
            if self.status == .listening { self.status = .idle }
            if self.cleanupGeneration == generation { self.cleanupTask = nil }
        }

        if !speech.isRecording, status == .listening {
            status = .idle
        }
    }

    /// push-to-talk 시작
    func beginListening() async {
        guard status == .idle else { return }
        userText = ""; npcSubtitle = ""
        do {
            try await speech.start()
            status = .listening
        } catch {
            npcSubtitle = "STT 에러: \(error.localizedDescription)"
            status = .idle
        }
    }

    /// push-to-talk 종료 → AI 응답 → 음성+자막
    func endTurn() async {
        guard status == .listening else { return }
        let utterance = await speech.stop()
        userText = utterance
        guard !utterance.isEmpty else { status = .idle; return }

        await respond(to: utterance)
    }

    /// 시뮬레이터에서도 STT 없이 대화/애니메이션 연결을 검증하는 텍스트 입력 경로.
    func submit(utterance: String) async {
        guard status == .idle else { return }
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userText = trimmed
        await respond(to: trimmed)
    }

    private func respond(to utterance: String) async {
        status = .thinking
        lastEvent = ""
        lastMissionEvent = nil
        let pair = AsyncStream.makeStream(of: String.self)
        let speechTask = Task { @MainActor [weak self] in
            for await sentence in pair.stream {
                guard let self else { return }
                self.status = .speaking
                await self.voice.speak(sentence) { [weak self] line in
                    self?.npcSubtitle = line
                }
            }
        }
        let result = await orchestrator.handle(
            utterance: utterance,
            history: history,
            fulfillmentContext: fulfillmentContext,
            onSentence: { pair.continuation.yield($0) })
        guard !Task.isCancelled else {
            pair.continuation.finish()
            speechTask.cancel()
            await speechTask.value
            status = .idle
            return
        }
        if result.usedFallback {
            result.spokenSentences.forEach { pair.continuation.yield($0) }
        }
        pair.continuation.finish()

        rapport = await orchestrator.climate.rapport
        tone = await orchestrator.climate.tone
        // Greet는 세션의 첫 인사 전용이다. 이후 감정 톤이 좋아져도 다시 호출하지 않는다.
        if !result.usedFallback { requestAnimation(.idle) }
        let full = result.spokenSentences.joined(separator: " ")
        history.append(Message(role: .user, content: utterance))
        if !full.isEmpty { history.append(Message(role: .assistant, content: full)) }

        let terminalEvent = result.event.flatMap { event in
            event == .orderPlaced || event == .exited ? event : nil
        }
        if let event = result.event, terminalEvent == nil {
            publishMissionEvent(event)
        }
        await speechTask.value
        if let terminalEvent {
            // 마지막 확인 음성을 끝낸 뒤 먼저 논리적 대화 세션을 닫고 퀘스트 이벤트를 보낸다.
            // NPC 주문 접수와 전체 체험 완료는 후속 퀘스트 단계에서 별도로 진행된다.
            isEncounterActive = false
            automaticConversationTask = nil
            publishMissionEvent(terminalEvent)
        }
        status = .idle
    }

    // MARK: - Automatic spatial conversation

    private func runAutomaticConversation() async {
        while isEncounterActive, !Task.isCancelled {
            let listenResult = await listenForAutomaticTurn()
            guard isEncounterActive, !Task.isCancelled else { return }

            switch listenResult {
            case .utterance(let utterance):
                await respond(to: utterance)
                guard isEncounterActive, !Task.isCancelled else { return }

                automaticTurnCount += 1
                if automaticTurnCount >= AutomaticConversationTuning.maximumTurns {
                    await finishAutomaticEncounter(
                        farewell: AutomaticConversationTuning.turnLimitFarewell)
                    return
                }

            case .timedOut:
                await applyInactivityPenalty()
                await finishAutomaticEncounter(
                    farewell: AutomaticConversationTuning.inactivityFarewell)
                return

            case .unavailable:
#if targetEnvironment(simulator)
                // 시뮬레이터에서는 마이크를 재시도하지 않고 세션/위치 잠금은 유지한다.
                // 개발용 텍스트 입력이나 거리 이탈로 명시적으로 대화를 진행/종료할 수 있다.
                status = .idle
                npcSubtitle = "시뮬레이터에서는 마이크 대신 개발용 텍스트 입력을 사용해 주세요."
                automaticConversationTask = nil
                return
#else
                isEncounterActive = false
                automaticConversationTask = nil
                publishMissionEvent(.exited)
                return
#endif

            case .cancelled:
                // 거리 이탈이나 명시적 취소 후에는 반복해서 마이크를 열지 않는다.
                isEncounterActive = false
                automaticConversationTask = nil
                publishMissionEvent(.exited)
                return
            }
        }
    }

    /// 마이크를 자동으로 열고, 첫 발화 후 일정 시간 새 인식 결과가 없으면 한 턴을 확정한다.
    private func listenForAutomaticTurn() async -> AutomaticListenResult {
        await beginListening()
        guard isEncounterActive, !Task.isCancelled else {
            if speech.isRecording { _ = await speech.stop() }
            return .cancelled
        }
        guard status == .listening else { return .unavailable }

        let startedAt = Date()
        var lastChangeAt = startedAt
        var lastPartial = ""

        while isEncounterActive, !Task.isCancelled {
            let now = Date()
            let partial = speech.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial != lastPartial {
                lastPartial = partial
                lastChangeAt = now
                userText = partial
            }

            let elapsed = now.timeIntervalSince(startedAt)
            let silence = now.timeIntervalSince(lastChangeAt)
            if lastPartial.isEmpty, elapsed >= AutomaticConversationTuning.responseTimeout {
                _ = await speech.stop()
                status = .idle
                return .timedOut
            }
            if !lastPartial.isEmpty,
               silence >= AutomaticConversationTuning.endOfSpeechSilence
                || elapsed >= AutomaticConversationTuning.maximumUtteranceDuration {
                let utterance = await speech.stop()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                status = .idle
                userText = utterance
                return utterance.isEmpty ? .timedOut : .utterance(utterance)
            }

            try? await Task.sleep(for: AutomaticConversationTuning.pollingInterval)
        }

        if speech.isRecording { _ = await speech.stop() }
        status = .idle
        return .cancelled
    }

    private func finishAutomaticEncounter(farewell: String) async {
        guard isEncounterActive else { return }
        status = .speaking
        await voice.speak(farewell) { [weak self] line in
            self?.npcSubtitle = line
        }
        guard isEncounterActive, !Task.isCancelled else { return }
        status = .idle
        isEncounterActive = false
        automaticConversationTask = nil
        publishMissionEvent(.exited)
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
        realtimeFailureConfirmationVoice.stop()
        realtimeFailureConfirmationGeneration = realtimeFailureConfirmation.beginEncounter()
        automaticConversationTask?.cancel()
        automaticConversationTask = nil
        if speech.isRecording { _ = await speech.stop() }

        await orchestrator.beginEncounter()
        history = []
        lastEvent = ""
        lastMissionEvent = nil
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.reset()
        realtimeTerminalEvent = nil
        resetRealtimeTurnState()
        realtimeResponseTimeoutTask?.cancel()
        realtimeResponseTimeoutTask = nil
        userText = ""
        npcSubtitle = "연결 중..."
        status = .thinking
        isEncounterActive = true

        if hasRequestedGreetingAnimation {
            requestAnimation(.idle)
        } else {
            hasRequestedGreetingAnimation = true
            requestAnimation(.greet)
        }

        let session = RealtimeNPCConversationSession()
        realtimeSession = session
        do {
            try await session.start(
                instructions: realtimeInstructions(
                    for: SocialClimate(rapport: rapport)
                ),
                tools: Self.realtimeTools
            ) { [weak self] event in
                self?.handleRealtimeEvent(event)
            }
        } catch {
            await session.stop()
            realtimeSession = nil
            realtimeFailureConfirmation.cancel()
            realtimeFailureConfirmationVoice.stop()
            isEncounterActive = false
            npcSubtitle = "실시간 음성 연결이 어려워 기존 음성 모드로 전환합니다."
            status = .idle
            await startLegacyEncounter()
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
            let orderDecision: RainbowSmoothieOrderDecision
            if fulfillmentContext.allowsOrderCompletion {
                orderDecision = realtimeMission.observe(userTranscript: transcript)
            } else {
                orderDecision = .continueConversation
            }
#if DEBUG
            Self.lifecycleLogger.debug(
                "[ORDER_TURN] transcript=\(transcript, privacy: .public) decision=\(String(describing: orderDecision), privacy: .public) terminal=\(orderDecision.endsConversationAfterResponse, privacy: .public)"
            )
#endif
            if orderDecision.endsConversationAfterResponse {
                // 주문 슬롯은 확정됐지만 퀘스트 이벤트는 최종 확인 음성과 세션 종료 뒤에 보낸다.
                realtimeTerminalEvent = .orderPlaced
            }
            realtimeMicrophoneIsReady = false
            status = .thinking
            guard let realtimeSession else { return }
            armRealtimeGenerationTimeout()
            realtimeCommandTask?.cancel()
            realtimeCommandTask = Task { @MainActor [weak self, realtimeSession] in
                do {
                    guard let self else { return }
                    let climate = await self.orchestrator.observePlayerTurn(transcript)
                    try Task.checkCancellation()
                    guard self.isEncounterActive,
                          self.realtimeSession === realtimeSession else { return }
                    self.rapport = climate.rapport
                    self.tone = climate.tone
                    try await realtimeSession.requestResponse(
                        instructions: self.realtimeInstructions(
                            for: climate,
                            orderDecision: orderDecision
                        ),
                        toolChoice: orderDecision.disablesTools ? .none : .auto
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
            if !transcript.isEmpty { npcSubtitle = transcript }

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
                "[CONVERSATION_LIFECYCLE] output_audio_stopped responseDonePending=\(self.realtimeResponseDonePending, privacy: .public) terminal=\(String(describing: self.realtimeTerminalEvent), privacy: .public)"
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
            if let event = realtimeMission.register(
                name: name,
                callID: callID,
                arguments: arguments
            ) {
                publishMissionEvent(event)
            }

        case .responseDone:
            cancelRealtimeGenerationTimeout()
#if DEBUG
            Self.lifecycleLogger.debug(
                "[CONVERSATION_LIFECYCLE] response_done audioPlaying=\(self.realtimeOutputIsPlaying, privacy: .public) terminal=\(String(describing: self.realtimeTerminalEvent), privacy: .public)"
            )
#endif
            if realtimeOutputIsPlaying {
                realtimeResponseDonePending = true
                return
            }
            finishRealtimeResponse()

        case .failure(let message):
            let completedOrder = realtimeTerminalEvent == .orderPlaced
                || realtimeMission.takeCompletedEvent() == .orderPlaced
            let confirmationGeneration = realtimeFailureConfirmationGeneration
            cancelEncounter(preservingRealtimeFailureConfirmation: completedOrder)
            if completedOrder {
                // 주문 슬롯은 이미 앱에서 확정됐다. Realtime 연결 대신 온디바이스 음성으로
                // 같은 확인 문구를 끝까지 전달한 뒤에만 퀘스트 이벤트를 발행한다.
                _ = realtimeFailureConfirmation.recoverCompletedOrder(
                    encounterGeneration: confirmationGeneration,
                    present: { [weak self] line in
                        self?.npcSubtitle = line
                        self?.status = .speaking
                    },
                    speak: { [weak self] line in
                        guard let self else { return }
                        await self.realtimeFailureConfirmationVoice.speak(line) { [weak self] _ in
                            self?.npcSubtitle = RealtimeFailureOrderConfirmationContent.line
                        }
                    },
                    publish: { [weak self] in
                        self?.publishMissionEvent(.orderPlaced)
                    },
                    finish: { [weak self] in
                        self?.status = .idle
                    })
            } else {
                status = .idle
                npcSubtitle = "음성 연결 오류: \(message)"
                publishMissionEvent(.exited)
            }
        }
    }

    private func realtimeInstructions(
        for climate: SocialClimate,
        orderDecision: RainbowSmoothieOrderDecision = .continueConversation
    ) -> String {
        """
        \(RealtimeConversationGuide().instructions(
            persona: Self.makePersona(
                accessibilityAttitude: accessibilityAttitude,
                clerkPersonality: clerkPersonality
            ),
            climate: climate,
            fulfillmentContext: fulfillmentContext
        ))

        # App-owned order state for this response
        \(orderDecision.promptGuide)
        """
    }

    private func realtimeFollowUpInstructions(_ immediateInstructions: String) -> String {
        """
        \(realtimeInstructions(for: SocialClimate(rapport: rapport)))

        # Immediate tool result response
        \(immediateInstructions)
        """
    }

    /// `response.done`은 생성 완료일 뿐 실제 WebRTC 재생 완료가 아니다. 오디오가 재생
    /// 중이면 `output_audio_buffer.stopped` 뒤에만 이 메서드가 호출된다.
    private func finishRealtimeResponse() {
        realtimeSpeechDetected = false
        realtimeInputTurnIsActive = false
        realtimeSuppressesCurrentInputTurn = false
        requestAnimation(.idle)
        if let functionCall = realtimeMission.takeFunctionCall() {
            realtimeCanAcceptInput = false
            realtimeMicrophoneIsReady = false
            status = .thinking
            guard let realtimeSession else { return }
            armRealtimeGenerationTimeout()
            realtimeCommandTask?.cancel()
            realtimeCommandTask = Task { @MainActor [weak self] in
                do {
                    try await realtimeSession.completeFunctionCall(
                        callID: functionCall.callID,
                        output: functionCall.output,
                        responseInstructions: self?.realtimeFollowUpInstructions(
                            functionCall.followUpInstructions
                        ) ?? functionCall.followUpInstructions
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleRealtimeEvent(.failure(error.localizedDescription))
                }
            }
            return
        }
        if let terminalEvent = realtimeTerminalEvent {
#if DEBUG
            Self.lifecycleLogger.notice(
                "[CONVERSATION_LIFECYCLE] terminal_response_finished closing encounter"
            )
#endif
            realtimeTerminalEvent = nil
            cancelEncounter()
            status = .idle
            // 논리적 Realtime 세션을 닫은 상태에서만 NPC/퀘스트 계층으로 전달한다.
            publishMissionEvent(terminalEvent)
            return
        }
        if let event = realtimeMission.takeCompletedEvent() {
            publishMissionEvent(event)
            if event == .orderPlaced || event == .exited {
                cancelEncounter()
                status = .idle
                return
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
              !realtimeInputTurnIsActive else { return }
        realtimeCanAcceptInput = true
        armRealtimeResponseTimeout()
    }

    private func resetRealtimeTurnState() {
        cancelRealtimeGenerationTimeout()
        realtimeOutputIsPlaying = false
        realtimeResponseDonePending = false
        realtimeMicrophoneIsReady = false
        realtimeCanAcceptInput = false
        realtimeInputTurnIsActive = false
        realtimeSuppressesCurrentInputTurn = false
    }

    private func finishPendingCleanup() async {
        let generation = cleanupGeneration
        guard let task = cleanupTask else { return }
        await task.value
        if cleanupGeneration == generation { cleanupTask = nil }
    }

    /// Realtime API의 서버 VAD에는 "아예 말하지 않음" 이벤트가 없으므로 NPC 응답이
    /// 끝난 시점부터 별도 타이머를 건다. 사용자가 발화를 시작하면 즉시 취소한다.
    private func armRealtimeResponseTimeout() {
        realtimeResponseTimeoutTask?.cancel()
        realtimeResponseTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(AutomaticConversationTuning.responseTimeout))
            } catch {
                return
            }
            guard let self,
                  self.isEncounterActive,
                  self.realtimeSession != nil,
                  self.status == .listening else { return }
            self.realtimeResponseTimeoutTask = nil
            await self.finishRealtimeEncounterForInactivity()
        }
    }

    /// `response.create` 이후 아무 출력도 시작되지 않는 경우 대화를 종료해
    /// 사용자가 영구적으로 "생각 중" 상태에 갇히지 않게 한다.
    private func armRealtimeGenerationTimeout() {
        realtimeGenerationTimeoutTask?.cancel()
        realtimeGenerationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(AutomaticConversationTuning.generationTimeout)
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
        guard isEncounterActive else { return }
        await applyInactivityPenalty()
        guard isEncounterActive, !Task.isCancelled else { return }
        npcSubtitle = AutomaticConversationTuning.inactivityFarewell
        requestAnimation(.idle)
        cancelEncounter()
        status = .idle
        publishMissionEvent(.exited)
    }

    private func applyInactivityPenalty() async {
        await orchestrator.applyInactivityPenalty(
            AutomaticConversationTuning.inactivityRapportPenalty)
        rapport = await orchestrator.climate.rapport
        tone = await orchestrator.climate.tone
    }

    private static let realtimeTools: [RealtimeFunctionTool] = [
        .init(name: "request_help",
              description: "Call only when the visitor explicitly asks for another employee or assistance."),
        .init(name: "end_conversation",
              description: "Call only when the visitor clearly says they are leaving or ending the conversation."),
    ]

    private func requestAnimation(_ cue: NPCAnimationCue) {
        animationSequence += 1
        animationRequest = NPCAnimationRequest(sequence: animationSequence, cue: cue)
    }
}
