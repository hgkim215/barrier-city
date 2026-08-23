import Combine
import SwiftUI

/// 몰입 공간 진입 직후 애셋 프리로드가 끝날 때까지 보여주는 자리표시 화면.
/// 디자이너의 온보딩 영상이 준비되기 전까지 어두운 배경 위에 안내 문구만 반복해
/// 보여준다(BootLoadingOverlay가 배경을 어둡게 가리고, 이 뷰는 그 위 텍스트만 담당).
struct BootLoadingView: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("도시 건설중" + String(repeating: ".", count: dotCount))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 240)
        }
        .padding(48)
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

#Preview {
    BootLoadingView()
        .background(.black)
}
