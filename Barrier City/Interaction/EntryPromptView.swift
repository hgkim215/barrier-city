//
//  EntryPromptView.swift
//  Barrier City
//
//  근접 트리거가 활성화되면 사용자 눈앞에 뜨는 예/아니요 패널.
//  RealityView attachment로 렌더되어 content root에 배치된다.
//

import SwiftUI

struct EntryPromptView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 프로퍼티가 관찰 의존성이 된다.
        let im = InteractionModel.shared

        VStack(spacing: 24) {
            Text(im.activeTrigger?.prompt ?? "")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            if let error = im.transitionError {
                Text(error)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button {
                    im.dismissActive()
                } label: {
                    Text(im.activeTrigger?.cancelLabel ?? "아니요")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)

                // 진입 확인은 온보딩·미션의 주 버튼과 같은 노랑 그라데이션을 쓴다.
                Button {
                    SceneSwitcher.requestIndoorTransition()
                } label: {
                    Text(im.activeTrigger?.confirmLabel ?? "예")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            GuideTheme.accentGradient,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 2)
                                .padding(2)
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            .disabled(im.isTransitioning)
        }
        .padding(36)
        .frame(width: 520)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
