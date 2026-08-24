import Combine
import SwiftUI
import UIKit

/// 몰입 공간 진입 직후 애셋 프리로드가 끝날 때까지 보여주는 스플래시 화면.
/// Splash_1 → Splash_2를 0.5초 간격으로 번갈아 보여준다(BootLoadingOverlay가 배경을
/// 어둡게 가리고, 이 뷰는 그 위 이미지만 담당). Resources 폴더의 낱장 PNG라
/// 애셋 카탈로그(Image(_:))가 아니라 오디오 리소스와 같은 방식(Bundle.main.url)으로
/// 불러온다.
struct BootLoadingView: View {
    private static let images: [UIImage] = ["Splash_1", "Splash_2"].compactMap { name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image
    }

    @State private var index = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if Self.images.isEmpty {
                // 스플래시 이미지를 못 찾았을 때만 쓰는 문구 폴백.
                VStack(spacing: 24) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("도시 건설중")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(48)
            } else {
                Image(uiImage: Self.images[index % Self.images.count])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 700, height: 700)
            }
        }
        .onReceive(timer) { _ in
            guard Self.images.count > 1 else { return }
            index = (index + 1) % Self.images.count
        }
    }
}

#Preview {
    BootLoadingView()
        .background(.black)
}
