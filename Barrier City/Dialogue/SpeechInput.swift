//
//  SpeechInput.swift
//  WheelchairXR
//
//  T4 — 온디바이스 한국어 STT (push-to-talk).
//  실기(Vision Pro) 전용: 마이크·음성인식은 시뮬레이터에서 동작하지 않음.
//  Info.plist 필요 키: Privacy - Microphone / Privacy - Speech Recognition (A3에서 추가됨).
//
//  구현 메모: 안정적인 SFSpeechRecognizer(온디바이스 한국어)로 베이스라인.
//  스펙 목표인 visionOS 26 SpeechTranscriber로는 동일 인터페이스 유지한 채 추후 교체 가능.
//

import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
final class SpeechInput {
    enum STTError: LocalizedError {
        case notAuthorized, recognizerUnavailable, inputUnavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "마이크/음성인식 권한이 필요합니다."
            case .recognizerUnavailable: return "한국어 음성인식을 사용할 수 없습니다."
            case .inputUnavailable: return "현재 환경에서는 마이크 입력을 사용할 수 없습니다."
            }
        }
    }

    /// 실시간 부분 결과(자막/디버그용)
    private(set) var partialText: String = ""
    private(set) var isRecording: Bool = false
    private(set) var inputLevel: Float = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    /// Simulator에서는 생성 자체가 CoreAudio 채널 경고를 낼 수 있어 실제 녹음 시점까지 지연한다.
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var inputLevelTask: Task<Void, Never>?
    @ObservationIgnored private var inputLevelContinuation: AsyncStream<Float>.Continuation?
    @ObservationIgnored private let inputLevelSampler = MicrophoneLevelSampler()
    private var isInputTapInstalled = false
    private var hasAudioSessionClaim = false

    /// 음성인식 + 마이크 권한 요청
    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    /// push-to-talk 시작 — 누르고 있는 동안 부분 결과가 partialText로 흐른다.
    func start() async throws {
#if targetEnvironment(simulator)
        // 기본값은 안전하게 차단하고, 개발 패널에서 명시적으로 켠 경우에만 Mac의
        // 마이크 입력을 시도한다. 실제 입력 가능 여부는 아래 포맷 검사에서 다시 확인한다.
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw STTError.inputUnavailable
        }
#endif
        guard await requestPermission() else { throw STTError.notAuthorized }
        try Task.checkCancellation()
        guard let recognizer, recognizer.isAvailable else { throw STTError.recognizerUnavailable }

        partialText = ""
        inputLevel = 0
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // 온디바이스 우선(인터넷 불필요)
        }
        self.request = req

        try AudioSessionCoordinator.shared.acquire(.recording)
        hasAudioSessionClaim = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.request = nil
            releaseAudioSessionClaim()
            throw STTError.inputUnavailable
        }
        let inputLevels = AsyncStream.makeStream(
            of: Float.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        inputLevelContinuation = inputLevels.continuation
        inputLevelTask = Task { @MainActor [weak self] in
            for await level in inputLevels.stream {
                guard !Task.isCancelled else { return }
                self?.inputLevel = level
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak req, inputLevelSampler, levelContinuation = inputLevels.continuation] buffer, _ in
            req?.append(buffer)
            if let level = inputLevelSampler.consume(buffer) {
                levelContinuation.yield(level)
            }
        }
        isInputTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            isInputTapInstalled = false
            self.request = nil
            stopInputLevelUpdates()
            releaseAudioSessionClaim()
            throw error
        }
        isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            self.partialText = result.bestTranscription.formattedString
        }
    }

    /// 음성인식 권한만 요청(파일 인식은 마이크 불필요).
    func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// 오디오 파일을 STT로 인식 — 시뮬레이터에서도 동작(마이크 불필요).
    /// 라이브 마이크 경로(start/stop)를 못 쓰는 환경에서 인식 파이프라인 검증용.
    func transcribeFile(_ url: URL) async throws -> String {
        guard await requestSpeechAuth() else { throw STTError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw STTError.recognizerUnavailable }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var resumed = false
            recognizer.recognitionTask(with: req) { result, error in
                if resumed { return }
                if let error { resumed = true; cont.resume(throwing: error); return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    /// push-to-talk 종료 — 확정 텍스트 반환.
    @discardableResult
    func stop() async -> String {
        if isInputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        isRecording = false
        stopInputLevelUpdates()
        releaseAudioSessionClaim()
        return partialText
    }

    private func releaseAudioSessionClaim() {
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.recording)
    }

    private func stopInputLevelUpdates() {
        inputLevelContinuation?.finish()
        inputLevelContinuation = nil
        inputLevelTask?.cancel()
        inputLevelTask = nil
        inputLevelSampler.reset()
        inputLevel = 0
    }
}
