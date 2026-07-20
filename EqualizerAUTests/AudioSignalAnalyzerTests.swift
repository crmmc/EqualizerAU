import Foundation
import XCTest
@testable import EqualizerAU

final class AudioSignalAnalyzerTests: XCTestCase {
    func testAnalyzerMeasuresRMSPeakAndDominantFrequency() throws {
        let window = sineWindow(stage: .capture)
        let analysis = try XCTUnwrap(AudioSignalAnalyzer().analyze(window))
        let expectedRMS = Float(sqrt(window.samples.reduce(0.0) { sum, sample in
            sum + Double(sample * sample)
        } / Double(window.samples.count)))

        XCTAssertEqual(analysis.rms, expectedRMS, accuracy: 0.000_001)
        XCTAssertEqual(analysis.peak, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(analysis.dominantFrequencyHz, 1_000, accuracy: 20)
        XCTAssertEqual(analysis.stage, .capture)
        XCTAssertFalse(analysis.spectrumPeaks.isEmpty)
    }

    func testEvidenceRecorderWritesStageWAVJSONAndStructuredLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualizerAU-SignalEvidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("audio-debug.jsonl")
        let recorder = AudioSignalEvidenceRecorder(
            directoryURL: directory.appendingPathComponent("probes"),
            sessionID: "test-session"
        )
        let logger = AudioDebugLogger(fileURL: logURL, sessionID: "test-session")
        let generation = AudioGeneration(rawValue: 7)

        await recorder.record(
            windows: [sineWindow(stage: .postDSP)], generation: generation, logger: logger
        )

        let generationDirectory = directory.appendingPathComponent(
            "probes/session-test-session/generation-7"
        )
        let wavURL = generationDirectory.appendingPathComponent("postDSP.wav")
        let jsonURL = generationDirectory.appendingPathComponent("postDSP.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let analysis = try JSONDecoder().decode(
            AudioSignalAnalysis.self, from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(analysis.stage, .postDSP)
        XCTAssertEqual(analysis.dominantFrequencyHz, 1_000, accuracy: 20)
    }

    func testIsolationAnalyzerDetectsExactNonceAtAnOffset() throws {
        let challenge = try makeChallenge(seed: 1)
        let capture = captureWindow(challenge.samples, gain: 0.8, offset: 777)

        let attribution = try AudioOutputIsolationSignalAnalyzer().compare(
            capture: capture,
            challenge: challenge,
            drainFaultFlags: 0
        )

        XCTAssertEqual(attribution.verdict, .detected)
        XCTAssertGreaterThan(attribution.capture.challengeCorrelation, 0.999)
        XCTAssertEqual(attribution.capture.challengeLagFrames, 777)
        XCTAssertEqual(attribution.capture.estimatedGain, 0.8, accuracy: 0.001)
    }

    func testIsolationAnalyzerRejectsDifferentNonceAtTheSameCarrierFrequency() throws {
        let expected = try makeChallenge(seed: 1)
        let different = try makeChallenge(seed: 2)

        let attribution = try AudioOutputIsolationSignalAnalyzer().compare(
            capture: captureWindow(different.samples, gain: 1, offset: 300),
            challenge: expected,
            drainFaultFlags: 0
        )

        XCTAssertEqual(attribution.verdict, .notDetected)
        XCTAssertLessThan(attribution.capture.challengeCorrelation, attribution.correlationThreshold)
    }

    func testIsolationAnalyzerMakesDroppedOrFaultedCaptureInconclusive() throws {
        let challenge = try makeChallenge(seed: 3)
        let dropped = try AudioOutputIsolationSignalAnalyzer().compare(
            capture: captureWindow(challenge.samples, gain: 1, offset: 0, droppedFrames: 64),
            challenge: challenge,
            drainFaultFlags: 0
        )
        let faulted = try AudioOutputIsolationSignalAnalyzer().compare(
            capture: captureWindow(challenge.samples, gain: 1, offset: 0),
            challenge: challenge,
            drainFaultFlags: UInt32(EAUAudioIOFaultLayoutMismatch)
        )

        XCTAssertEqual(dropped.verdict, .inconclusive)
        XCTAssertTrue(dropped.reason.contains("dropped"))
        XCTAssertEqual(faulted.verdict, .inconclusive)
        XCTAssertTrue(faulted.reason.contains("drain"))
    }

    func testIsolationEvidenceRecorderWritesChallengeCaptureAndAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualizerAU-IsolationEvidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("audio-debug.jsonl")
        let recorder = AudioOutputIsolationEvidenceRecorder(
            directoryURL: directory.appendingPathComponent("probes"),
            sessionID: "test-session"
        )
        let logger = AudioDebugLogger(fileURL: logURL, sessionID: "test-session")
        let generation = AudioGeneration(rawValue: 9)
        let challenge = try makeChallenge(seed: 9)
        let capture = captureWindow(challenge.samples, gain: 0.5, offset: 128)
        let attribution = try AudioOutputIsolationSignalAnalyzer().compare(
            capture: capture, challenge: challenge, drainFaultFlags: 0
        )

        await recorder.record(
            challenge: challenge,
            capture: capture,
            attribution: attribution,
            generation: generation,
            logger: logger
        )

        let evidenceDirectory = directory.appendingPathComponent(
            "probes/session-test-session/generation-9"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: evidenceDirectory.appendingPathComponent("challenge.wav").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: evidenceDirectory.appendingPathComponent("capture.wav").path
        ))
        let analysisURL = evidenceDirectory.appendingPathComponent("analysis.json")
        let decoded = try JSONDecoder().decode(
            AudioOutputIsolationAttribution.self, from: Data(contentsOf: analysisURL)
        )
        XCTAssertEqual(decoded.verdict, .detected)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("isolation.signal.attribution"))
        XCTAssertTrue(log.contains("isolation.signal.evidence.exported"))
    }

    private func sineWindow(stage: AudioSignalStage) -> AudioSignalProbeWindow {
        let sampleRate = 48_000.0
        let frames = 4_096
        let channels = 2
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let sample = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
            samples[frame * channels] = sample
            samples[frame * channels + 1] = sample
        }
        return AudioSignalProbeWindow(
            stage: stage,
            sequence: 1,
            hostTime: 123,
            droppedFrames: 0,
            frameCount: UInt32(frames),
            channelCount: UInt32(channels),
            sampleRate: sampleRate,
            samples: samples
        )
    }

    private func makeChallenge(seed: UInt64) throws -> AudioOutputIsolationChallenge {
        try AudioOutputIsolationChallengeGenerator().make(
            seed: seed,
            sampleRate: 48_000,
            carrierFrequency: 660,
            amplitude: 0.02,
            durationFrames: 48_000,
            chipFrames: 480,
            fadeFrames: 1_440
        )
    }

    private func captureWindow(
        _ reference: [Float],
        gain: Float,
        offset: Int,
        droppedFrames: UInt64 = 0
    ) -> AudioOutputIsolationSignalWindow {
        let frameCount = reference.count + offset + 512
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for (frame, sample) in reference.enumerated() {
            samples[(offset + frame) * 2] = sample * gain
            samples[(offset + frame) * 2 + 1] = sample * gain
        }
        return AudioOutputIsolationSignalWindow(
            phase: .challengeCapture,
            sequence: 1,
            firstHostTime: 100,
            droppedFrames: droppedFrames,
            frameCount: UInt32(frameCount),
            channelCount: 2,
            sampleRate: 48_000,
            samples: samples
        )
    }
}
