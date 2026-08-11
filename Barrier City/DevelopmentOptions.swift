import Foundation

/// 시뮬레이터에서만 사용하는 개발 옵션.
enum DevelopmentOptions {
    static let simulatorMicrophoneKey = "development.simulatorMicrophoneEnabled"

    static var simulatorMicrophoneEnabled: Bool {
#if targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: simulatorMicrophoneKey)
#else
        false
#endif
    }
}
