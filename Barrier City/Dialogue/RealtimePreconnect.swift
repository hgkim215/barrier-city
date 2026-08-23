import DialogueKitOpenAI
import Foundation

/// 몰입 공간 진입 시 OpenAI Realtime WebRTC 연결을 미리 열어둔다. 토큰 발급과
/// SDP/ICE 협상이 대화 시작 전에 끝나 있으면, 유저가 실제로 NPC에게 처음 말을
/// 걸 때 연결 지연 없이 바로 시작할 수 있다.
///
/// 실패해도 조용히 넘어간다 — 대화 시작 시 RealtimeNPCConversationSession이
/// 평소대로 새 클라이언트를 만들어 다시 연결을 시도한다.
@MainActor
final class RealtimePreconnect {
    static let shared = RealtimePreconnect()

    private var connectedClient: RealtimeWebRTCClient?
    private var isPreconnecting = false

    private init() {}

    func preconnect() async {
        guard connectedClient == nil, !isPreconnecting else { return }
        isPreconnecting = true
        defer { isPreconnecting = false }

        let client = RealtimeWebRTCClient(config: AppConfig.proxy)
        do {
            try await client.connect()
            connectedClient = client
        } catch {
            // 조용히 무시. 실제 대화 시작 시 새 클라이언트로 다시 시도한다.
        }
    }

    /// 대화를 시작할 때 미리 연결된 클라이언트를 한 번 소비한다. 없으면 nil을
    /// 반환해 호출부가 평소대로 새 클라이언트를 만들게 한다.
    func takeClient() -> RealtimeWebRTCClient? {
        defer { connectedClient = nil }
        return connectedClient
    }
}
