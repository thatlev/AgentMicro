import AVFoundation
import Foundation
import Speech

/// On-device push-to-talk for the VS Code control page. The recognized text is
/// inserted into the selected editor target; sending remains a separate key.
@MainActor
final class VoicePromptRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case processing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var delivery: ((String) -> Void)?
    private var deliveryGeneration = 0
    private var wantsRecording = false
    private var recordingLimitTask: Task<Void, Never>?
    private var processingFallbackTask: Task<Void, Never>?
    /// Type-erased because SpeechAnalyzer is iOS 26+. The concrete session is
    /// conditionally cast only inside availability checks.
    private var modernSession: AnyObject?

    var isListening: Bool { phase == .listening }

    func setPressed(_ pressed: Bool, onTranscript: @escaping (String) -> Void) {
        wantsRecording = pressed
        if pressed {
            guard phase != .listening, phase != .requestingPermission else { return }
            delivery = onTranscript
            Task { await begin() }
        } else if phase == .listening {
            finishCapture()
        }
    }

    func resetError() {
        if case .failed = phase { phase = .idle }
    }

    private func begin() async {
        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        transcript = ""
        phase = .requestingPermission

        guard await requestPermissions() else {
            phase = .failed("Allow Microphone and Speech Recognition in Settings.")
            return
        }
        guard wantsRecording else {
            phase = .idle
            delivery = nil
            return
        }
        var modernFailure: Error?
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            do {
                try await beginModern(generation: generation)
                return
            } catch {
                // SpeechAnalyzer uses the new downloadable on-device models
                // and does not depend on the Siri/keyboard Dictation switch.
                // If the locale/model is unavailable, retain the legacy Apple
                // recognizer as a network-capable fallback.
                if let session = modernSession as? ModernSpeechSession {
                    await session.cancel()
                }
                modernSession = nil
                modernFailure = error
                deactivateAudioSession()
            }
        }

        beginLegacy(generation: generation, modernFailure: modernFailure)
    }

    @available(iOS 26.0, *)
    private func beginModern(generation: Int) async throws {
        let session = ModernSpeechSession { [weak self] text in
            guard let self, generation == self.deliveryGeneration else { return }
            self.transcript = text
        }
        modernSession = session
        try await session.start(using: audioEngine)
        guard wantsRecording, generation == deliveryGeneration else {
            await session.cancel()
            modernSession = nil
            phase = .idle
            delivery = nil
            return
        }
        phase = .listening
        armRecordingLimit(generation: generation)
        if !wantsRecording { finishCapture() }
    }

    private func beginLegacy(generation: Int, modernFailure: Error?) {
        guard recognizer?.isAvailable == true else {
            phase = .failed(failureMessage(
                fallback: "Speech recognition is unavailable right now.",
                modernFailure: modernFailure
            ))
            return
        }

        task?.cancel()
        task = nil
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else {
            phase = .failed(failureMessage(
                fallback: "Could not start speech recognition.",
                modernFailure: modernFailure
            ))
            return
        }
        request.shouldReportPartialResults = true
        // Do not force the legacy Siri-backed on-device path. On some devices
        // it reports support but then fails with "Siri and Dictation are
        // disabled". SpeechAnalyzer is our on-device path on iOS 26; this
        // fallback is allowed to use Apple's recognition service.
        request.requiresOnDeviceRecognition = false

        do {
            try activateAudioSession()

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceRecorderError.unavailableInputFormat
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            request.endAudio()
            self.request = nil
            phase = .failed(failureMessage(
                fallback: "Microphone could not start: \(error.localizedDescription)",
                modernFailure: modernFailure
            ))
            return
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.deliveryGeneration else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.deliverAndReset(generation: generation) }
                } else if let error, self.phase != .processing {
                    self.failAndReset(self.recognitionFailureMessage(error, modernFailure: modernFailure))
                }
            }
        }
        phase = .listening
        armRecordingLimit(generation: generation)
        if !wantsRecording { finishCapture() }
    }

    private func finishCapture() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        phase = .processing
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        if #available(iOS 26.0, *), let session = modernSession as? ModernSpeechSession {
            let generation = deliveryGeneration
            armProcessingFallback(generation: generation, delay: 8.0)
            Task {
                let finalText = await session.finish()
                guard generation == deliveryGeneration, phase == .processing else { return }
                if !finalText.isEmpty { transcript = finalText }
                deliverAndReset(generation: generation)
            }
            return
        }

        request?.endAudio()
        let generation = deliveryGeneration

        // Some locales never mark the final partial as final after a very short
        // press. Deliver the best result after a brief settling window.
        Task {
            try? await Task.sleep(for: .milliseconds(1_300))
            guard generation == deliveryGeneration, phase == .processing else { return }
            deliverAndReset(generation: generation)
        }
    }

    private func deliverAndReset(generation: Int) {
        guard generation == deliveryGeneration else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = delivery
        cleanup()
        if !text.isEmpty { callback?(text) }
    }

    private func failAndReset(_ message: String) {
        cleanup(phaseAfter: .failed(message))
    }

    private func cleanup(phaseAfter: Phase = .idle) {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        processingFallbackTask?.cancel()
        processingFallbackTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if #available(iOS 26.0, *), let session = modernSession as? ModernSpeechSession {
            Task { await session.cancel() }
        }
        modernSession = nil
        delivery = nil
        wantsRecording = false
        deactivateAudioSession()
        phase = phaseAfter
    }

    /// A stuck gesture or interrupted touch must never leave the microphone
    /// active indefinitely. Two minutes is intentionally generous for a voice
    /// prompt while still providing a deterministic safety stop.
    private func armRecordingLimit(generation: Int) {
        recordingLimitTask?.cancel()
        recordingLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled,
                  generation == self.deliveryGeneration,
                  self.phase == .listening else { return }
            self.wantsRecording = false
            self.finishCapture()
        }
    }

    /// SpeechAnalyzer normally finalizes immediately after end-of-input, but a
    /// model/daemon failure must not strand the UI in TRANSCRIBING. Deliver the
    /// best text already received (if any) and tear the session down cleanly.
    private func armProcessingFallback(generation: Int, delay: TimeInterval) {
        processingFallbackTask?.cancel()
        processingFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled,
                  generation == self.deliveryGeneration,
                  self.phase == .processing else { return }
            self.deliverAndReset(generation: generation)
        }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? session.setPreferredIOBufferDuration(0.012)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func failureMessage(fallback: String, modernFailure: Error?) -> String {
        guard let modernFailure else { return fallback }
        let detail = modernFailure.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : "iPhone transcription failed: \(detail)"
    }

    private func recognitionFailureMessage(_ error: Error, modernFailure: Error?) -> String {
        let message = error.localizedDescription
        let normalized = message.lowercased()
        if normalized.contains("siri") || normalized.contains("dictation") {
            return failureMessage(
                fallback: "Apple speech recognition is unavailable. Try again while online.",
                modernFailure: modernFailure
            )
        }
        return failureMessage(fallback: message, modernFailure: modernFailure)
    }

    private func requestPermissions() async -> Bool {
        let speechAllowed: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAllowed = true
        case .notDetermined:
            speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            speechAllowed = false
        }
        guard speechAllowed else { return false }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

private enum VoiceRecorderError: LocalizedError {
    case unavailableInputFormat

    var errorDescription: String? {
        switch self {
        case .unavailableInputFormat:
            return "The iPhone microphone did not provide a usable audio format."
        }
    }
}

// MARK: - iOS 26 speech engine

/// SpeechAnalyzer is independent of the Siri/keyboard Dictation preference and
/// uses system-managed downloadable speech assets. It is the primary iPhone
/// fallback whenever a VS Code provider does not expose its own voice command.
@available(iOS 26.0, *)
@MainActor
private final class ModernSpeechSession {
    enum SessionError: LocalizedError {
        case unsupportedLocale
        case unavailableFormat
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "The current language is not supported for on-device transcription."
            case .unavailableFormat: return "No compatible speech audio format is available."
            case .conversionFailed: return "The microphone audio could not be converted for transcription."
            }
        }
    }

    private let onTranscript: (String) -> Void
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var accumulated = ""
    private var resultError: Error?

    init(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
    }

    func start(using audioEngine: AVAudioEngine) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw SessionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SessionError.unavailableFormat
        }

        // Activate the iPhone input route before asking AVAudioEngine for its
        // natural format. Querying it first can return a zero-Hz format after a
        // route change, which made SpeechAnalyzer fail and incorrectly fall
        // back to the Siri-backed recognizer.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? audioSession.setPreferredIOBufferDuration(0.012)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let stream = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = stream.continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.transcriber = transcriber

        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    self.accumulated += text
                    self.onTranscript(self.accumulated)
                }
            } catch {
                self?.resultError = error
            }
        }

        try await analyzer.start(inputSequence: stream.stream)

        let input = audioEngine.inputNode
        let naturalFormat = input.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw SessionError.unavailableFormat
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: analyzerFormat) else {
            throw SessionError.conversionFailed
        }
        let continuation = stream.continuation
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { buffer, _ in
            let ratio = analyzerFormat.sampleRate / max(naturalFormat.sampleRate, 1)
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
                if supplied {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func finish() async -> String {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            resultError = error
        }
        _ = await resultTask?.result
        resultTask = nil
        analyzer = nil
        transcriber = nil
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
    }
}
