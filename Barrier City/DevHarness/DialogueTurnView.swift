//
//  DialogueTurnView.swift
//  WheelchairXR
//
//  T6 — 실제 NPC 대화 한 턴: 누르고 말하면 → AI가 한국어로 답하고 → 음성+자막.
//  iPhone 시뮬레이터로 라이브 검증 가능(마이크 동작). 주문/잡담/무례 등 시도.
//

import SwiftUI
import DialogueKit

struct DialogueTurnView: View {
    @Bindable private var ctrl: NPCDialogueController
    @State private var pressing = false
    @State private var beginListeningTask: Task<Void, Never>?
    @State private var textInput = ""
    private let title: String
    private let showsManualControls: Bool

    init(controller: NPCDialogueController,
         title: String = "AI NPC 대화 테스트",
         showsManualControls: Bool = true) {
        _ctrl = Bindable(wrappedValue: controller)
        self.title = title
        self.showsManualControls = showsManualControls
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.title2).bold()

            Text("상태: \(ctrl.status.rawValue)   ·   호감도 \(String(format: "%.2f", ctrl.rapport))   ·   \(ctrl.tone.rawValue)")
                .font(.caption).foregroundStyle(.secondary)

            Text(ctrl.npcSubtitle.isEmpty
                 ? (showsManualControls
                    ? "직원에게 말을 걸어보세요 (주문·인사·잡담)"
                    : "직원이 자동으로 대화를 시작합니다.")
                 : "🧑‍🍳 직원: \(ctrl.npcSubtitle)")
                .font(.title3).multilineTextAlignment(.center)
                .frame(maxWidth: 440, minHeight: 60)

            if !ctrl.userText.isEmpty {
                Text("🙋 나: \(ctrl.userText)").font(.callout).foregroundStyle(.blue)
            } else if pressing {
                Text("🙋 나: \(ctrl.liveText)").font(.callout).foregroundStyle(.secondary)
            }

            if !ctrl.lastEvent.isEmpty {
                Text("미션 이벤트: \(ctrl.lastEvent)").font(.caption).foregroundStyle(.green)
            }

            if showsManualControls {
                HStack(spacing: 8) {
                    TextField("직원에게 말하기…", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendText() }
                        .disabled(ctrl.status != .idle)
                    Button("전송") { sendText() }
                        .buttonStyle(.borderedProminent)
                        .disabled(ctrl.status != .idle || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(pressing ? "말하는 중… (떼면 응답)" : "🎙️ 누르고 말하기")
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(pressing ? Color.red.opacity(0.35) : Color.gray.opacity(0.25))
                    .clipShape(Capsule())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !pressing else { return }
                                pressing = true
                                beginListeningTask = Task { await ctrl.beginListening() }
                            }
                            .onEnded { _ in
                                pressing = false
                                let beginTask = beginListeningTask
                                beginListeningTask = nil
                                Task {
                                    await beginTask?.value
                                    await ctrl.endTurn()
                                }
                            }
                    )
                    .disabled(ctrl.status != .idle && ctrl.status != .listening)
            } else {
                Label(automaticStatusText, systemImage: automaticStatusIcon)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.22))
                    .clipShape(Capsule())
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 320)
    }

    private func sendText() {
        let utterance = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, ctrl.status == .idle else { return }
        textInput = ""
        Task { await ctrl.submit(utterance: utterance) }
    }

    private var automaticStatusText: String {
        switch ctrl.status {
        case .idle: "대화를 기다리는 중"
        case .listening: "말씀하세요 · 자동으로 듣고 있어요"
        case .thinking: "답변을 생각하고 있어요"
        case .speaking: "직원이 말하고 있어요"
        }
    }

    private var automaticStatusIcon: String {
        switch ctrl.status {
        case .listening: "waveform"
        case .thinking: "ellipsis.bubble"
        case .speaking: "speaker.wave.2.fill"
        case .idle: "person.wave.2"
        }
    }
}
