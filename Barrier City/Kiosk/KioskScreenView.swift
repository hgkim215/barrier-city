//
//  KioskScreenView.swift
//  Barrier City
//
//  실물 크기 키오스크 화면(월드 고정 attachment — 배치는 InteractionSetup).
//  세로 1090pt ≈ 0.8m. 상단 영역(카테고리·결제 확인)은 공간상 1.4m+ 높이에 놓여
//  앉은 사용자의 손이 닿지 않는다. 상단 버튼 탭은 KioskFlowModel이
//  리치 판정에 따라 근접 실패로 라우팅한다.
//

import SwiftUI

struct KioskScreenView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 프로퍼티가 관찰 의존성이 된다.
        let m = KioskFlowModel.shared

        VStack(spacing: 0) {
            switch m.phase {
            case .browsing:  browsing(m)
            case .resetting: resetting(m)
            case .payment:   payment(m)
            case .failed:    failed
            }
        }
        .frame(width: 680, height: 1090)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
        .animation(.default, value: m.phase)
    }

    // MARK: 메뉴 탐색(장벽 ①·②)

    @ViewBuilder
    private func browsing(_ m: KioskFlowModel) -> some View {
        // 상단 존: 카테고리 탭(물리적으로 높아 손이 안 닿는다)
        upperZone {
            HStack(spacing: 10) {
                ForEach(Array(KioskMenu.categories.enumerated()), id: \.offset) { i, name in
                    Button { m.categoryTapped(i) } label: {
                        Text(name)
                            .font(.title3).bold()
                            .padding(.vertical, 12).padding(.horizontal, 18)
                            .background(i == m.categoryIndex ? Color.orange : Color.white.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .nearMissFlash(pulse: m.nearMissPulse)
        }

        // 중단: 메뉴 그리드
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(KioskMenu.items(for: m.categoryIndex)) { item in
                Button { m.addToCart(item) } label: {
                    VStack(spacing: 6) {
                        Text(item.name).font(.title3).bold()
                        Text("\(item.price)원").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(item.price == 0)
            }
        }
        .padding(20)

        Spacer(minLength: 0)

        // 하단: 안내 + 장바구니 + 주문하기(하단이라 닿는다)
        VStack(spacing: 10) {
            if m.showsReachHint {
                Label("손이 닿지 않습니다", systemImage: "hand.raised.slash")
                    .font(.callout).foregroundStyle(.orange)
            }
            idleBar(m)
            HStack {
                Text("장바구니 \(m.cart.count)개 · \(m.cartTotal)원")
                    .font(.title3)
                Spacer()
                Button { m.proceedToPayment() } label: {
                    Text("주문하기").font(.title2).bold()
                        .padding(.vertical, 12).padding(.horizontal, 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.cart.isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: 시간 초과 리셋(장벽 ②)

    @ViewBuilder
    private func resetting(_ m: KioskFlowModel) -> some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56)).foregroundStyle(.orange)
            Text("이용자가 없어\n처음 화면으로 돌아갑니다")
                .font(.largeTitle).bold().multilineTextAlignment(.center)
            Text("담아둔 메뉴가 사라졌습니다")
                .font(.title3).foregroundStyle(.secondary)
        }
        Spacer()
    }

    // MARK: 결제(장벽 ③)

    @ViewBuilder
    private func payment(_ m: KioskFlowModel) -> some View {
        // 상단 존: 카드 투입구 + 결제 확인(최상단 — 도달해도 카드 삽입 불가 설정)
        upperZone {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.3))
                    .frame(width: 220, height: 14)
                    .overlay(Text("CARD").font(.caption2).foregroundStyle(.black.opacity(0.6)))
                Button { m.paymentConfirmTapped() } label: {
                    Text("결제 확인").font(.title2).bold()
                        .padding(.vertical, 14).padding(.horizontal, 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .nearMissFlash(pulse: m.nearMissPulse)
        }

        Spacer()
        VStack(spacing: 14) {
            Text("결제 금액").font(.title3).foregroundStyle(.secondary)
            Text("\(m.cartTotal)원").font(.system(size: 54, weight: .bold))
            // 결제 화면의 안내는 '결제 시도'에만 반응한다. showsReachHint는 카테고리
            // 근접 실패와 카운터를 공유하므로, 그걸 쓰면 결제를 눌러보기도 전에
            // "닿지 않는다"가 떠서 장벽 ③의 좌절 연출이 김빠진다.
            if m.paymentAttempts > 0 {
                Label("손이 닿지 않아 결제가 진행되지 않았습니다 (\(m.paymentAttempts)/\(KioskTuning.paymentMaxAttempts))",
                      systemImage: "hand.raised.slash")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        Spacer()
        idleBar(m).padding(20)
    }

    // MARK: 최종 실패

    @ViewBuilder
    private var failed: some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.red)
            Text("결제가 완료되지 않았습니다")
                .font(.largeTitle).bold().multilineTextAlignment(.center)
            Text("직원에게 문의해 주세요")
                .font(.title2).foregroundStyle(.secondary)
        }
        Spacer()
    }

    // MARK: 공통 조각

    /// 상단 존 컨테이너: 높이를 고정해 화면 위쪽(공간상 1.4m+)에 온다.
    @ViewBuilder
    private func upperZone<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(.white.opacity(0.06))
    }

    /// 유휴 타이머 바: 남은 시간을 시각화(줄어드는 압박).
    @ViewBuilder
    private func idleBar(_ m: KioskFlowModel) -> some View {
        GeometryReader { geo in
            let ratio = max(0, min(1, m.idleRemaining / KioskTuning.idleLimit))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(ratio < 0.3 ? Color.red : Color.white.opacity(0.4))
                    .frame(width: geo.size.width * CGFloat(ratio))
            }
        }
        .frame(height: 6)
    }
}

/// 근접 실패 펄스: nearMissPulse가 증가할 때마다 잠깐 주황 테두리를 깜빡인다
/// ("닿을 듯 말 듯" 피드백).
private struct NearMissFlash: ViewModifier {
    let pulse: Int
    @State private var flashing = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.orange, lineWidth: flashing ? 4 : 0))
            .onChange(of: pulse) {
                flashing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    flashing = false
                }
            }
            .animation(.easeOut(duration: 0.3), value: flashing)
    }
}

private extension View {
    func nearMissFlash(pulse: Int) -> some View { modifier(NearMissFlash(pulse: pulse)) }
}

#Preview(windowStyle: .automatic) {
    KioskScreenView()
}
