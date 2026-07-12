//
//  EntryPromptView.swift
//  Barrier City
//
//  근접 트리거가 활성화되면 문 앞 공간에 뜨는 예/아니요 패널.
//  RealityView attachment로 렌더되어 worldRoot 자식 엔티티로 배치된다.
//

import SwiftUI

struct EntryPromptView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 프로퍼티가 관찰 의존성이 된다.
        let im = InteractionModel.shared

        VStack(spacing: 22) {
            Text(im.activeTrigger?.prompt ?? "")
                .font(.title).bold()
                .multilineTextAlignment(.center)

            if let error = im.transitionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button {
                    im.dismissActive()
                } label: {
                    Text(im.activeTrigger?.cancelLabel ?? "아니요")
                        .font(.title3)
                        .frame(minWidth: 120)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await SceneSwitcher.switchToIndoor() }
                } label: {
                    Text(im.activeTrigger?.confirmLabel ?? "예")
                        .font(.title3)
                        .frame(minWidth: 120)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(im.isTransitioning)
        }
        .padding(40)
        .frame(width: 560)
        .glassBackgroundEffect()
    }
}
