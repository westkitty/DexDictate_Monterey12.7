import AVFoundation
import Foundation
import SwiftWhisper

private let targetSampleRate: Double = 16_000

private enum ProbeError: LocalizedError {
    case usage(String)
    case audio(String)
    case microphone(String)
    case transcription(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .audio(let message), .microphone(let message), .transcription(let message):
            return message
        }
    }
}

private struct ProbeResult {
    let mode: String
    let status: String
    let message: String
    let transcript: String
    let normalizedExpected: String
    let normalizedActual: String
    let wordErrorRate: Double?
    let matchedWords: Int
    let expectedWords: Int
    let loadMilliseconds: Double?
    let transcriptionMilliseconds: Double?
    let totalMilliseconds: Double
    let frameCount: Int
    let rms: Double?

    func json() -> String {
        let wer = wordErrorRate.map { String(format: "%.6f", $0) } ?? "null"
        let load = loadMilliseconds.map { String(format: "%.3f", $0) } ?? "null"
        let transcription = transcriptionMilliseconds.map { String(format: "%.3f", $0) } ?? "null"
        let rmsValue = rms.map { String(format: "%.8f", $0) } ?? "null"
        let total = String(format: "%.3f", totalMilliseconds)
        return "{\"mode\":\(quote(mode)),\"status\":\(quote(status)),\"message\":\(quote(message)),\"transcript\":\(quote(transcript)),\"normalized_expected\":\(quote(normalizedExpected)),\"normalized_actual\":\(quote(normalizedActual)),\"word_error_rate\":\(wer),\"matched_words\":\(matchedWords),\"expected_words\":\(expectedWords),\"model_load_ms\":\(load),\"transcription_ms\":\(transcription),\"total_ms\":\(total),\"frame_count\":\(frameCount),\"rms\":\(rmsValue)}"
    }
}

private func quote(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

private func monotonicMilliseconds() -> Double {
    ProcessInfo.processInfo.systemUptime * 1_000
}

private func normalizedWords(_ input: String) -> [String] {
    input.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
        result.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
    }.split(whereSeparator: { $0 == " " }).map(String.init)
}

private func wordDistance(_ lhs: [String], _ rhs: [String]) -> Int {
    var previous = Array(0...rhs.count)
    for (leftIndex, left) in lhs.enumerated() {
        var current = [leftIndex + 1]
        for (rightIndex, right) in rhs.enumerated() {
            current.append(min(
                previous[rightIndex + 1] + 1,
                current[rightIndex] + 1,
                previous[rightIndex] + (left == right ? 0 : 1)
            ))
        }
        previous = current
    }
    return previous[rhs.count]
}

private func positionalMatches(_ expected: [String], _ actual: [String]) -> Int {
    zip(expected, actual).filter { $0 == $1 }.count
}

private func convertToWhisperFrames(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    guard inputFormat.sampleRate > 0 else { throw ProbeError.audio("Input audio has no sample rate.") }
    guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw ProbeError.audio("Unable to create a 16 kHz mono AVFoundation converter.")
    }
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw ProbeError.audio("Unable to allocate input audio buffer.")
    }
    try file.read(into: inputBuffer)
    guard inputBuffer.frameLength > 0 else { throw ProbeError.audio("Input audio contains zero frames.") }
    let outputCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * targetSampleRate / inputFormat.sampleRate).rounded(.up) + 4_096)
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
        throw ProbeError.audio("Unable to allocate converted audio buffer.")
    }
    var suppliedInput = false
    var conversionError: NSError?
    let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
        if suppliedInput {
            status.pointee = .endOfStream
            return nil
        }
        suppliedInput = true
        status.pointee = .haveData
        return inputBuffer
    }
    guard conversionStatus != .error, conversionError == nil else {
        throw ProbeError.audio("AVFoundation conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
    }
    guard outputBuffer.frameLength > 0, let channels = outputBuffer.floatChannelData else {
        throw ProbeError.audio("AVFoundation conversion returned zero Float32 frames.")
    }
    return Array(UnsafeBufferPointer(start: channels[0], count: Int(outputBuffer.frameLength)))
}

private func rms(_ frames: [Float]) -> Double {
    guard !frames.isEmpty else { return 0 }
    let sum = frames.reduce(0.0) { $0 + Double($1) * Double($1) }
    return sqrt(sum / Double(frames.count))
}

private func transcribe(modelPath: String, frames: [Float], expected: String, mode: String, signalRMS: Double? = nil) -> ProbeResult {
    let totalStart = monotonicMilliseconds()
    let expectedWords = normalizedWords(expected)
    guard !frames.isEmpty else {
        return ProbeResult(mode: mode, status: "FAIL", message: "Zero audio frames.", transcript: "", normalizedExpected: expectedWords.joined(separator: " "), normalizedActual: "", wordErrorRate: nil, matchedWords: 0, expectedWords: expectedWords.count, loadMilliseconds: nil, transcriptionMilliseconds: nil, totalMilliseconds: monotonicMilliseconds() - totalStart, frameCount: 0, rms: signalRMS)
    }
    let loadStart = monotonicMilliseconds()
    let params = WhisperParams(strategy: .greedy)
    params.language = .english
    let whisper = Whisper(fromFileURL: URL(fileURLWithPath: modelPath), withParams: params)
    let loadMilliseconds = monotonicMilliseconds() - loadStart
    var result: Result<[Segment], Error>?
    let completed = DispatchSemaphore(value: 0)
    let transcriptionStart = monotonicMilliseconds()
    whisper.transcribe(audioFrames: frames) { callbackResult in
        result = callbackResult
        completed.signal()
    }
    while completed.wait(timeout: .now()) != .success {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    let transcriptionMilliseconds = monotonicMilliseconds() - transcriptionStart
    let totalMilliseconds = monotonicMilliseconds() - totalStart
    switch result {
    case .success(let segments):
        let transcript = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let actualWords = normalizedWords(transcript)
        let distance = wordDistance(expectedWords, actualWords)
        let wer = expectedWords.isEmpty ? nil : Double(distance) / Double(expectedWords.count)
        let matches = positionalMatches(expectedWords, actualWords)
        // Deterministic speech has a fixed, deliberately strict gate. Live speech does not:
        // microphone hardware is proven by capture, signal energy, conversion, and plausible output.
        let passed: Bool
        let message: String
        if mode == "microphone" {
            passed = actualWords.count >= 2 && transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
            message = passed ? "Captured non-silent microphone audio produced a plausible transcript; phrase similarity is diagnostic only." : "Microphone audio did not produce a plausible transcript."
        } else {
            passed = !actualWords.isEmpty && (wer ?? 1) <= 0.35 && matches >= max(3, expectedWords.count / 2)
            message = passed ? "Transcript met the fixed deterministic threshold." : "Transcript did not meet the fixed deterministic threshold (WER <= 0.35 and >= 50% positional word matches)."
        }
        return ProbeResult(mode: mode, status: passed ? "PASS" : "FAIL", message: message, transcript: transcript, normalizedExpected: expectedWords.joined(separator: " "), normalizedActual: actualWords.joined(separator: " "), wordErrorRate: wer, matchedWords: matches, expectedWords: expectedWords.count, loadMilliseconds: loadMilliseconds, transcriptionMilliseconds: transcriptionMilliseconds, totalMilliseconds: totalMilliseconds, frameCount: frames.count, rms: signalRMS)
    case .failure(let error):
        return ProbeResult(mode: mode, status: "FAIL", message: "SwiftWhisper transcribe failed: \(error.localizedDescription)", transcript: "", normalizedExpected: expectedWords.joined(separator: " "), normalizedActual: "", wordErrorRate: nil, matchedWords: 0, expectedWords: expectedWords.count, loadMilliseconds: loadMilliseconds, transcriptionMilliseconds: transcriptionMilliseconds, totalMilliseconds: totalMilliseconds, frameCount: frames.count, rms: signalRMS)
    case .none:
        return ProbeResult(mode: mode, status: "FAIL", message: "SwiftWhisper did not return a result.", transcript: "", normalizedExpected: expectedWords.joined(separator: " "), normalizedActual: "", wordErrorRate: nil, matchedWords: 0, expectedWords: expectedWords.count, loadMilliseconds: loadMilliseconds, transcriptionMilliseconds: transcriptionMilliseconds, totalMilliseconds: totalMilliseconds, frameCount: frames.count, rms: signalRMS)
    }
}

private final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var captured: [Float] = []

    func capture(seconds: TimeInterval) throws -> ([Float], Double) {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ProbeError.microphone("The default input device has an unusable format.")
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let values = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            self?.lock.lock()
            self?.captured.append(contentsOf: values)
            self?.lock.unlock()
        }
        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        try engine.start()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        lock.lock()
        let samples = captured
        lock.unlock()
        guard !samples.isEmpty else { throw ProbeError.microphone("Microphone capture produced zero audio frames.") }
        let signalRMS = rms(samples)
        guard signalRMS > 0.0005 else { throw ProbeError.microphone("Microphone capture was effectively silent (RMS \(signalRMS)).") }
        guard let capturedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: capturedFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: capturedFormat, to: outputFormat) else {
            throw ProbeError.microphone("Unable to configure microphone format conversion.")
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            sourceBuffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * targetSampleRate / inputFormat.sampleRate).rounded(.up) + 4_096)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ProbeError.microphone("Unable to allocate converted microphone buffer.")
        }
        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return sourceBuffer
        }
        guard conversionStatus != .error, conversionError == nil, outputBuffer.frameLength > 0, let channels = outputBuffer.floatChannelData else {
            throw ProbeError.microphone("Microphone conversion to 16 kHz mono failed: \(conversionError?.localizedDescription ?? "unknown error")")
        }
        return (Array(UnsafeBufferPointer(start: channels[0], count: Int(outputBuffer.frameLength))), signalRMS)
    }
}

private func option(_ name: String, from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func write(_ result: ProbeResult, to path: String?) {
    print("PROBE_STATUS=\(result.status)")
    print("PROBE_MODE=\(result.mode)")
    print("PROBE_MESSAGE=\(result.message)")
    print("PROBE_TRANSCRIPT=\(result.transcript)")
    let wer = result.wordErrorRate.map { String(format: "%.6f", $0) } ?? "null"
    print("PROBE_WER=\(wer)")
    if let path = path {
        do {
            try result.json().write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            fputs("Could not write result JSON: \(error.localizedDescription)\n", stderr)
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let resultPath = option("--result", from: arguments)
let mode = arguments.first ?? ""
let expected = option("--expected", from: arguments) ?? "The quick brown fox jumps over the lazy dog. This is a Monterey compatibility test."
let modelPath = option("--model", from: arguments)

do {
    guard let modelPath = modelPath else { throw ProbeError.usage("Missing --model path.") }
    let result: ProbeResult
    switch mode {
    case "transcribe":
        guard let audioPath = option("--audio", from: arguments) else { throw ProbeError.usage("Missing --audio path.") }
        result = transcribe(modelPath: modelPath, frames: try convertToWhisperFrames(from: URL(fileURLWithPath: audioPath)), expected: expected, mode: mode)
    case "microphone":
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted = allowed
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) != .success {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard granted else { throw ProbeError.microphone("MIC_PERMISSION_BLOCKED") }
        } else if permission != .authorized {
            throw ProbeError.microphone("MIC_PERMISSION_BLOCKED")
        }
        let duration = TimeInterval(option("--seconds", from: arguments).flatMap(Double.init) ?? 7)
        let capture = MicrophoneCapture()
        let (frames, signalRMS) = try capture.capture(seconds: duration)
        result = transcribe(modelPath: modelPath, frames: frames, expected: expected, mode: mode, signalRMS: signalRMS)
    default:
        throw ProbeError.usage("Usage: MontereyWhisperProbe transcribe --model PATH --audio PATH [--expected TEXT] [--result PATH] | microphone --model PATH [--seconds 7] [--expected TEXT] [--result PATH]")
    }
    write(result, to: resultPath)
    exit(result.status == "PASS" ? 0 : 2)
} catch {
    let failed = ProbeResult(mode: mode.isEmpty ? "unknown" : mode, status: "FAIL", message: error.localizedDescription, transcript: "", normalizedExpected: normalizedWords(expected).joined(separator: " "), normalizedActual: "", wordErrorRate: nil, matchedWords: 0, expectedWords: normalizedWords(expected).count, loadMilliseconds: nil, transcriptionMilliseconds: nil, totalMilliseconds: 0, frameCount: 0, rms: nil)
    write(failed, to: resultPath)
    exit(1)
}
