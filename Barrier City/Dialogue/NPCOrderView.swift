//
//  NPCOrderView.swift
//  Barrier City
//
//  NPC 직원 대화 패널(빌보드 attachment).
//  push-to-talk(누르는 동안 듣기)로 음성 주문 → NPC 음성+자막 응답.
//  STT 실패·오프라인이면 선택지 버튼 폴백으로 같은 흐름을 완주한다.
//

import SwiftUI

struct NPCOrderView: View {

    @State private var holding = false

    var body: some View {
        let m = NPCOrderModel.shared
        let c = m.controller

        VStack(spacing: 20) {
            if m.completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.green)
                Text("주문이 접수되었습니다")
                    .font(.largeTitle).bold()
                // 선택지로 완료했다면 그 응답을 우선한다 — 겹쳐 있던 음성 턴의 자막이
                // 완료 화면에 잘못 인용되지 않도록.
                let reply = m.completedReply ?? c.npcSubtitle
                if !reply.isEmpty {
                    Text("“\(reply)”")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("직원에게 주문하기")
                    .font(.largeTitle).bold()
                Text(statusLine(c))
                    .font(.title3).foregroundStyle(.secondary)

                // 자막 영역: 내 발화(실시간/확정) + NPC 응답
                VStack(spacing: 8) {
                    if c.status == .listening {
                        Text(c.liveText.isEmpty ? "…" : c.liveText)
                            .font(.title3).foregroundStyle(.blue)
                    } else if !c.userText.isEmpty {
                        Text("나: \(c.userText)").font(.title3)
                    }
                    if !c.npcSubtitle.isEmpty {
                        Text("직원: \(c.npcSubtitle)")
                            .font(.title3).bold()
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(minHeight: 80)

                // 선택지와 push-to-talk은 배타적이지 않다 — 둘 다 보일 수 있다.
                if m.fallbackMode {
                    VStack(spacing: 12) {
                        ForEach(m.choices) { choice in
                            Button { m.selectFallback(choice) } label: {
                                Text(choice.label)
                                    .font(.title3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    // 듣는 중(.listening)에만 잠근다 — 발화 중에 선택지를 눌러 두 입력이
                    // 동시에 진행되면 push-to-talk이 마이크를 켠 채로 남을 수 있다.
                    .disabled(c.status == .listening)
                }

                if !m.sttUnavailable {
                    // push-to-talk: 누르는 동안 듣고, 떼면 응답.
                    // 누르기/떼기 순서 보장을 위해 모델의 동기 진입점을 그대로 호출한다.
                    Label(holding ? "듣는 중… 떼면 전송" : "누른 채로 말하기",
                          systemImage: holding ? "waveform" : "mic.fill")
                        .font(.title2).bold()
                        .frame(minWidth: 300)
                        .padding(.vertical, 16)
                        .background(holding ? Color.blue : Color.blue.opacity(0.5),
                                    in: Capsule())
                        .onLongPressGesture(minimumDuration: .infinity) {
                        } onPressingChanged: { pressing in
                            holding = pressing
                            if pressing { m.press() } else { m.release() }
                        }
                        .disabled(c.status == .thinking || c.status == .speaking)
                }

                // 선택지가 이미 떠 있으면 눌러도 할 게 없으니 숨긴다. 듣는 중(.listening)만 잠근다.
                if !m.fallbackMode {
                    Button("선택지로 주문하기") {
                        m.offerChoices()
                    }
                    .font(.callout)
                    .disabled(c.status == .listening)
                }
            }
        }
        .padding(48)
        .frame(width: 720)
        .glassBackgroundEffect()
        // STT를 못 쓰게 되면 push-to-talk 버튼 자체가 화면에서 빠지므로 떼기 이벤트가
        // 오지 않는다 — holding이 눌린 채로 남아 재진입 시 잘못된 상태로 보이지 않도록 리셋.
        .onChange(of: m.sttUnavailable) { _, _ in holding = false }
        // 선택지로 주문을 완료하면 완료 화면으로 전환되며 push-to-talk 버튼이 사라져
        // 떼기 이벤트가 오지 않을 수 있다 — holding이 눌린 채로 남지 않도록 리셋.
        .onChange(of: m.completed) { _, _ in holding = false }
    }

    private func statusLine(_ c: NPCDialogueController) -> String {
        switch c.status {
        case .idle:      return "버튼을 누른 채로 주문을 말해 보세요"
        case .listening: return "듣고 있어요"
        case .thinking:  return "직원이 생각하고 있어요…"
        case .speaking:  return "직원이 말하는 중"
        }
    }
}

#Preview(windowStyle: .automatic) {
    NPCOrderView()
}
