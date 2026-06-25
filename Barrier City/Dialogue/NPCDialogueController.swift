//
//  NPCDialogueController.swift
//  WheelchairXR
//
//  T6 — 앱-측 코디네이터: 발화(STT) → DialogueOrchestrator(AI) → 음성+자막(TTS).
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
    var rapport: Float = 0         // 누적 호감도(AI#4)

    var liveText: String { speech.partialText }  // 듣는 중 실시간 부분 결과

    private let speech = SpeechInput()
    private let voice = VoiceOutput(config: AppConfig.proxy)
    private let orchestrator: DialogueOrchestrator
    private var history: [Message] = []

    init() {
        orchestrator = DialogueOrchestrator(
            persona: NPCPersona(
                id: "staff",
                role: "cafe staff",
                englishSystemBase: "You are a busy but kind cafe staff member taking a customer's order. Keep replies to 1-2 short sentences."),
            climate: SocialClimate(),
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
        history.append(Message(role: .user, content: utterance))
        let result = await orchestrator.handle(utterance: utterance, history: history)
        rapport = await orchestrator.climate.rapport
        if let ev = result.event { lastEvent = String(describing: ev) }

        let full = result.spokenSentences.joined()
        if !full.isEmpty { history.append(Message(role: .assistant, content: full)) }

        status = .speaking
        await voice.speak(sentences: result.spokenSentences) { [weak self] line in
            self?.npcSubtitle = line
        }
        status = .idle
    }
}
