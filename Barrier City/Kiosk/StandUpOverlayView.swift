//
//  StandUpOverlayView.swift
//  Barrier City
//
//  일어서기 감지 시 시야 정면에 뜨는 안내 패널.
//  "그냥 일어서면 되잖아"라는 탈출구를 차단하는 제약 전달 장치.
//

import SwiftUI

struct StandUpOverlayView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.roll")
                .font(.system(size: 52))
            Text("휠체어 사용자는\n일어설 수 없습니다")
                .font(.largeTitle).bold()
                .multilineTextAlignment(.center)
            Text("앉은 채로 체험해 주세요")
                .font(.title3).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 620)
        .glassBackgroundEffect()
    }
}

#Preview(windowStyle: .automatic) {
    StandUpOverlayView()
}
