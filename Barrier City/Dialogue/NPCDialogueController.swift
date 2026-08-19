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
    private static let orderToolLogger = Logger(
        subsystem: "com.Television.Barrier-City",
        category: "OrderToolEvaluation"
    )

    enum Status: String { case idle = "대기", listening = "듣는 중", thinking = "생각 중", speaking = "말하는 중" }

    /// 버튼 없이 이어지는 공간 대화의 음성 구간 판정값.
    /// 첫 발화는 충분히 기다리되, 말을 시작한 뒤에는 자연스러운 짧은 쉼을 한 턴의 끝으로 본다.
    private enum RealtimeConversationTuning {
        /// NPC 발화가 끝난 뒤 사용자가 첫 말을 시작할 때까지 기다리는 시간.
        static let responseTimeout: TimeInterval = 30
        /// 응답 생성이나 도구 후속 응답이 시작되지 않을 때 무한 대기를 끊는 시간.
        static let generationTimeout: TimeInterval = 30
        static let inactivityRapportPenalty: Float = 0.1
        static let inactivityFarewell = "필요하시면 다시 불러 주세요."
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

    private let accessibilityAttitude: AccessibilityAttitude
    private let clerkPersonality: ClerkPersonality
    private var climate: SocialClimate
    private var animationSequence = 0
    private var hasRequestedGreetingAnimation = false
    private var realtimeSession: RealtimeNPCConversationSession?
    private var realtimeCommandTask: Task<Void, Never>?
    private var realtimeResponseTimeoutTask: Task<Void, Never>?
    private var realtimeGenerationTimeoutTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration = 0
    private var realtimeLiveText = ""
    private var realtimeMission = RealtimeMissionCoordinator()
    private var realtimeOutputIsPlaying = false
    private var realtimeResponseDonePending = false
    private var realtimeMicrophoneIsReady = false
    private var realtimeCanAcceptInput = false
    private var realtimeInputTurnIsActive = false
    private var realtimeSuppressesCurrentInputTurn = false
    /// 같은 immersive session에서 몇 번째로 연결한 encounter인지 나타낸다.
    private var encounterCount = 0

    init(
        accessibilityAttitude: AccessibilityAttitude = .ableist,
        clerkPersonality: ClerkPersonality? = nil
    ) {
        let resolvedPersonality = clerkPersonality ?? .random()
        let initialClimate = SocialClimate(rapport: accessibilityAttitude.initialRapport)
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = resolvedPersonality
        realtimeMission = RealtimeMissionCoordinator(personality: resolvedPersonality)
        climate = initialClimate
        rapport = initialClimate.rapport
        tone = initialClimate.tone
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
        cancelEncounter()
        status = .idle
        userText = ""
        npcSubtitle = ""
        lastEvent = ""
        climate = SocialClimate(rapport: accessibilityAttitude.initialRapport)
        rapport = climate.rapport
        tone = climate.tone
        realtimeLiveText = ""
        realtimeSpeechDetected = false
        realtimeMission.reset()
        resetRealtimeTurnState()
        animationSequence = 0
        hasRequestedGreetingAnimation = false
        animationRequest = nil
        lastMissionEvent = nil
        missionEventSequence = 0
        encounterCount = 0
    }

    /// Realtime WebRTC 세션을 열고 NPC의 첫 인사부터 자동 음성 대화를 시작한다.
    func startEncounter() async {
        await startRealtimeEncounter()
    }

    /// 거리 이탈·씬 종료처럼 공간 상태가 대화를 끝낼 때 호출한다.
    /// 마이크를 즉시 닫고 진행 중인 자동 턴을 취소하되, 호감도와 미션 결과는 보존한다.
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

        let session = RealtimeNPCConversationSession()
        realtimeSession = session
        do {
            try await session.start(
                instructions: realtimeInstructions(
                    for: SocialClimate(rapport: rapport)
                ),
                openingInstructions: RealtimeConversationGuide.openingInstructions(
                    snapshot: realtimeMission.snapshot,
                    isReturningEncounter: isReturningEncounter
                ),
                tools: Self.realtimeTools
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
            let orderDecision = realtimeMission.observe(userTranscript: transcript)
#if DEBUG
            Self.lifecycleLogger.debug(
                "[ORDER_TURN] transcript=\(transcript, privacy: .public) decision=\(String(describing: orderDecision), privacy: .public) terminal=\(orderDecision.endsConversationAfterResponse, privacy: .public)"
            )
#endif
            realtimeMicrophoneIsReady = false
            status = .thinking
            guard let realtimeSession else { return }
            climate.apply(Self.assessAttitude(transcript))
            rapport = climate.rapport
            tone = climate.tone
            armRealtimeGenerationTimeout()
            realtimeCommandTask?.cancel()
            realtimeCommandTask = Task { @MainActor [weak self, realtimeSession] in
                do {
                    guard let self else { return }
                    try Task.checkCancellation()
                    guard self.isEncounterActive,
                          self.realtimeSession === realtimeSession else { return }
                    try await realtimeSession.requestResponse(
                        instructions: self.realtimeInstructions(
                            for: self.climate,
                            orderDecision: orderDecision
                        ),
                        toolChoice: orderDecision == .completeOrder ? .required : .auto,
                        tools: orderDecision == .completeOrder ? [Self.placeOrderTool] : nil
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
                npcSubtitle = "레인보우 스무디 한 잔 주문됐어요. 준비되면 알려드릴게요."
                publishMissionEvent(.orderPlaced)
            } else {
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
            climate: climate
        ))

        # App-owned order state for this response
        \(realtimeMission.snapshot.promptGuide)

        \(orderDecision.realtimeToolPromptGuide)
        """
    }

    private func realtimeFollowUpInstructions(_ immediateInstructions: String) -> String {
        """
        \(RealtimeConversationGuide().instructions(
            persona: Self.makePersona(
                accessibilityAttitude: accessibilityAttitude,
                clerkPersonality: clerkPersonality
            ),
            climate: SocialClimate(rapport: rapport)
        ))

        \(realtimeMission.snapshot.promptGuide)

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
        if let evaluation = realtimeMission.finishOrderToolEvaluation() {
#if DEBUG
            Self.orderToolLogger.notice(
                "[ORDER_TOOL_EVALUATION] outcome=\(evaluation.outcome.rawValue, privacy: .public) localReady=\(evaluation.localOrderReady, privacy: .public) proposed=\(evaluation.modelProposedOrder, privacy: .public) argumentsValid=\(String(describing: evaluation.argumentsValid), privacy: .public)"
            )
#endif
        }
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
                    for: .seconds(RealtimeConversationTuning.responseTimeout))
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
        guard isEncounterActive else { return }
        applyInactivityPenalty()
        guard isEncounterActive, !Task.isCancelled else { return }
        npcSubtitle = RealtimeConversationTuning.inactivityFarewell
        requestAnimation(.idle)
        cancelEncounter()
        status = .idle
        publishMissionEvent(.exited)
    }

    private func applyInactivityPenalty() {
        climate.applyInactivityPenalty(RealtimeConversationTuning.inactivityRapportPenalty)
        rapport = climate.rapport
        tone = climate.tone
    }

    /// 기존 대화 오케스트레이터와 같은 규칙으로 Realtime 발화의 태도를 반영한다.
    private static func assessAttitude(_ text: String) -> PlayerTurn {
        let polite = ["요", "주세요", "감사", "죄송", "부탁"].contains { text.contains($0) }
        let impatient = ["빨리", "당장", "언제까지", "어휴", "답답"].contains { text.contains($0) }
        let hostile = ["야", "바보", "멍청", "꺼져", "닥쳐", "짜증나"].contains { text.contains($0) }
        return PlayerTurn(text: text, polite: polite, impatient: impatient, hostile: hostile)
    }

    private static let placeOrderTool = RealtimeFunctionTool(
        name: "place_order",
        description: "Call once only when counter service is accepted and the visitor explicitly requested exactly one Rainbow Smoothie. The app validates the action before any confirmation.",
        parameters: [
            .init(
                name: "item",
                type: .string,
                description: "Canonical requested menu item.",
                allowedStringValues: ["rainbow_smoothie"]
            ),
            .init(
                name: "quantity",
                type: .integer,
                description: "Explicitly requested number of cups.",
                minimumIntegerValue: 1,
                maximumIntegerValue: 1
            ),
        ]
    )

    private static let realtimeTools: [RealtimeFunctionTool] = [
        placeOrderTool,
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
