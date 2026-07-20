import Accelerate
import AVFoundation
import Foundation

struct AudioSpectrumPeak: Codable, Equatable, Sendable {
    let frequencyHz: Double
    let magnitudeDB: Double
}

struct AudioSignalAnalysis: Codable, Equatable, Sendable {
    let stage: AudioSignalStage
    let sequence: UInt64
    let hostTime: UInt64
    let droppedFrames: UInt64
    let frameCount: UInt32
    let channelCount: UInt32
    let sampleRate: Double
    let rms: Float
    let rmsDBFS: Double
    let peak: Float
    let peakDBFS: Double
    let dominantFrequencyHz: Double
    let spectrumPeaks: [AudioSpectrumPeak]
}

struct AudioSignalAnalyzer: Sendable {
    func analyze(_ window: AudioSignalProbeWindow) -> AudioSignalAnalysis? {
        let channels = Int(window.channelCount)
        let frames = Int(window.frameCount)
        guard channels > 0, frames >= 2, window.sampleRate > 0,
              window.samples.count == channels * frames else { return nil }

        var rms: Float = 0
        var peak: Float = 0
        window.samples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(samples.count))
            vDSP_maxmgv(baseAddress, 1, &peak, vDSP_Length(samples.count))
        }

        let transformLength = largestPowerOfTwo(notExceeding: frames)
        guard transformLength >= 2,
              let setup = vDSP_DFT_zop_CreateSetup(
                  nil, vDSP_Length(transformLength), vDSP_DFT_Direction.FORWARD
              ) else { return nil }
        defer { vDSP_DFT_DestroySetup(setup) }

        var real = [Float](repeating: 0, count: transformLength)
        let imaginary = [Float](repeating: 0, count: transformLength)
        for frame in 0..<transformLength {
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += window.samples[frame * channels + channel]
            }
            let hann = transformLength == 1
                ? 1.0
                : 0.5 - 0.5 * cos(2 * Double.pi * Double(frame) / Double(transformLength - 1))
            real[frame] = mixed / Float(channels) * Float(hann)
        }
        var outputReal = [Float](repeating: 0, count: transformLength)
        var outputImaginary = [Float](repeating: 0, count: transformLength)
        real.withUnsafeBufferPointer { realBuffer in
            imaginary.withUnsafeBufferPointer { imaginaryBuffer in
                outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        vDSP_DFT_Execute(
                            setup,
                            realBuffer.baseAddress!, imaginaryBuffer.baseAddress!,
                            outputRealBuffer.baseAddress!, outputImaginaryBuffer.baseAddress!
                        )
                    }
                }
            }
        }

        let peaks = (1..<(transformLength / 2)).map { index -> AudioSpectrumPeak in
            let magnitude = hypot(outputReal[index], outputImaginary[index]) / Float(transformLength)
            return AudioSpectrumPeak(
                frequencyHz: Double(index) * window.sampleRate / Double(transformLength),
                magnitudeDB: decibels(Double(magnitude))
            )
        }
        .sorted { $0.magnitudeDB > $1.magnitudeDB }
        .prefix(5)

        return AudioSignalAnalysis(
            stage: window.stage,
            sequence: window.sequence,
            hostTime: window.hostTime,
            droppedFrames: window.droppedFrames,
            frameCount: window.frameCount,
            channelCount: window.channelCount,
            sampleRate: window.sampleRate,
            rms: rms,
            rmsDBFS: decibels(Double(rms)),
            peak: peak,
            peakDBFS: decibels(Double(peak)),
            dominantFrequencyHz: peaks.first?.frequencyHz ?? 0,
            spectrumPeaks: Array(peaks)
        )
    }

    private func largestPowerOfTwo(notExceeding value: Int) -> Int {
        1 << (Int.bitWidth - 1 - value.leadingZeroBitCount)
    }

    private func decibels(_ value: Double) -> Double {
        value > 0 ? 20 * log10(value) : -.infinity
    }
}

struct AudioOutputIsolationSignalAnalyzer: Sendable {
    private let decibelFloor = -160.0

    func compare(
        capture: AudioOutputIsolationSignalWindow,
        challenge: AudioOutputIsolationChallenge,
        drainFaultFlags: UInt32
    ) throws -> AudioOutputIsolationAttribution {
        guard let captureAnalysis = analyze(capture, challenge: challenge) else {
            throw AudioOutputIsolationError.signalCaptureDidNotComplete(.challengeCapture)
        }

        let correlationThreshold = 0.75
        let minimumEstimatedGain = 0.05
        let expectedFrames = UInt32(min(
            Double(UInt32.max),
            Double(challenge.samples.count) * capture.sampleRate / challenge.sampleRate
        ))
        let minimumComparedFrames = UInt32(Double(expectedFrames) * 0.9)

        let verdict: AudioOutputIsolationRecaptureVerdict
        let reason: String
        if drainFaultFlags != 0 {
            verdict = .inconclusive
            reason = "The raw Tap drain reported malformed or unsupported callback data."
        } else if captureAnalysis.droppedFrames > 0 {
            verdict = .inconclusive
            reason = "The bounded Tap waveform buffer dropped frames."
        } else if captureAnalysis.challengeComparedFrames < minimumComparedFrames {
            verdict = .inconclusive
            reason = "The Tap capture did not contain enough of the nonce-coded challenge."
        } else if captureAnalysis.challengeCorrelation >= correlationThreshold,
                  captureAnalysis.estimatedGain >= minimumEstimatedGain {
            verdict = .detected
            reason = "The Tap capture matched the nonce-coded output challenge."
        } else if captureAnalysis.challengeCorrelation >= correlationThreshold {
            verdict = .inconclusive
            reason = "The challenge correlation was high but its measured gain was too small."
        } else {
            verdict = .notDetected
            reason = "The Tap capture did not match the nonce-coded output challenge."
        }

        return AudioOutputIsolationAttribution(
            capture: captureAnalysis,
            challengeSeed: challenge.seed,
            challengeCarrierFrequencyHz: challenge.carrierFrequencyHz,
            challengeFrameCount: UInt32(challenge.samples.count),
            correlationThreshold: correlationThreshold,
            minimumEstimatedGain: minimumEstimatedGain,
            drainFaultFlags: drainFaultFlags,
            verdict: verdict,
            reason: reason
        )
    }

    private func analyze(
        _ window: AudioOutputIsolationSignalWindow,
        challenge: AudioOutputIsolationChallenge
    ) -> AudioOutputIsolationSignalAnalysis? {
        let channels = Int(window.channelCount)
        let frames = Int(window.frameCount)
        guard channels > 0, frames >= 2, window.sampleRate > 0,
              challenge.sampleRate > 0, !challenge.samples.isEmpty,
              window.samples.count == channels * frames else { return nil }

        var mono = [Double](repeating: 0, count: frames)
        for frame in 0..<frames {
            let base = frame * channels
            var sum = 0.0
            for channel in 0..<channels {
                sum += Double(window.samples[base + channel])
            }
            mono[frame] = sum / Double(channels)
        }
        let mean = mono.reduce(0, +) / Double(frames)
        var squaredSum = 0.0
        var peak = 0.0
        for frame in 0..<frames {
            let sample = mono[frame] - mean
            mono[frame] = sample
            squaredSum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(squaredSum / Double(frames))
        let reference = resample(
            challenge.samples.map(Double.init),
            from: challenge.sampleRate,
            to: window.sampleRate
        )
        let match = maximumCorrelation(reference: reference, capture: mono)

        return AudioOutputIsolationSignalAnalysis(
            phase: window.phase,
            sequence: window.sequence,
            firstHostTime: window.firstHostTime,
            droppedFrames: window.droppedFrames,
            frameCount: window.frameCount,
            channelCount: window.channelCount,
            sampleRate: window.sampleRate,
            rms: rms,
            rmsDBFS: decibels(rms),
            peak: peak,
            peakDBFS: decibels(peak),
            challengeCorrelation: match.correlation,
            challengeLagFrames: Int64(match.lagFrames),
            challengeComparedFrames: UInt32(match.comparedFrames),
            estimatedGain: match.gain,
            estimatedGainDB: decibels(match.gain)
        )
    }

    private func resample(_ samples: [Double], from sourceRate: Double, to targetRate: Double) -> [Double] {
        guard abs(sourceRate - targetRate) >= 0.5 else { return samples }
        let count = max(2, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
        return (0..<count).map { targetIndex in
            let sourcePosition = Double(targetIndex) * sourceRate / targetRate
            let lower = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = sourcePosition - Double(lower)
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    private func maximumCorrelation(
        reference: [Double],
        capture: [Double]
    ) -> (correlation: Double, lagFrames: Int, comparedFrames: Int, gain: Double) {
        guard reference.count >= 2, capture.count >= reference.count else {
            return (0, 0, min(reference.count, capture.count), 0)
        }
        let maximumLag = capture.count - reference.count
        var bestLag = 0
        var best = (correlation: 0.0, gain: 0.0)
        for lag in stride(from: 0, through: maximumLag, by: 8) {
            let value = correlation(reference: reference, capture: capture, lag: lag, stride: 16)
            if value.correlation > best.correlation {
                best = value
                bestLag = lag
            }
        }
        let refinementLower = max(0, bestLag - 16)
        let refinementUpper = min(maximumLag, bestLag + 16)
        for lag in refinementLower...refinementUpper {
            let value = correlation(reference: reference, capture: capture, lag: lag, stride: 4)
            if value.correlation > best.correlation {
                best = value
                bestLag = lag
            }
        }
        best = correlation(reference: reference, capture: capture, lag: bestLag, stride: 1)
        return (best.correlation, bestLag, reference.count, best.gain)
    }

    private func correlation(
        reference: [Double],
        capture: [Double],
        lag: Int,
        stride sampleStride: Int
    ) -> (correlation: Double, gain: Double) {
        var count = 0.0
        var referenceSum = 0.0
        var captureSum = 0.0
        var referenceSquareSum = 0.0
        var captureSquareSum = 0.0
        var productSum = 0.0
        for index in stride(from: 0, to: reference.count, by: sampleStride) {
            let referenceSample = reference[index]
            let captureSample = capture[lag + index]
            count += 1
            referenceSum += referenceSample
            captureSum += captureSample
            referenceSquareSum += referenceSample * referenceSample
            captureSquareSum += captureSample * captureSample
            productSum += referenceSample * captureSample
        }
        guard count > 1 else { return (0, 0) }
        let covariance = productSum - referenceSum * captureSum / count
        let referenceVariance = referenceSquareSum - referenceSum * referenceSum / count
        let captureVariance = captureSquareSum - captureSum * captureSum / count
        guard referenceVariance > 0, captureVariance > 0 else { return (0, 0) }
        let normalized = abs(covariance / sqrt(referenceVariance * captureVariance))
        return (min(1, normalized), abs(covariance / referenceVariance))
    }

    private func decibels(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return decibelFloor }
        return max(decibelFloor, 20 * log10(value))
    }
}

protocol AudioOutputIsolationEvidenceRecording: Sendable {
    func record(
        challenge: AudioOutputIsolationChallenge,
        capture: AudioOutputIsolationSignalWindow,
        attribution: AudioOutputIsolationAttribution,
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async
}

actor AudioOutputIsolationEvidenceRecorder: AudioOutputIsolationEvidenceRecording {
    static let shared = AudioOutputIsolationEvidenceRecorder()

    private let directoryURL: URL?
    private let sessionID: String
    private let encoder: JSONEncoder

    init(
        directoryURL: URL? = AudioOutputIsolationEvidenceRecorder.defaultDirectoryURL(),
        sessionID: String = AudioDebugSession.id
    ) {
        self.directoryURL = directoryURL
        self.sessionID = sessionID
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func record(
        challenge: AudioOutputIsolationChallenge,
        capture: AudioOutputIsolationSignalWindow,
        attribution: AudioOutputIsolationAttribution,
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async {
        await logger.log("isolation.signal.attribution", generation: generation, fields: [
            "challengeSeed": "\(attribution.challengeSeed)",
            "challengeCorrelation": "\(attribution.capture.challengeCorrelation)",
            "challengeLagFrames": "\(attribution.capture.challengeLagFrames)",
            "estimatedGainDB": "\(attribution.capture.estimatedGainDB)",
            "captureRMSDBFS": "\(attribution.capture.rmsDBFS)",
            "drainFaultFlags": "0x\(String(attribution.drainFaultFlags, radix: 16))",
            "verdict": attribution.verdict.rawValue,
            "reason": attribution.reason
        ])

#if DEBUG
        guard let directoryURL else { return }
        do {
            let generationDirectory = directoryURL
                .appendingPathComponent("session-\(sessionID)", isDirectory: true)
                .appendingPathComponent("generation-\(generation.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: generationDirectory, withIntermediateDirectories: true
            )
            let challengeURL = generationDirectory.appendingPathComponent("challenge.wav")
            let captureURL = generationDirectory.appendingPathComponent("capture.wav")
            let analysisURL = generationDirectory.appendingPathComponent("analysis.json")
            try writeChallengeWAV(challenge, to: challengeURL)
            try writeWAV(capture, to: captureURL)
            try encoder.encode(attribution).write(to: analysisURL, options: .atomic)
            await logger.log("isolation.signal.evidence.exported", generation: generation, fields: [
                "challengeWAV": challengeURL.path,
                "captureWAV": captureURL.path,
                "analysis": analysisURL.path
            ])
        } catch {
            await logger.log("isolation.signal.evidence.failed", generation: generation, fields: [
                "error": error.localizedDescription
            ])
        }
#endif
    }

    nonisolated static func defaultDirectoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EqualizerAU/Debug/output-isolation", isDirectory: true)
    }

    private func writeWAV(_ window: AudioOutputIsolationSignalWindow, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: window.sampleRate,
            channels: AVAudioChannelCount(window.channelCount)
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(window.frameCount)
        ), let channelData = buffer.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(window.frameCount)
        for frame in 0..<Int(window.frameCount) {
            for channel in 0..<Int(window.channelCount) {
                channelData[channel][frame] = window.samples[
                    frame * Int(window.channelCount) + channel
                ]
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func writeChallengeWAV(
        _ challenge: AudioOutputIsolationChallenge,
        to url: URL
    ) throws {
        try writeWAV(
            AudioOutputIsolationSignalWindow(
                phase: .challengeCapture,
                sequence: 0,
                firstHostTime: 0,
                droppedFrames: 0,
                frameCount: UInt32(challenge.samples.count),
                channelCount: 1,
                sampleRate: challenge.sampleRate,
                samples: challenge.samples
            ),
            to: url
        )
    }
}

struct NullAudioOutputIsolationEvidenceRecorder: AudioOutputIsolationEvidenceRecording {
    func record(
        challenge: AudioOutputIsolationChallenge,
        capture: AudioOutputIsolationSignalWindow,
        attribution: AudioOutputIsolationAttribution,
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async {}
}

protocol AudioSignalEvidenceRecording: Sendable {
    func record(
        windows: [AudioSignalProbeWindow],
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async
}

actor AudioSignalEvidenceRecorder: AudioSignalEvidenceRecording {
    static let shared = AudioSignalEvidenceRecorder()

    private struct EvidenceKey: Hashable {
        let generation: UInt64
        let stage: AudioSignalStage
    }

    private let directoryURL: URL?
    private let sessionID: String
    private let analyzer = AudioSignalAnalyzer()
    private let encoder: JSONEncoder
    private var latestSequences: [EvidenceKey: UInt64] = [:]
    private var exportedStages: Set<EvidenceKey> = []

    init(
        directoryURL: URL? = AudioSignalEvidenceRecorder.defaultDirectoryURL(),
        sessionID: String = AudioDebugSession.id
    ) {
        self.directoryURL = directoryURL
        self.sessionID = sessionID
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func record(
        windows: [AudioSignalProbeWindow],
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async {
        for window in windows {
            let key = EvidenceKey(generation: generation.rawValue, stage: window.stage)
            guard window.sequence > latestSequences[key] ?? 0,
                  let analysis = analyzer.analyze(window) else { continue }
            latestSequences[key] = window.sequence
            await logger.log("signal.probe", generation: generation, fields: fields(analysis))

#if DEBUG
            guard analysis.rms > 0.000_001, !exportedStages.contains(key), let directoryURL else {
                continue
            }
            do {
                let generationDirectory = directoryURL
                    .appendingPathComponent("session-\(sessionID)", isDirectory: true)
                    .appendingPathComponent("generation-\(generation.rawValue)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: generationDirectory, withIntermediateDirectories: true
                )
                let wavURL = generationDirectory.appendingPathComponent("\(window.stage.rawValue).wav")
                let jsonURL = generationDirectory.appendingPathComponent("\(window.stage.rawValue).json")
                try writeWAV(window, to: wavURL)
                try encoder.encode(analysis).write(to: jsonURL, options: .atomic)
                exportedStages.insert(key)
                await logger.log("signal.evidence.exported", generation: generation, fields: [
                    "stage": window.stage.rawValue,
                    "wav": wavURL.path,
                    "analysis": jsonURL.path
                ])
            } catch {
                await logger.log("signal.evidence.failed", generation: generation, fields: [
                    "stage": window.stage.rawValue,
                    "error": error.localizedDescription
                ])
            }
#endif
        }
    }

    nonisolated static func defaultDirectoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EqualizerAU/Debug/signal-probes", isDirectory: true)
    }

    private func fields(_ analysis: AudioSignalAnalysis) -> [String: String] {
        [
            "stage": analysis.stage.rawValue,
            "sequence": "\(analysis.sequence)",
            "hostTime": "\(analysis.hostTime)",
            "droppedProbeFrames": "\(analysis.droppedFrames)",
            "frames": "\(analysis.frameCount)",
            "channels": "\(analysis.channelCount)",
            "sampleRate": "\(analysis.sampleRate)",
            "rms": "\(analysis.rms)",
            "rmsDBFS": "\(analysis.rmsDBFS)",
            "peak": "\(analysis.peak)",
            "peakDBFS": "\(analysis.peakDBFS)",
            "dominantFrequencyHz": "\(analysis.dominantFrequencyHz)",
            "spectrumPeaks": analysis.spectrumPeaks.map {
                "\($0.frequencyHz):\($0.magnitudeDB)"
            }.joined(separator: ",")
        ]
    }

    private func writeWAV(_ window: AudioSignalProbeWindow, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: window.sampleRate,
            channels: AVAudioChannelCount(window.channelCount)
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(window.frameCount)
        ), let channelData = buffer.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(window.frameCount)
        for frame in 0..<Int(window.frameCount) {
            for channel in 0..<Int(window.channelCount) {
                channelData[channel][frame] = window.samples[frame * Int(window.channelCount) + channel]
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

struct NullAudioSignalEvidenceRecorder: AudioSignalEvidenceRecording {
    func record(
        windows: [AudioSignalProbeWindow],
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async {}
}
