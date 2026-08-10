//
//  NPCDialogueController.swift
//  WheelchairXR
//
//  T6 — 앱-측 코디네이터: 발화(STT) → DialogueOrchestrator(AI) → 스트리밍 자막+음성.
//  MissionEvent / SocialClimate(태도 반영)도 노출. iOS·visionOS 공용.
//

import Foundation
import DialogueKit
import DialogueKitOpenAI

@MainActor
@Observable
final class NPCDialogueController {
    enum Status: String { case idle = "대기", listening = "듣는 중", thinking = "생각 중", speaking = "말하는 중" }

    /// 버튼 없이 이어지는 공간 대화의 음성 구간 판정값.
    /// 첫 발화는 충분히 기다리되, 말을 시작한 뒤에는 자연스러운 짧은 쉼을 한 턴의 끝으로 본다.
    private enum AutomaticConversationTuning {
        /// NPC 발화가 끝난 뒤 사용자가 첫 말을 시작할 때까지 기다리는 시간.
        static let responseTimeout: TimeInterval = 30
        /// 사용자가 말을 시작한 뒤 한 턴이 끝났다고 판단하는 무음 시간.
        static let endOfSpeechSilence: TimeInterval = 2.5
        static let maximumUtteranceDuration: TimeInterval = 30
        static let pollingInterval = Duration.milliseconds(120)
        static let maximumTurns = 14
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

    var liveText: String {
        realtimeSession == nil ? speech.partialText : realtimeLiveText
    }
    var isBusy: Bool { status == .thinking || status == .speaking }

    private let speech = SpeechInput()
    private let voice: VoiceOutput
    private let accessibilityAttitude: AccessibilityAttitude
    private var orchestrator: DialogueOrchestrator
    private var history: [Message] = []
    private var animationSequence = 0
    private var hasRequestedGreetingAnimation = false
    private var automaticTurnCount = 0
    private var automaticConversationTask: Task<Void, Never>?
    private var realtimeSession: RealtimeNPCConversationSession?
    private var realtimeCommandTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration = 0
    private var realtimeLiveText = ""
    private var realtimeMission = RealtimeMissionCoordinator()

    init(accessibilityAttitude: AccessibilityAttitude = .ableist) {
        self.accessibilityAttitude = accessibilityAttitude
        rapport = accessibilityAttitude.initialRapport
        tone = SocialClimate(rapport: accessibilityAttitude.initialRapport).tone
#if targetEnvironment(simulator)
        // Simulator의 AVSpeech voice catalog가 손상된 메타데이터를 반환하는 경우가 있어
        // 개발 환경에서는 프록시 TTS를 우선 사용한다.
        voice = VoiceOutput(config: AppConfig.proxy, mode: .cloud)
#else
        voice = VoiceOutput(config: AppConfig.proxy, mode: .lowLatency)
#endif
        orchestrator = Self.makeOrchestrator(accessibilityAttitude: accessibilityAttitude)
    }

    private static func makeOrchestrator(
        accessibilityAttitude: AccessibilityAttitude
    ) -> DialogueOrchestrator {
        let persona = makePersona(accessibilityAttitude: accessibilityAttitude)
        return DialogueOrchestrator(
            persona: persona,
            llm: OpenAILLMClient(config: AppConfig.proxy),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: AutomaticConversationTuning.maximumTurns),
            cache: DialogueCache(lines: [
                .greeting: CannedLine(text: "어서 오세요.", audioKey: "greeting"),
                .timeout: CannedLine(text: "죄송해요, 다시 한 번 말씀해 주시겠어요?", audioKey: "timeout"),
                .blockedContent: CannedLine(text: "주문을 도와드릴게요.", audioKey: "blocked"),
                .turnLimitReached: CannedLine(text: "이만 다음 손님을 받을게요. 좋은 하루 되세요.", audioKey: "turnlimit"),
            ]),
            turnLimit: AutomaticConversationTuning.maximumTurns)
    }

    private static func makePersona(
        accessibilityAttitude: AccessibilityAttitude
    ) -> NPCPersona {
        NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are a busy cafe employee standing near an ordering kiosk whose touchscreen is too high for wheelchair users.",
            accessibilityAttitude: accessibilityAttitude)
    }

    /// 몰입 공간 재진입 시 이전 대화·호감도·미션 이벤트를 초기 상태로 되돌린다.
    func reset() {
        cancelEncounter()
        status = .idle
        userText = ""
        npcSubtitle = ""
        lastEvent = ""
        rapport = accessibilityAttitude.initialRapport
        tone = SocialClimate(rapport: rapport).tone
        history = []
        realtimeLiveText = ""
        realtimeMission.reset()
        automaticTurnCount = 0
        animationSequence = 0
        hasRequestedGreetingAnimation = false
        animationRequest = nil
        lastMissionEvent = nil
        missionEventSequence = 0
        orchestrator = Self.makeOrchestrator(accessibilityAttitude: accessibilityAttitude)
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
        await voice.speak("안녕하세요. 필요하신 거 있으세요?") { [weak self] line in
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
        isEncounterActive = false
        voice.stop()
        automaticConversationTask?.cancel()
        automaticConversationTask = nil
        realtimeCommandTask?.cancel()
        realtimeCommandTask = nil
        let realtime = realtimeSession
        realtimeSession = nil
        realtimeLiveText = ""
        realtimeMission.reset()
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
        if let event = result.event {
            lastEvent = String(describing: event)
            lastMissionEvent = event
            missionEventSequence += 1
        }

        let full = result.spokenSentences.joined(separator: " ")
        history.append(Message(role: .user, content: utterance))
        if !full.isEmpty { history.append(Message(role: .assistant, content: full)) }

        await speechTask.value
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
                if lastMissionEvent == .orderPlaced || lastMissionEvent == .exited {
                    isEncounterActive = false
                    automaticConversationTask = nil
                    return
                }
                if automaticTurnCount >= AutomaticConversationTuning.maximumTurns {
                    await finishAutomaticEncounter(
                        farewell: AutomaticConversationTuning.turnLimitFarewell)
                    return
                }

            case .timedOut:
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
    }

    // MARK: - Realtime speech-to-speech conversation

    private func startRealtimeEncounter() async {
        await finishPendingCleanup()
        guard !Task.isCancelled else { return }
        guard !isEncounterActive else { return }
        automaticConversationTask?.cancel()
        automaticConversationTask = nil
        if speech.isRecording { _ = await speech.stop() }

        await orchestrator.beginEncounter()
        history = []
        lastEvent = ""
        lastMissionEvent = nil
        realtimeLiveText = ""
        realtimeMission.reset()
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
                instructions: RealtimeConversationGuide().instructions(
                    persona: Self.makePersona(accessibilityAttitude: accessibilityAttitude),
                    climate: SocialClimate(rapport: rapport)
                ),
                tools: Self.realtimeTools
            ) { [weak self] event in
                self?.handleRealtimeEvent(event)
            }
        } catch {
            await session.stop()
            realtimeSession = nil
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
            realtimeLiveText = ""
            userText = ""
            status = .listening

        case .speechStopped:
            status = .thinking

        case .inputTranscriptDelta(let text):
            realtimeLiveText += text

        case .inputTranscriptDone(let text):
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            userText = transcript
            realtimeLiveText = transcript

        case .outputTranscriptDelta(let text):
            if status != .speaking { npcSubtitle = "" }
            status = .speaking
            npcSubtitle += text

        case .outputTranscriptDone(let text):
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { npcSubtitle = transcript }

        case .functionCall(let name, let callID, _):
            if let event = realtimeMission.register(name: name, callID: callID) {
                publishMissionEvent(event)
            }

        case .responseDone:
            requestAnimation(.idle)
            if let functionCall = realtimeMission.takeFunctionCall() {
                status = .thinking
                guard let realtimeSession else { return }
                realtimeCommandTask?.cancel()
                realtimeCommandTask = Task { @MainActor [weak self] in
                    do {
                        try await realtimeSession.completeFunctionCall(
                            callID: functionCall.callID,
                            output: functionCall.output
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
                if event == .orderPlaced || event == .exited {
                    cancelEncounter()
                    status = .idle
                    return
                }
            }
            status = .listening

        case .failure(let message):
            cancelEncounter()
            npcSubtitle = "음성 연결 오류: \(message)"
            status = .idle
            publishMissionEvent(.exited)
        }
    }

    private func finishPendingCleanup() async {
        let generation = cleanupGeneration
        guard let task = cleanupTask else { return }
        await task.value
        if cleanupGeneration == generation { cleanupTask = nil }
    }

    private static let realtimeTools: [RealtimeFunctionTool] = [
        .init(name: "complete_order",
              description: "Call after the visitor and employee have confirmed a concrete cafe order."),
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
