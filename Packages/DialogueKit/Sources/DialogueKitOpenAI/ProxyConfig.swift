import Foundation

/// 프록시 엔드포인트(키 없음). base = 배포된 CloudFlare Worker URL.
public struct ProxyConfig: Sendable {
    public let realtimeTokenURL: URL
    public init(base: URL) {
        realtimeTokenURL = base.appending(path: "realtime-token")
    }
}
