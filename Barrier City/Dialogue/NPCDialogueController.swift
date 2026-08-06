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
        static let responseTimeout: TimeInterval = 12
        static let endOfSpeechSilence: TimeInterval = 1.4
        static let maximumUtteranceDuration: TimeInterval = 25
        static let pollingInterval = Duration.milliseconds(120)
        static let maximumTurns = 8
        static let inactivityFarewell = "주문하실 때 다시 불러 주세요."
        static let turnLimitFarewell = "잠시 후 다시 말씀해 주세요."
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

    var liveText: String { speech.partialText }  // 듣는 중 실시간 부분 결과
    var isBusy: Bool { status == .thinking || status == .speaking }

    private let speech = SpeechInput()
    private let voice: VoiceOutput
    private let accessibilityAttitude: AccessibilityAttitude
    private var orchestrator: DialogueOrchestrator
    private var history: [Message] = []
    private var animationSequence = 0
    private var automaticTurnCount = 0
    private var automaticConversationTask: Task<Void, Never>?

    init(accessibilityAttitude: AccessibilityAttitude = .ableist) {
        self.accessibilityAttitude = accessibilityAttitude
        rapport = accessibilityAttitude.initialRapport
        tone = SocialClimate(rapport: accessibilityAttitude.initialRapport).tone
        voice = VoiceOutput(config: AppConfig.proxy, mode: .lowLatency)
        orchestrator = Self.makeOrchestrator(accessibilityAttitude: accessibilityAttitude)
    }

    private static func makeOrchestrator(
        accessibilityAttitude: AccessibilityAttitude
    ) -> DialogueOrchestrator {
        let persona = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are a busy cafe employee standing near an ordering kiosk whose touchscreen is too high for wheelchair users.",
            accessibilityAttitude: accessibilityAttitude)
        return DialogueOrchestrator(
            persona: persona,
            llm: OpenAILLMClient(config: AppConfig.proxy),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 8),
            cache: DialogueCache(lines: [
                .greeting: CannedLine(text: "어서 오세요.", audioKey: "greeting"),
                .timeout: CannedLine(text: "죄송해요, 다시 한 번 말씀해 주시겠어요?", audioKey: "timeout"),
                .blockedContent: CannedLine(text: "주문을 도와드릴게요.", audioKey: "blocked"),
                .turnLimitReached: CannedLine(text: "이만 다음 손님을 받을게요. 좋은 하루 되세요.", audioKey: "turnlimit"),
            ]),
            turnLimit: 8)
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
        automaticTurnCount = 0
        animationSequence = 0
        animationRequest = nil
        lastMissionEvent = nil
        missionEventSequence = 0
        orchestrator = Self.makeOrchestrator(accessibilityAttitude: accessibilityAttitude)
    }

    /// 점원이 계산대에 도착했을 때 먼저 인사한 뒤 자동 음성 대화를 시작한다.
    /// 호출자는 인사가 끝나면 `.conversing` 상태로 전환할 수 있고, 이후 턴은 이 컨트롤러가
    /// 마이크 열기/닫기까지 반복하므로 별도의 push-to-talk 버튼이 필요 없다.
    func startEncounter() async {
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
        requestAnimation(.greeting)
        await voice.speak("어서 오세요. 무엇을 도와드릴까요?") { [weak self] line in
            self?.npcSubtitle = line
        }
        guard isEncounterActive, !Task.isCancelled else {
            status = .idle
            return
        }
        status = .idle

        automaticConversationTask = Task { @MainActor [weak self] in
            await self?.runAutomaticConversation()
        }
    }

    /// 거리 이탈·씬 종료처럼 공간 상태가 대화를 끝낼 때 호출한다.
    /// 마이크를 즉시 닫고 진행 중인 자동 턴을 취소하되, 호감도와 미션 결과는 보존한다.
    func cancelEncounter() {
        isEncounterActive = false
        automaticConversationTask?.cancel()
        automaticConversationTask = nil

        if speech.isRecording {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.speech.isRecording { _ = await self.speech.stop() }
                if self.status == .listening { self.status = .idle }
            }
        } else if status == .listening {
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
        if !result.usedFallback {
            switch tone {
            case .supportive, .warm:
                requestAnimation(.happy)
            case .dismissive, .hostile:
                requestAnimation(.upset)
            case .neutral:
                break
            }
        }
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

            case .unavailable, .cancelled:
                // 권한 거부/거리 이탈 때 반복해서 마이크를 열지 않는다.
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

    private func requestAnimation(_ cue: NPCAnimationCue) {
        animationSequence += 1
        animationRequest = NPCAnimationRequest(sequence: animationSequence, cue: cue)
    }
}
