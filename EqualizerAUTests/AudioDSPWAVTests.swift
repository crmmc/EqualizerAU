import AVFoundation
import XCTest
@testable import EqualizerAU

final class AudioDSPWAVTests: XCTestCase {
    func testExactRealtimeDSPProducesMinus12dBStereoWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualizerAU-WAV-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input-1khz.wav")
        let outputURL = directory.appendingPathComponent("output-minus12db.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frameCount: AVAudioFrameCount = 48_000
        var input = [Float](repeating: 0, count: Int(frameCount) * 2)
        for frame in 0..<Int(frameCount) {
            let sample = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(frame) / 48_000))
            input[frame * 2] = sample
            input[frame * 2 + 1] = sample
        }
        try write(interleaved: input, format: format, frameCount: frameCount, to: inputURL)

        let decoded = try readInterleaved(url: inputURL, format: format, frameCount: frameCount)
        var output = [Float](repeating: 0, count: decoded.count)
        let nonZero = decoded.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                EAUAudioDSPProcessInterleaved(
                    source.baseAddress, destination.baseAddress, UInt32(frameCount), 2,
                    AudioIOController.mvpOutputGain, AudioIOController.mvpOutputLimit
                )
            }
        }
        try write(interleaved: output, format: format, frameCount: frameCount, to: outputURL)

        let renderedSamples = try readInterleaved(url: outputURL, format: format, frameCount: frameCount)
        let sampleCount = Int(frameCount) * 2
        let inputRMS = rms(decoded)
        let outputRMS = rms(renderedSamples)
        let peak = (0..<sampleCount).reduce(Float.zero) { max($0, abs(renderedSamples[$1])) }

        XCTAssertGreaterThan(nonZero, 0)
        XCTAssertEqual(renderedSamples.count, sampleCount)
        XCTAssertEqual(outputRMS / inputRMS, AudioIOController.mvpOutputGain, accuracy: 0.000_02)
        XCTAssertEqual(20 * log10(outputRMS / inputRMS), -12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(peak, AudioIOController.mvpOutputLimit)
        XCTAssertTrue((0..<sampleCount).allSatisfy { renderedSamples[$0].isFinite })
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let inputAttachment = XCTAttachment(contentsOfFile: inputURL)
        inputAttachment.name = "input-1khz-48khz-stereo.wav"
        inputAttachment.lifetime = .keepAlways
        add(inputAttachment)
        let outputAttachment = XCTAttachment(contentsOfFile: outputURL)
        outputAttachment.name = "output-minus12db-48khz-stereo.wav"
        outputAttachment.lifetime = .keepAlways
        add(outputAttachment)
    }

    private func write(
        interleaved samples: [Float],
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        to url: URL
    ) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = samples[frame * 2]
            channels[1][frame] = samples[frame * 2 + 1]
        }
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }

    private func readInterleaved(
        url: URL,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        try file.read(into: buffer, frameCount: frameCount)
        XCTAssertEqual(buffer.frameLength, frameCount)
        XCTAssertEqual(buffer.format.sampleRate, 48_000)
        XCTAssertEqual(buffer.format.channelCount, 2)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        var samples = [Float](repeating: 0, count: Int(buffer.frameLength) * 2)
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame * 2] = channels[0][frame]
            samples[frame * 2 + 1] = channels[1][frame]
        }
        return samples
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
    }
}
