@preconcurrency import AVFoundation
import Foundation

/// Core Audio 입력 버퍼의 RMS를 UI용 0...1 감도 값으로 변환한다.
/// 오디오 콜백 스레드에서 호출되므로 상태는 잠금으로 보호하고 15Hz로 게시를 제한한다.
nonisolated final class MicrophoneLevelSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var smoothedLevel: Float = 0
    private var lastPublishedAt: TimeInterval = 0

    func consume(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let rawLevel = Self.normalizedRMS(buffer) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }

        // 말이 시작될 때는 빠르게, 끝날 때는 부드럽게 내려가도록 attack/release를 다르게 둔다.
        let response: Float = rawLevel > smoothedLevel ? 0.48 : 0.18
        smoothedLevel += (rawLevel - smoothedLevel) * response
        guard now - lastPublishedAt >= 1.0 / 15.0 else { return nil }
        lastPublishedAt = now
        return smoothedLevel
    }

    func reset() {
        lock.lock()
        smoothedLevel = 0
        lastPublishedAt = 0
        lock.unlock()
    }

    private static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return nil }

        let sumOfSquares: Double
        let sampleCount: Int
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            let planes = buffer.format.isInterleaved ? 1 : channels
            let samplesPerPlane = buffer.format.isInterleaved ? frames * channels : frames
            var sum = 0.0
            for plane in 0..<planes {
                for index in 0..<samplesPerPlane {
                    let sample = Double(data[plane][index])
                    sum += sample * sample
                }
            }
            sumOfSquares = sum
            sampleCount = planes * samplesPerPlane

        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            let planes = buffer.format.isInterleaved ? 1 : channels
            let samplesPerPlane = buffer.format.isInterleaved ? frames * channels : frames
            var sum = 0.0
            for plane in 0..<planes {
                for index in 0..<samplesPerPlane {
                    let sample = Double(data[plane][index]) / 32_768.0
                    sum += sample * sample
                }
            }
            sumOfSquares = sum
            sampleCount = planes * samplesPerPlane

        default:
            return nil
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        // 일반적인 음성 범위인 -60dB...-12dB를 게이지 전체 폭에 대응시킨다.
        return Float(max(0, min(1, (decibels + 60) / 48)))
    }
}
