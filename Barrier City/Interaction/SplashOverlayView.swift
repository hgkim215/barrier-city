import SwiftUI

/// "splash" 볼륨 윈도우의 콘텐츠. BootLoadingOverlay(검은 구체)와 별개로, 몰입
/// 공간이 열리는 동안 이 윈도우가 앞에 떠서 Splash_1 → Splash_2를 SplashSequence
/// 계약대로 0.5초 간격 무한 루프로 보여준다.
///
/// PNG는 Assets 카탈로그가 아니라 Resources 폴더의 낱장 파일이라 Image(_:)로
/// 바로 못 부른다(오디오 리소스와 같은 방식으로 Bundle.main.url을 통해 불러온다).
/// 배경 투명은 원본 디자인 의도라, RealityKit 텍스처처럼 블렌딩 모드를 신경 쓸
/// 필요 없이 SwiftUI Image가 있는 그대로 그린다.
struct SplashOverlayView: View {
    @State private var images: [UIImage] = []
    @State private var frame = 0
    @State private var swapTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if !images.isEmpty {
                    Image(uiImage: images[frame % images.count])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 540, height: 488)

            HStack(spacing: 10) {
                Text("도로 공사중")
                Text(SplashSequence.progressDots(atFrame: frame) ?? "")
                    .frame(width: 78, alignment: .leading)
            }
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
            .background(.black.opacity(0.58), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("도로 공사중")
        }
        .frame(width: 600, height: 600)
        .task {
            images = Self.loadImages()
            frame = 0
            swapTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: SplashSequence.frameDuration)
                    guard !Task.isCancelled else { return }
                    frame = (frame + 1) % SplashSequence.combinedCycleLength
                }
            }
        }
        .onDisappear {
            swapTask?.cancel()
            swapTask = nil
        }
    }

    /// Splash_1 → Splash_2 순서로 전부 로드한다. 하나라도 빠졌다면 불완전한
    /// 순서로 순환하지 않도록 빈 배열을 반환한다.
    private static func loadImages() -> [UIImage] {
        var result: [UIImage] = []
        for name in SplashSequence.resourceNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let image = UIImage(contentsOfFile: url.path)
            else { return [] }
            result.append(image)
        }
        return result
    }
}

#Preview(windowStyle: .volumetric) {
    SplashOverlayView()
}
