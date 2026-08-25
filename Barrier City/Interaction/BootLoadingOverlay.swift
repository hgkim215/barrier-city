import RealityKit
import SwiftUI
import UIKit
import OSLog

/// 몰입 공간 진입 직후, Outdoor 표시 + Indoor/Realtime 프리로드가 끝날 때까지 화면을
/// 어둡게 가리고 스플래시 이미지를 띄운다. 검은 구체는 SceneFadeOverlay와 같은
/// head-anchor 기법을 쓰되, 씬 전환용 짧은 페이드가 아니라 로딩 중 계속 떠 있는
/// 화면이라 반경을 더 넉넉히 두고 이미지를 눈앞 편한 거리에 별도로 배치한다.
///
/// 스플래시 이미지는 SwiftUI Attachment가 아니라 순수 RealityKit 평면(plane) +
/// 텍스처로 그린다 — Attachment로 시도했을 때는(예전 구현) 검은 구체는 항상 잘
/// 보이는데 그 위에 있어야 할 이미지/문구가 로딩 내내 전혀 안 보이는 문제가 있었다
/// (attachments.entity(for:)를 make 클로저 맨 앞에서 부르면 아직 nil이라는 타이밍
/// 문제, isEnabled 기본값 문제까지 다 고쳐봐도 재현됐다 — 실기에서 검은 화면만
/// 계속 나온다는 게 확인됨). 검은 구체와 똑같이 이미 확실히 동작하는 방식(평면
/// ModelEntity를 anchor의 자식으로 붙이는 것)으로 바꿔 이 불확실성을 없앴다.
@MainActor
final class BootLoadingOverlay {
    static let shared = BootLoadingOverlay()

    private enum Tuning {
        static let radius: Float = 3.0
        static let imageDistance: Float = -1.4
        /// 스플래시 이미지 한 변의 크기(m). 원본이 정사각형(800x800)이라 정사각형으로 둔다.
        static let imageSize: Float = 1.1
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "BootLoadingOverlay")

    private var anchor: Entity?
    private var imagePlane: ModelEntity?
    private var materials: [UnlitMaterial] = []
    private var swapIndex = 0
    private var swapTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// ImmersiveView의 RealityView make 클로저 맨 앞에서 한 번 호출한다.
    func install(content: RealityViewContent) {
        // 빠른 재진입이나 RealityView 재생성에도 이전 anchor/task가 남지 않게 한다.
        remove()

        let anchor = AnchorEntity(.head)
        anchor.name = "BootLoadingOverlay"

        let sphereMesh = MeshResource.generateSphere(radius: Tuning.radius)
        var sphereMaterial = UnlitMaterial(color: .black)
        sphereMaterial.faceCulling = .front   // 시야가 구 안쪽에 있으므로 안쪽 면을 렌더링한다.
        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        anchor.addChild(sphere)

        content.add(anchor)
        self.anchor = anchor

        // 텍스처 디코딩(PNG→CGImage→TextureResource)은 install()을 막지 않고 별도
        // Task로 미룬다 — 검은 구체는 이번 프레임에 바로 보이고, Outdoor 씬 로드와
        // 동시에(백그라운드로) 스플래시 이미지가 준비되는 대로 뒤이어 붙는다.
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = Self.loadSplashMaterials()
            guard !Task.isCancelled else {
                Self.logger.error("스플래시 로드 취소됨(Task.isCancelled)")
                return
            }
            guard self.anchor === anchor else {
                Self.logger.error("스플래시 부착 취소: install()이 재호출되어 anchor가 이미 교체됨")
                return
            }
            guard let firstMaterial = loaded.first else {
                Self.logger.error("스플래시 부착 취소: 로드된 머티리얼이 없음(위 로드 실패 로그 참고)")
                return
            }
            self.materials = loaded
            self.attachSplashPlane(to: anchor, firstMaterial: firstMaterial)
            Self.logger.info("스플래시 평면 부착 완료: \(loaded.count, privacy: .public)개 머티리얼")
        }
    }

    private func attachSplashPlane(to anchor: Entity, firstMaterial: UnlitMaterial) {
        let plane = ModelEntity(
            mesh: .generatePlane(width: Tuning.imageSize, height: Tuning.imageSize),
            materials: [firstMaterial])
        plane.name = "BootLoadingSplashImage"
        // 평면의 기본 법선은 +Y(위)라, 카메라(-Z 쪽)를 보도록 X축 기준 -90도 눕힌다.
        plane.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        plane.setPosition([0, 0, Tuning.imageDistance], relativeTo: anchor)
        anchor.addChild(plane)
        imagePlane = plane

        swapIndex = 0
        guard materials.count > 1 else { return }
        swapTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SplashSequence.frameDuration)
                guard !Task.isCancelled else { return }
                self?.advanceSplash()
            }
        }
    }

    /// Splash_1 → Splash_2 순서로 전부 로드한다. 하나라도 빠졌다면 불완전한 순서로
    /// 실행하지 않고 빈 배열을 반환한다. Resources 폴더의 낱장 PNG라 애셋 카탈로그가
    /// 아니라 오디오 리소스와 같은 방식(Bundle.main.url)으로 불러온다.
    private static func loadSplashMaterials() -> [UnlitMaterial] {
        var result: [UnlitMaterial] = []
        for name in SplashSequence.resourceNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                logger.error("스플래시 리소스 없음: \(name, privacy: .public).png (번들에 포함되지 않음)")
                return []
            }
            guard let uiImage = UIImage(contentsOfFile: url.path), let cgImage = uiImage.cgImage else {
                logger.error("스플래시 이미지 디코딩 실패: \(name, privacy: .public).png")
                return []
            }
            // TextureResource(image:)는 CGImage의 픽셀 포맷(색공간·알파 배치 등)이
            // 기대와 다르면 조용히 throw할 수 있다. 원본 PNG의 색 프로필/알파 배치가
            // 무엇이든 항상 성공하도록, 표준 sRGB·premultiplied-last 8bit RGBA로
            // 다시 그려 넘긴다 — 실기에서 "검은 구체만 계속 보이는" 현상의 실제
            // 원인이 여기(구버전엔 try?로 조용히 삼켜짐)였을 가능성이 크다.
            guard let normalized = normalizeToRGBA8(cgImage) else {
                logger.error("스플래시 이미지 정규화 실패: \(name, privacy: .public).png")
                return []
            }
            let texture: TextureResource
            do {
                // 화면에 항상 같은 크기로 고정 표시되는 2D 스플래시라 밉맵이 불필요하다.
                // 밉맵 생성을 끄면 로드가 더 빠르고(백그라운드 애셋 최적화), 밉맵 체인
                // 생성 과정에서 발생할 수 있는 실패 경로도 함께 제거된다.
                texture = try TextureResource(
                    image: normalized,
                    options: .init(semantic: .color, mipmapsMode: .none))
            } catch {
                logger.error("스플래시 텍스처 생성 실패: \(name, privacy: .public).png — \(String(describing: error), privacy: .public)")
                return []
            }
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            // 평면이 카메라를 보도록 준 회전(아래 install)이 앞/뒤 어느 쪽을 향하는지
            // 렌더링 없이는 확신할 수 없었다 — 실제로는 뒷면이 카메라를 향해 기본
            // 백페이스 컬링에 걸려 화면에 검은 구체만 보이고 이미지가 전혀 안 보이는
            // 문제가 있었다. 양면 다 그리게 해 방향에 관계없이 항상 보이게 한다.
            material.faceCulling = .none
            result.append(material)
        }
        return result
    }

    /// 원본 PNG는 배경이 완전 투명(alpha=0)인데, 그 투명 픽셀의 RGB 자체가 (0,0,0)로
    /// 저장돼 있다 — 실측 확인됨(코너 픽셀 RGBA=(0,0,0,0)). UnlitMaterial 기본
    /// 블렌딩(.opaque)이 텍스처 알파를 어떻게 다루느냐에 따라 이 투명 배경이 그대로
    /// 검은 사각형으로 그려져 뒤의 검은 구체와 구분이 안 갈 수 있다. 알파 채널
    /// 자체를 없애 이 불확실성을 원천 차단한다 — 불투명 흰 배경 위에 원본을
    /// 합성해, 최종 텍스처에는 알파가 아예 없으므로(noneSkipLast) 블렌딩 모드와
    /// 무관하게 항상 그대로 그려진다.
    private static func normalizeToRGBA8(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func advanceSplash() {
        guard materials.count > 1, let imagePlane else { return }
        swapIndex = (swapIndex + 1) % materials.count
        imagePlane.model?.materials = [materials[swapIndex]]
    }

    /// 모든 프리로드가 끝나면 호출해 화면을 걷어낸다.
    func remove() {
        loadTask?.cancel()
        loadTask = nil
        swapTask?.cancel()
        swapTask = nil
        anchor?.removeFromParent()
        anchor = nil
        imagePlane = nil
        materials = []
    }
}
