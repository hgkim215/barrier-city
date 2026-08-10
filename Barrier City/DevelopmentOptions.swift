import Foundation

/// 불안정할 수 있는 시뮬레이터 기능을 기본 동작과 분리한다.
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
