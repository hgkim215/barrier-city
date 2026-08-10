//
//  RealtimeAudioIO.swift
//  Barrier City
//
//  Realtime API가 요구하는 mono PCM16/24kHz 마이크 스트림과
//  서버가 보내는 PCM16/24kHz 음성 재생을 하나의 voice-chat 세션에서 처리한다.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class RealtimeAudioIO {
    enum AudioError: LocalizedError {
        case permissionDenied
        case inputUnavailable
        case converterUnavailable
        case simulatorUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "마이크 권한이 필요합니다."
            case .inputUnavailable:
                "현재 오디오 입력을 사용할 수 없습니다."
            case .converterUnavailable:
                "마이크 오디오를 Realtime 형식으로 변환할 수 없습니다."
            case .simulatorUnavailable:
                "visionOS 시뮬레이터에서는 Realtime 마이크를 사용할 수 없습니다."
            }
        }
    }

    static let sampleRate: Double = 24_000

    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private lazy var playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: Self.sampleRate,
        channels: 1
    )!
    private var isInputTapInstalled = false
    private var isPlayerAttached = false
    private var outputStartedAt: ContinuousClock.Instant?
    private var receivedOutputFrames = 0
    private(set) var isRunning = false

    /// Audio I/O를 시작한다. 콜백은 Core Audio 스레드에서 호출되므로 전달받은 Data를
    /// 즉시 비동기 큐/스트림으로 넘기고 콜백 안에서 네트워크를 기다리면 안 된다.
    func start(onInput: @escaping @Sendable (Data) -> Void) async throws {
#if targetEnvironment(simulator)
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw AudioError.simulatorUnavailable
        }
#endif
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioError.inputUnavailable
        }
        guard let streamFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: streamFormat) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioError.converterUnavailable
        }

        if !isPlayerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            isPlayerAttached = true
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            guard let data = Self.convertInput(
                buffer,
                using: converter,
                outputFormat: streamFormat
            ), !data.isEmpty else { return }
            onInput(data)
        }
        isInputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            isInputTapInstalled = false
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// 서버가 보낸 little-endian PCM16 mono/24kHz chunk를 순서대로 재생한다.
    func enqueueOutput(_ pcm16: Data, beginsResponse: Bool) {
        guard isRunning,
              pcm16.count >= MemoryLayout<Int16>.size,
              let buffer = Self.makePlaybackBuffer(from: pcm16, format: playbackFormat) else {
            return
        }
        if beginsResponse || outputStartedAt == nil {
            outputStartedAt = .now
            receivedOutputFrames = 0
        }
        receivedOutputFrames += Int(buffer.frameLength)
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// 사용자가 NPC 발화 중 끼어들면 아직 재생하지 않은 음성까지 즉시 버린다.
    func interruptOutput() -> Int? {
        guard isPlayerAttached else { return nil }
        let playedMilliseconds: Int?
        if let outputStartedAt {
            let elapsed = outputStartedAt.duration(to: .now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let receivedSeconds = Double(receivedOutputFrames) / Self.sampleRate
            playedMilliseconds = Int(min(elapsedSeconds, receivedSeconds) * 1_000)
        } else {
            playedMilliseconds = nil
        }
        player.stop()
        outputStartedAt = nil
        receivedOutputFrames = 0
        return playedMilliseconds
    }

    func stop() {
        guard isRunning || isInputTapInstalled else { return }
        if isInputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if isPlayerAttached { player.stop() }
        if engine.isRunning { engine.stop() }
        isRunning = false
        outputStartedAt = nil
        receivedOutputFrames = 0
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private static func convertInput(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              status != .error,
              let samples = output.int16ChannelData?[0] else { return nil }

        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }

    private static func makePlaybackBuffer(
        from pcm16: Data,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCount = pcm16.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ), let samples = buffer.floatChannelData?[0] else { return nil }

        pcm16.withUnsafeBytes { bytes in
            for index in 0..<frameCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: low | high)
                samples[index] = Float(sample) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
