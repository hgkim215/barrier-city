import SwiftUI

/// 키오스크 화면이 아닌 사용자 앞 몰입 공간에 표시하는 독립 알림.
struct KioskBarrierAlertView: View {
    var interactionModel: InteractionModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(GuideTheme.accent)
                .frame(width: 72, height: 72)
                .background(GuideTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("상단 카테고리에 손이 닿지 않아요")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("키오스크의 상단 카테고리가 높아\n앉은 자세에서는 선택할 수 없습니다.\n카페 직원에게 직접 주문해 보세요.")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    KioskPrimaryActionCoordinator.activate(
                        interactionModel: interactionModel,
                        eventSink: GuideFlowModel.shared.handleQuestEvent)
                } label: {
                    Text("직원에게 직접 주문하기")
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
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint("직원에게 도움을 요청하는 다음 미션으로 이동합니다")

                Button {
                    _ = interactionModel.dismissKioskBarrier()
                } label: {
                    Text("닫기")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)
                .accessibilityHint("현재 미션을 유지하고 키오스크로 돌아갑니다")
            }
            .disabled(!interactionModel.kioskBarrierVisible)
        }
        .padding(36)
        .frame(width: 540)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("키오스크 접근성 안내")
    }
}
