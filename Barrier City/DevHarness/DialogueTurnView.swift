//
//  DialogueTurnView.swift
//  WheelchairXR
//
//  T6 — 실제 NPC 대화 한 턴: 누르고 말하면 → AI가 한국어로 답하고 → 음성+자막.
//  iPhone 시뮬레이터로 라이브 검증 가능(마이크 동작). 주문/잡담/무례 등 시도.
//

import SwiftUI

struct DialogueTurnView: View {
    @State private var ctrl = NPCDialogueController()
    @State private var pressing = false
    @State private var beginListeningTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            Text("AI NPC 대화 테스트").font(.title2).bold()

            Text("상태: \(ctrl.status.rawValue)   ·   호감도 \(String(format: "%.2f", ctrl.rapport))")
                .font(.caption).foregroundStyle(.secondary)

            Text(ctrl.npcSubtitle.isEmpty ? "직원에게 말을 걸어보세요 (주문·인사·잡담)" : "🧑‍🍳 직원: \(ctrl.npcSubtitle)")
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
                .disabled(ctrl.status == .thinking || ctrl.status == .speaking)
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 320)
    }
}
