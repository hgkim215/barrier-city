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

    // 화면에 보여줄 상태
    var status: Status = .idle
    var userText: String = ""      // 내 확정 발화
    var npcSubtitle: String = ""   // NPC 자막(현재 문장)
    var lastEvent: String = ""     // orderPlaced / helpRequested / exited
    var rapport: Float             // NPC 성향 기반 초기값 + 대화별 변화(AI#4)

    var liveText: String { speech.partialText }  // 듣는 중 실시간 부분 결과

    private let speech = SpeechInput()
    private let voice: VoiceOutput
    private let orchestrator: DialogueOrchestrator
    private var history: [Message] = []

    init(accessibilityAttitude: AccessibilityAttitude = .ableist) {
        let persona = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are a busy cafe employee standing near an ordering kiosk whose touchscreen is too high for wheelchair users.",
            accessibilityAttitude: accessibilityAttitude)
        rapport = accessibilityAttitude.initialRapport
        voice = VoiceOutput(config: AppConfig.proxy, mode: .lowLatency)
        orchestrator = DialogueOrchestrator(
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

        status = .thinking
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
        if result.usedFallback {
            result.spokenSentences.forEach { pair.continuation.yield($0) }
        }
        pair.continuation.finish()

        rapport = await orchestrator.climate.rapport
        if let ev = result.event { lastEvent = String(describing: ev) }

        let full = result.spokenSentences.joined(separator: " ")
        history.append(Message(role: .user, content: utterance))
        if !full.isEmpty { history.append(Message(role: .assistant, content: full)) }

        await speechTask.value
        status = .idle
    }
}
