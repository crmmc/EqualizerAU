import Foundation
import XCTest

final class M1ConvolutionIRTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualizerAUM1-IRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPCM16ImportPersistsImmutableSidecarAndReloadsVerifiedMetadata() throws {
        let source = temporaryDirectory.appendingPathComponent("Room IR.wav")
        try wavPCM16(sampleRate: 48_000, channels: [[0, 0.5, -0.5, 0]]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))

        let reference = try store.importWAV(at: source)
        let loaded = try store.load(reference: reference, targetSampleRate: 48_000)

        XCTAssertEqual(reference.originalFileName, "Room IR.wav")
        XCTAssertEqual(reference.sampleRate, 48_000)
        XCTAssertEqual(reference.channelCount, 1)
        XCTAssertEqual(reference.frameCount, 4)
        XCTAssertEqual(reference.sha256.count, 64)
        XCTAssertFloatArraysEqual(loaded.channels[0], [0, 0.5, -0.5, 0], accuracy: 0.000_1)
        let sidecar = store.directoryURL.appendingPathComponent("\(reference.storageID.uuidString).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertThrowsError(try store.importWAV(at: source, storageID: reference.storageID)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .storageAlreadyExists)
        }
    }

    func testFloat32ImportAndWindowedSincSampleRateConversion() throws {
        let source = temporaryDirectory.appendingPathComponent("delta.wav")
        try wavFloat32(sampleRate: 24_000, channels: [[1, 0, 0, 0]]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = try store.importWAV(at: source)

        let loaded = try store.load(reference: reference, targetSampleRate: 48_000)

        XCTAssertEqual(loaded.channels[0].count, 8)
        XCTAssertEqual(loaded.targetSampleRate, 48_000)
        XCTAssertTrue(loaded.channels[0].allSatisfy(\.isFinite))
        XCTAssertEqual(loaded.channels[0][0], 0.5, accuracy: 0.0001)
    }

    func testHighRatioDownsamplingAttenuatesContentAboveTargetNyquist() throws {
        let samples = (0..<16_384).map { $0.isMultiple(of: 2) ? Float(0.5) : Float(-0.5) }
        let source = temporaryDirectory.appendingPathComponent("high-frequency.wav")
        try wavFloat32(sampleRate: 768_000, channels: [samples]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = try store.importWAV(at: source)

        let loaded = try store.load(reference: reference, targetSampleRate: 48_000)
        let interior = loaded.channels[0].dropFirst(32).dropLast(32)

        XCTAssertFalse(interior.isEmpty)
        XCTAssertLessThan(interior.map { abs($0) }.max() ?? 1, 0.01)
    }

    func testExtremeRateSingleFrameResamplingUsesZeroExtensionAndPreservesImpulseGain() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let downsampleSource = temporaryDirectory.appendingPathComponent("single-768k.wav")
        try wavFloat32(sampleRate: 768_000, channels: [[1]]).write(to: downsampleSource)
        let downsampleReference = try store.importWAV(at: downsampleSource)
        let downsampled = try store.load(reference: downsampleReference, targetSampleRate: 8_000)
        XCTAssertEqual(downsampled.channels[0].count, 1)
        XCTAssertEqual(downsampled.channels[0][0], 1, accuracy: 0.0001)

        let upsampleSource = temporaryDirectory.appendingPathComponent("single-8k.wav")
        try wavFloat32(sampleRate: 8_000, channels: [[1]]).write(to: upsampleSource)
        let upsampleReference = try store.importWAV(at: upsampleSource)
        let upsampled = try store.load(reference: upsampleReference, targetSampleRate: 768_000)
        XCTAssertEqual(upsampled.channels[0].count, 96)
        XCTAssertEqual(upsampled.channels[0][0], 1.0 / 96.0, accuracy: 0.0001)
        XCTAssertLessThan(abs(upsampled.channels[0].last!), 0.001)

        let centeredSource = temporaryDirectory.appendingPathComponent("centered-delta-8k.wav")
        var centeredDelta = Array(repeating: Float.zero, count: 65)
        centeredDelta[32] = 1
        try wavFloat32(sampleRate: 8_000, channels: [centeredDelta]).write(to: centeredSource)
        let centeredReference = try store.importWAV(at: centeredSource)
        let centered = try store.load(reference: centeredReference, targetSampleRate: 768_000)
        XCTAssertEqual(centered.channels[0].reduce(0, +), 1, accuracy: 0.001)
    }

    func testRejectsNonWAVCompressionFloat64EmptyOverDurationOversizeAndNonFinite() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let fixtures: [(String, Data, M1ConvolutionIRError)] = [
            ("not.wav", Data("not wave".utf8), .invalidWAV),
            ("compressed.wav", wav(format: 6, bits: 8, sampleRate: 48_000, channels: 1, payload: Data([0])), .unsupportedEncoding),
            ("float64.wav", wav(format: 3, bits: 64, sampleRate: 48_000, channels: 1, payload: Data(repeating: 0, count: 8)), .unsupportedEncoding),
            ("empty.wav", wav(format: 1, bits: 16, sampleRate: 48_000, channels: 1, payload: Data()), .emptyAudio),
            ("long.wav", wavPCM16(sampleRate: 48_000, channels: [Array(repeating: 0, count: 96_001)]), .durationExceeded),
            ("nan.wav", wavFloat32Bits(sampleRate: 48_000, bits: [Float.nan.bitPattern]), .invalidSample),
            ("infinity.wav", wavFloat32Bits(sampleRate: 48_000, bits: [Float.infinity.bitPattern]), .invalidSample),
            ("subnormal.wav", wavFloat32Bits(sampleRate: 48_000, bits: [1]), .invalidSample),
        ]
        for (name, data, expected) in fixtures {
            let url = temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertThrowsError(try store.importWAV(at: url), name) {
                XCTAssertEqual($0 as? M1ConvolutionIRError, expected, name)
            }
        }

        let oversized = temporaryDirectory.appendingPathComponent("oversized.wav")
        try Data(repeating: 0, count: M1ConvolutionIRStore.maximumFileSize + 1).write(to: oversized)
        XCTAssertThrowsError(try store.importWAV(at: oversized)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .fileTooLarge)
        }
    }

    func testRejectsMalformedExtensibleEncodingAndUnsupportedSampleRatesWithoutTrapping() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let malformed = temporaryDirectory.appendingPathComponent("malformed-extensible.wav")
        try wavExtensible(subformatEncoding: 0x0001_0001).write(to: malformed)
        XCTAssertThrowsError(try store.importWAV(at: malformed)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .unsupportedEncoding)
        }

        let excessiveRate = temporaryDirectory.appendingPathComponent("excessive-rate.wav")
        try wavPCM16(sampleRate: 768_001, channels: [[1]]).write(to: excessiveRate)
        XCTAssertThrowsError(try store.importWAV(at: excessiveRate)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidMetadata)
        }

        let insufficientRate = temporaryDirectory.appendingPathComponent("insufficient-rate.wav")
        try wavPCM16(sampleRate: 7_999, channels: [[1]]).write(to: insufficientRate)
        XCTAssertThrowsError(try store.importWAV(at: insufficientRate)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidMetadata)
        }

        let fixture = try makeStore(channels: [[1]])
        XCTAssertThrowsError(try fixture.store.load(
            reference: fixture.reference!,
            targetSampleRate: Double.greatestFiniteMagnitude
        )) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidMetadata)
        }
        XCTAssertThrowsError(try fixture.store.load(
            reference: fixture.reference!,
            targetSampleRate: 7_999
        )) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidMetadata)
        }
    }

    func testLoadRejectsMissingTamperedAndMetadataMismatch() throws {
        let source = temporaryDirectory.appendingPathComponent("valid.wav")
        try wavPCM16(sampleRate: 48_000, channels: [[1, 0]]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = try store.importWAV(at: source)
        let sidecar = store.directoryURL.appendingPathComponent("\(reference.storageID.uuidString).wav")

        var tampered = try Data(contentsOf: sidecar)
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: sidecar)
        XCTAssertThrowsError(try store.load(reference: reference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .hashMismatch)
        }

        try FileManager.default.removeItem(at: sidecar)
        XCTAssertThrowsError(try store.load(reference: reference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .missingResource)
        }

        let second = try store.importWAV(at: source)
        let wrong = M1ConvolutionIRReference(
            storageID: second.storageID,
            originalFileName: second.originalFileName,
            sha256: second.sha256,
            sampleRate: second.sampleRate,
            channelCount: second.channelCount,
            frameCount: second.frameCount + 1
        )
        XCTAssertThrowsError(try store.load(reference: wrong, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .metadataMismatch)
        }
    }

    func testBuilderBroadcastsMonoFlushesGainAndReportsLatencyAndSource() throws {
        let store = try makeStore(channels: [[1, 0, 0]])
        let reference = try XCTUnwrap(store.reference)
        let gain = M1PreampNode(id: UUID(), isEnabled: true, gainDB: -6, channels: .all)
        let convolution = M1ProcessingNode.convolution(ir: reference)

        let result = try M1ProcessingBuilder.build(
            nodes: [gain, convolution],
            layout: stereoLayout(),
            irLoader: store.store
        )

        XCTAssertEqual(result.processingLatencyFrames, 0)
        XCTAssertEqual(result.diagnostics.convolutionSources.count, 1)
        for stages in result.stagesByChannel {
            guard case .gain = stages[0], case let .convolution(nodeID, taps) = stages[1] else {
                return XCTFail("expected Gain followed by Convolution")
            }
            XCTAssertEqual(nodeID, convolution.id)
            XCTAssertFloatArraysEqual(taps, [1, 0, 0], accuracy: 0.000_1)
        }
    }

    func testBuilderMapsMultichannelInSelectionOrderAndRejectsMismatch() throws {
        let fixture = try makeStore(channels: [[0.25, 0], [0.75, 0]])
        let reference = try XCTUnwrap(fixture.reference)
        let convolution = M1ProcessingNode.convolution(ir: reference)
        let right = M1ChannelIdentifier("R")!
        let left = M1ChannelIdentifier("L")!
        let result = try M1ProcessingBuilder.build(
            nodes: [.channels(selection: .identifiers([right, left])), convolution],
            layout: stereoLayout(),
            irLoader: fixture.store
        )
        guard case let .convolution(_, leftTaps) = result.stagesByChannel[0][0],
              case let .convolution(_, rightTaps) = result.stagesByChannel[1][0]
        else {
            return XCTFail("expected mapped convolution stages")
        }
        XCTAssertEqual(rightTaps[0], 0.25, accuracy: 0.000_1)
        XCTAssertEqual(leftTaps[0], 0.75, accuracy: 0.000_1)

        XCTAssertThrowsError(try M1ProcessingBuilder.build(
            nodes: [.channels(selection: .identifiers([left])), convolution],
            layout: stereoLayout(),
            irLoader: fixture.store
        )) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .convolutionChannelCountMismatch(nodeID: convolution.id, expected: 1, actual: 2)
            )
        }
    }

    func testBuilderDoesNotLoadForEntirelyUnresolvedScopeAndEnforcesConvolutionCapacity() throws {
        let missing = reference(storageID: UUID())
        let unresolved = M1ProcessingNode.convolution(ir: missing)
        let emptyStore = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("empty"))
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .channels(selection: .identifiers([M1ChannelIdentifier("MISSING")!])),
                unresolved,
            ],
            layout: stereoLayout(),
            irLoader: emptyStore
        )
        XCTAssertEqual(result.stagesByChannel, [[], []])

        let fixture = try makeStore(channels: [[1]])
        let nodes = (0...M1ProcessingBuilder.maximumConvolutionStages).map { _ in
            M1ProcessingNode.convolution(ir: fixture.reference!)
        }
        let mono = M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [1],
            semanticPositionsByChannelIndex: [.left]
        )!
        XCTAssertThrowsError(try M1ProcessingBuilder.build(nodes: nodes, layout: mono, irLoader: fixture.store)) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .convolutionStageCapacityExceeded)
        }
    }

    func testBuilderAccumulatesSerialLatencyAndEnforcesTotalTapCapacity() throws {
        let short = try makeStore(channels: [[1]])
        let serial = try M1ProcessingBuilder.build(
            nodes: [
                .convolution(ir: short.reference!),
                .convolution(ir: short.reference!),
            ],
            layout: stereoLayout(),
            irLoader: short.store
        )
        XCTAssertEqual(serial.processingLatencyFrames, 0)

        let long = try makeStore(channels: [Array(repeating: 0, count: 65_537)])
        XCTAssertThrowsError(try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: long.reference!)],
            layout: stereoLayout(),
            irLoader: long.store
        )) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .convolutionTapCapacityExceeded)
        }
    }

    func testSwiftBridgeCreatesV3PreparedStateWithConvolutionDescriptors() throws {
        let fixture = try makeStore(channels: [[1, 0]])
        let compiled = try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: fixture.reference!)],
            layout: stereoLayout(),
            irLoader: fixture.store
        )
        let prepared = try M1RuntimePreparedStateFactory.create(stagesByChannel: compiled.stagesByChannel)
        XCTAssertNotNil(prepared)
        EAUM1PreparedStateDestroy(prepared)
        XCTAssertEqual(EAUM1RuntimeABIVersion(), 3)
    }

    private func makeStore(channels: [[Float]]) throws -> (store: M1ConvolutionIRStore, reference: M1ConvolutionIRReference?) {
        let source = temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        try wavFloat32(sampleRate: 48_000, channels: channels).write(to: source)
        let store = M1ConvolutionIRStore(
            directoryURL: temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        )
        return (store, try store.importWAV(at: source))
    }

    private func reference(storageID: UUID) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(
            storageID: storageID,
            originalFileName: "missing.wav",
            sha256: String(repeating: "0", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
    }

    private func stereoLayout() -> M1OutputLayoutSnapshot {
        M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [2],
            semanticPositionsByChannelIndex: [.left, .right]
        )!
    }

    private func wavPCM16(sampleRate: Int, channels: [[Float]]) -> Data {
        var payload = Data()
        for frame in channels[0].indices {
            for channel in channels {
                let value = Int16((max(-1, min(0.999_969, channel[frame])) * 32_768).rounded())
                payload.appendLittleEndian(UInt16(bitPattern: value))
            }
        }
        return wav(format: 1, bits: 16, sampleRate: sampleRate, channels: channels.count, payload: payload)
    }

    private func wavFloat32(sampleRate: Int, channels: [[Float]]) -> Data {
        var payload = Data()
        for frame in channels[0].indices {
            for channel in channels { payload.appendLittleEndian(channel[frame].bitPattern) }
        }
        return wav(format: 3, bits: 32, sampleRate: sampleRate, channels: channels.count, payload: payload)
    }

    private func wavFloat32Bits(sampleRate: Int, bits: [UInt32]) -> Data {
        var payload = Data()
        for value in bits { payload.appendLittleEndian(value) }
        return wav(format: 3, bits: 32, sampleRate: sampleRate, channels: 1, payload: payload)
    }

    private func wavExtensible(subformatEncoding: UInt32) -> Data {
        var format = Data()
        format.appendLittleEndian(UInt16(0xFFFE))
        format.appendLittleEndian(UInt16(1))
        format.appendLittleEndian(UInt32(48_000))
        format.appendLittleEndian(UInt32(96_000))
        format.appendLittleEndian(UInt16(2))
        format.appendLittleEndian(UInt16(16))
        format.appendLittleEndian(UInt16(22))
        format.appendLittleEndian(UInt16(16))
        format.appendLittleEndian(UInt32(0))
        format.appendLittleEndian(subformatEncoding)
        format.append(contentsOf: [0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])

        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(4 + 8 + format.count + 8 + 2))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(format.count))
        data.append(format)
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(2))
        data.appendLittleEndian(UInt16(0))
        return data
    }

    private func wav(
        format: UInt16,
        bits: Int,
        sampleRate: Int,
        channels: Int,
        payload: Data
    ) -> Data {
        let blockAlign = channels * bits / 8
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + payload.count))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(format)
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * blockAlign))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bits))
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private extension XCTestCase {
    func XCTAssertFloatArraysEqual(
        _ actual: [Float],
        _ expected: [Float],
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
        }
    }
}
