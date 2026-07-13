//
//  QuestHUDView.swift
//  Barrier City
//
//  퀘스트 가이드 HUD 패널. QuestModel.shared를 관찰해 현재 목표를 보여주고,
//  단계 완료 순간에는 잠깐 "완료!" 연출을 띄운다. 위치·빌보드는 QuestSetup/
//  QuestHUDFollower가 처리하고, 이 뷰는 내용만 담당한다.
//

import SwiftUI

struct QuestHUDView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 값이 관찰 의존성이 된다.
        let quest = QuestModel.shared

        Group {
            if let done = quest.justCompletedStep {
                completed(done)
            } else if let step = quest.currentStep {
                objective(step)
            } else {
                EmptyView()   // 전체 완료(이번 스코프에선 도달 안 함)
            }
        }
        .animation(.spring(duration: 0.4), value: quest.justCompletedStep)
        .animation(.spring(duration: 0.4), value: quest.currentStep)
    }

    /// 완료 순간 연출.
    private func completed(_ step: QuestStep) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("완료!").font(.title2).bold()
            Text(step.title).font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .glassBackgroundEffect()
        .transition(.scale.combined(with: .opacity))
    }

    /// 상시 목표 카드.
    private func objective(_ step: QuestStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("목표")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.tint.opacity(0.25), in: Capsule())
            Text(step.title).font(.title2).bold()
            Text(step.detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 420, alignment: .leading)
        .padding(24)
        .glassBackgroundEffect()
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview(windowStyle: .automatic) {
    QuestHUDView()
}
