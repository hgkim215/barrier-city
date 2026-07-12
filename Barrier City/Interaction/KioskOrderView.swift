//
//  KioskOrderView.swift
//  Barrier City
//
//  키오스크 근접 시 눈높이에 뜨는 장벽 패널(문 패널과 같은 빌보드 방식).
//  "키오스크 사용하기"를 누르면 "너무 높아 사용할 수 없습니다" 안내가 뜬다 —
//  앉은 휠체어 사용자가 무인 키오스크를 스스로 쓸 수 없는 장벽을 문구로 전달한다.
//
//  (정교한 키오스크 화면 UI는 디자인 영역으로 분리. 여기서는 인터랙션·장벽 전달만.)
//

import SwiftUI

struct KioskOrderView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 kioskTooHighShown이 관찰 의존성이 된다.
        let im = InteractionModel.shared

        VStack(spacing: 20) {
            if im.kioskTooHighShown {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("키오스크가 너무 높아\n사용할 수 없습니다")
                    .font(.largeTitle).bold()
                    .multilineTextAlignment(.center)
                Text("앉은 자세에서는 화면과 결제 버튼에 손이 닿지 않습니다.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("키오스크")
                    .font(.largeTitle).bold()
                Text("무인 주문 키오스크입니다.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button {
                    im.kioskTooHighShown = true
                } label: {
                    Label("키오스크 사용하기", systemImage: "hand.tap.fill")
                        .font(.title2)
                        .frame(minWidth: 240)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(48)
        .frame(width: 640)
        .glassBackgroundEffect()
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
