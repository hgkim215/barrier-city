import AVFoundation
import Observation
import SwiftUI
import UIKit

@Observable @MainActor
private final class LoopingGuidePlayback {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
    }

    func play() { player.play() }

    func stop() {
        looper?.disableLooping()
        player.pause()
        looper = nil
    }
}

/// AVPlayerLayer를 직접 얹는 최소 호스트.
///
/// AVKit의 `VideoPlayer`는 재생/10초 이동/진행바 같은 transport 컨트롤을 항상
/// 그리고, 이를 끄는 API가 없다. `allowsHitTesting(false)`는 입력만 막을 뿐
/// 오버레이는 남아서 조작 안내 영상 위에 재생 버튼이 겹쳐 보였다.
/// 레이어를 직접 사용해 영상 프레임만 그린다.
private final class GuideVideoHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct GuideVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> GuideVideoHostView {
        let view = GuideVideoHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: GuideVideoHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ uiView: GuideVideoHostView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

struct LoopingGuideVideoView: View {
    let resourceName: String
    let placeholderResourceName: String?
    @State private var playback: LoopingGuidePlayback?

    init(
        resourceName: String,
        placeholderResourceName: String? = "onboarding-placeholder"
    ) {
        self.resourceName = resourceName
        self.placeholderResourceName = placeholderResourceName
    }

    var body: some View {
        Group {
            if let playback {
                GuideVideoSurface(player: playback.player)
            } else {
                ContentUnavailableView(
                    "영상 준비 중",
                    systemImage: "video.slash",
                    description: Text("조작 가이드 영상이 준비되면 자동으로 표시됩니다."))
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .accessibilityHidden(true)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: resourceName) { _, _ in
            stop()
            start()
        }
    }

    private func start() {
        let placeholderURL = placeholderResourceName.flatMap {
            Bundle.main.url(forResource: $0, withExtension: "mp4")
        }
        let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4")
            ?? placeholderURL
        guard let url else { return }
        let next = LoopingGuidePlayback(url: url)
        playback = next
        next.play()
    }

    private func stop() {
        playback?.stop()
        playback = nil
    }
}
