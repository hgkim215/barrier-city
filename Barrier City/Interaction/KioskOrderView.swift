//
//  KioskOrderView.swift
//  Barrier City
//
//  키오스크 주문 화면. 서 있는 눈높이(1.5m)에 고정 표시되어, 앉은 휠체어 시점에서는
//  올려다보게 된다. 메뉴·결제 버튼은 앉은 리치 밖(정적 태깅)이라 탭하면 흔들림 +
//  "손이 닿지 않습니다" 토스트만 뜨고 진행이 안 된다. 하단 "직원 호출"만 누를 수 있어,
//  스스로 주문할 수 없는 장벽을 체험시킨다.
//

import SwiftUI

struct KioskOrderView: View {

    /// 메뉴 항목(상단 배치 = 리치 밖).
    private let menu = ["아메리카노", "카페라떼", "바닐라라떼", "카푸치노", "아이스티", "핫초코"]

    /// "손이 닿지 않습니다" 토스트 표시 여부.
    @State private var showUnreachable = false
    /// 흔들림 애니메이션 트리거(증가할 때마다 흔들림).
    @State private var shakeToken = 0

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 staffCalled가 관찰 의존성이 된다.
        let im = InteractionModel.shared

        ZStack(alignment: .bottom) {
            VStack(spacing: 20) {
                Text(InteractionTuning.kioskTitle)
                    .font(.largeTitle).bold()

                if im.staffCalled {
                    calledView(im)
                } else {
                    orderView(im)
                }
            }
            .padding(40)
            .frame(width: 720)

            if showUnreachable {
                Text("손이 닿지 않습니다")
                    .font(.title3).bold()
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .glassBackgroundEffect()
    }

    /// 주문 화면(메뉴 그리드=리치 밖, 결제=리치 밖, 직원 호출=리치 안).
    @ViewBuilder
    private func orderView(_ im: InteractionModel) -> some View {
        // 상단 메뉴(닿지 않음)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
            ForEach(menu, id: \.self) { item in
                Button { triggerUnreachable() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill").font(.title)
                        Text(item).font(.callout)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
                .buttonStyle(.bordered)
            }
        }
        .modifier(ShakeEffect(shakes: CGFloat(shakeToken)))

        // 결제(닿지 않음)
        Button { triggerUnreachable() } label: {
            Text("결제하기").font(.title2)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .modifier(ShakeEffect(shakes: CGFloat(shakeToken)))

        // 직원 호출(닿음) — 앉은 사용자가 유일하게 할 수 있는 것.
        Button { im.staffCalled = true } label: {
            Label("직원 호출", systemImage: "bell.fill").font(.title3)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    /// 직원 호출 후 상태(스텁).
    @ViewBuilder
    private func calledView(_ im: InteractionModel) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("직원을 호출했습니다.\n잠시만 기다려 주세요...")
                .font(.title2).multilineTextAlignment(.center)
            Button("처음으로") { im.staffCalled = false }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 30)
    }

    /// 리치 밖 버튼 탭 반응: 흔들림 + 토스트(1.5초).
    private func triggerUnreachable() {
        withAnimation(.linear(duration: 0.4)) { shakeToken += 1 }
        withAnimation { showUnreachable = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showUnreachable = false }
        }
    }
}

/// 좌우로 짧게 흔드는 지오메트리 효과(shakes가 바뀔 때 애니메이션 구간 동안 진동).
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = sin(shakes * .pi * 4) * 8
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
