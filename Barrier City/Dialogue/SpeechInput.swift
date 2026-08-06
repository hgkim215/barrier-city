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
        case notAuthorized, recognizerUnavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "마이크/음성인식 권한이 필요합니다."
            case .recognizerUnavailable: return "한국어 음성인식을 사용할 수 없습니다."
            }
        }
    }

    /// 실시간 부분 결과(자막/디버그용)
    private(set) var partialText: String = ""
    private(set) var isRecording: Bool = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isInputTapInstalled = false

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
        guard await requestPermission() else { throw STTError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw STTError.recognizerUnavailable }

        partialText = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // 온디바이스 우선(인터넷 불필요)
        }
        self.request = req

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        isInputTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            isInputTapInstalled = false
            self.request = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return partialText
    }
}
