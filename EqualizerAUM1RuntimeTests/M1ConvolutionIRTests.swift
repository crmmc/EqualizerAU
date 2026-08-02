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

    func testPCM16SourcePathLoadsMetadataWithoutCreatingSidecar() throws {
        let source = temporaryDirectory.appendingPathComponent("Room IR.wav")
        try wavPCM16(sampleRate: 48_000, channels: [[0, 0.5, -0.5, 0]]).write(to: source)
        let storeDirectory = temporaryDirectory.appendingPathComponent("store")
        let store = M1ConvolutionIRStore(directoryURL: storeDirectory)

        let reference = M1ConvolutionIRStore.reference(sourceURL: source)
        let loaded = try store.load(reference: reference, targetSampleRate: 48_000)

        XCTAssertEqual(reference.sourcePath, source.standardizedFileURL.path)
        XCTAssertEqual(reference.originalFileName, "Room IR.wav")
        XCTAssertEqual(loaded.sourceSampleRate, 48_000)
        XCTAssertEqual(loaded.sourceChannelCount, 1)
        XCTAssertEqual(loaded.sourceFrameCount, 4)
        XCTAssertFloatArraysEqual(loaded.channels[0], [0, 0.5, -0.5, 0], accuracy: 0.000_1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.path))
    }

    func testSampleRateMismatchBypassesWithoutResampling() throws {
        let source = temporaryDirectory.appendingPathComponent("delta.wav")
        try wavFloat32(sampleRate: 24_000, channels: [[1, 0, 0, 0]]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = M1ConvolutionIRStore.reference(sourceURL: source)

        XCTAssertThrowsError(try store.load(reference: reference, targetSampleRate: 24_001.01)) {
            XCTAssertEqual(
                $0 as? M1ConvolutionIRError,
                .sampleRateMismatch(source: 24_000, target: 24_001.01)
            )
        }

        let loaded = try store.load(reference: reference, targetSampleRate: 24_001)
        XCTAssertEqual(loaded.channels[0], [1, 0, 0, 0])
        XCTAssertEqual(loaded.sourceFrameCount, 4)
        XCTAssertEqual(loaded.targetSampleRate, 24_001)
    }

    func testRejectsInvalidWAVEncodingEmptyAndNonFiniteSamples() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let fixtures: [(String, Data, M1ConvolutionIRError)] = [
            ("not.wav", Data("not wave".utf8), .invalidWAV),
            ("compressed.wav", wav(format: 6, bits: 8, sampleRate: 48_000, channels: 1, payload: Data([0])), .unsupportedEncoding),
            ("float64.wav", wav(format: 3, bits: 64, sampleRate: 48_000, channels: 1, payload: Data(repeating: 0, count: 8)), .unsupportedEncoding),
            ("empty.wav", wav(format: 1, bits: 16, sampleRate: 48_000, channels: 1, payload: Data()), .emptyAudio),
            ("nan.wav", wavFloat32Bits(sampleRate: 48_000, bits: [Float.nan.bitPattern]), .invalidSample),
            ("infinity.wav", wavFloat32Bits(sampleRate: 48_000, bits: [Float.infinity.bitPattern]), .invalidSample),
            ("subnormal.wav", wavFloat32Bits(sampleRate: 48_000, bits: [1]), .invalidSample),
        ]
        for (name, data, expected) in fixtures {
            let url = temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url)
            let reference = M1ConvolutionIRStore.reference(sourceURL: url)
            XCTAssertThrowsError(try store.load(reference: reference, targetSampleRate: 48_000), name) {
                XCTAssertEqual($0 as? M1ConvolutionIRError, expected, name)
            }
        }
    }

    func testRejectsNonRegularAndImpossibleSparseRIFFBeforeReadingBody() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let directoryReference = M1ConvolutionIRStore.reference(sourceURL: temporaryDirectory)
        XCTAssertThrowsError(try store.load(reference: directoryReference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .resourceIO)
        }

        let sparse = temporaryDirectory.appendingPathComponent("oversized-sparse.wav")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: sparse.path,
            contents: Data(repeating: 0, count: 12)
        ))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(UInt32.max) + 9)
        try handle.close()
        let sparseReference = M1ConvolutionIRStore.reference(sourceURL: sparse)
        XCTAssertThrowsError(try store.load(reference: sparseReference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidWAV)
        }
    }

    func testLongIRLoadsCreatesPreparedStateAndReportsPerformanceWarning() throws {
        let source = temporaryDirectory.appendingPathComponent("long.wav")
        var samples = Array(repeating: Float.zero, count: 384_000)
        samples[0] = 1
        try wavFloat32(sampleRate: 48_000, channels: [samples]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = M1ConvolutionIRStore.reference(sourceURL: source)
        let mono = M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [1],
            semanticPositionsByChannelIndex: [.left]
        )!

        let threshold = try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: reference)],
            layout: mono,
            irLoader: store
        )
        XCTAssertFalse(try XCTUnwrap(threshold.diagnostics.convolutionSources.first).hasPerformanceWarning)
        guard case let .convolution(_, thresholdTaps) = try XCTUnwrap(
            threshold.stagesByChannel[0].first
        ) else {
            return XCTFail("Expected convolution stage")
        }
        XCTAssertEqual(thresholdTaps, [1])

        samples.append(0)
        try wavFloat32(sampleRate: 48_000, channels: [samples]).write(to: source)
        let overThreshold = try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: reference)],
            layout: mono,
            irLoader: store
        )
        let sourceDiagnostic = try XCTUnwrap(overThreshold.diagnostics.convolutionSources.first)
        XCTAssertTrue(sourceDiagnostic.hasPerformanceWarning)
        XCTAssertEqual(sourceDiagnostic.sourceFrameCount, 384_001)
        XCTAssertEqual(sourceDiagnostic.targetFrameCount, 384_001)
        guard case let .convolution(_, overThresholdTaps) = try XCTUnwrap(
            overThreshold.stagesByChannel[0].first
        ) else {
            return XCTFail("Expected convolution stage")
        }
        XCTAssertEqual(overThresholdTaps, [1])
        let prepared = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: overThreshold.stagesByChannel
        )
        EAUM1PreparedStateDestroy(prepared)
    }

    func testBuilderTrimsOnlyExactTrailingZerosFromRuntimeTaps() throws {
        let fixture = try makeStore(channels: [
            [1, 0, 0.5, 0, 0],
            [0, 0, 0, 0, 0],
        ])
        let reference = try XCTUnwrap(fixture.reference)
        let loaded = try fixture.store.load(reference: reference, targetSampleRate: 48_000)
        XCTAssertEqual(loaded.channels.map(\.count), [5, 5])

        let result = try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: reference)],
            layout: stereoLayout(),
            irLoader: fixture.store
        )
        guard case let .convolution(_, leftTaps) = try XCTUnwrap(
            result.stagesByChannel[0].first
        ), case let .convolution(_, rightTaps) = try XCTUnwrap(
            result.stagesByChannel[1].first
        ) else {
            return XCTFail("Expected convolution stages")
        }
        XCTAssertEqual(leftTaps, [1, 0, 0.5])
        XCTAssertEqual(rightTaps, [0])
        XCTAssertEqual(result.diagnostics.convolutionSources.first?.sourceFrameCount, 5)
        XCTAssertEqual(result.diagnostics.convolutionSources.first?.targetFrameCount, 5)
    }

    func testTwoAndNineSecondUnitImpulsesCompileToIdenticalRuntimeStages() throws {
        let shortURL = temporaryDirectory.appendingPathComponent("unit-2s.wav")
        let longURL = temporaryDirectory.appendingPathComponent("unit-9s.wav")
        var shortSamples = Array(repeating: Float.zero, count: 96_000)
        var longSamples = Array(repeating: Float.zero, count: 432_000)
        shortSamples[0] = 1
        longSamples[0] = 1
        try wavFloat32(sampleRate: 48_000, channels: [shortSamples]).write(to: shortURL)
        try wavFloat32(sampleRate: 48_000, channels: [longSamples]).write(to: longURL)

        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let nodeID = UUID()
        let short = try M1ProcessingBuilder.build(
            nodes: [.convolution(
                id: nodeID,
                ir: M1ConvolutionIRStore.reference(sourceURL: shortURL)
            )],
            layout: stereoLayout(),
            irLoader: store
        )
        let long = try M1ProcessingBuilder.build(
            nodes: [.convolution(
                id: nodeID,
                ir: M1ConvolutionIRStore.reference(sourceURL: longURL)
            )],
            layout: stereoLayout(),
            irLoader: store
        )

        XCTAssertEqual(short.stagesByChannel, long.stagesByChannel)
        XCTAssertEqual(short.diagnostics.convolutionSources.first?.sourceFrameCount, 96_000)
        XCTAssertEqual(long.diagnostics.convolutionSources.first?.sourceFrameCount, 432_000)
        XCTAssertFalse(try XCTUnwrap(short.diagnostics.convolutionSources.first).hasPerformanceWarning)
        XCTAssertTrue(try XCTUnwrap(long.diagnostics.convolutionSources.first).hasPerformanceWarning)
    }

    func testRejectsMalformedExtensibleEncodingAndUnsupportedSampleRatesWithoutTrapping() throws {
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let malformed = temporaryDirectory.appendingPathComponent("malformed-extensible.wav")
        try wavExtensible(subformatEncoding: 0x0001_0001).write(to: malformed)
        let malformedReference = M1ConvolutionIRStore.reference(sourceURL: malformed)
        XCTAssertThrowsError(try store.load(reference: malformedReference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .unsupportedEncoding)
        }

        let excessiveRate = temporaryDirectory.appendingPathComponent("excessive-rate.wav")
        try wavPCM16(sampleRate: 768_001, channels: [[1]]).write(to: excessiveRate)
        let excessiveReference = M1ConvolutionIRStore.reference(sourceURL: excessiveRate)
        XCTAssertThrowsError(try store.load(reference: excessiveReference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .invalidMetadata)
        }

        let insufficientRate = temporaryDirectory.appendingPathComponent("insufficient-rate.wav")
        try wavPCM16(sampleRate: 7_999, channels: [[1]]).write(to: insufficientRate)
        let insufficientReference = M1ConvolutionIRStore.reference(sourceURL: insufficientRate)
        XCTAssertThrowsError(try store.load(reference: insufficientReference, targetSampleRate: 48_000)) {
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

    func testLoadUsesCurrentSourceContentsAndReportsMissingFile() throws {
        let source = temporaryDirectory.appendingPathComponent("valid.wav")
        try wavPCM16(sampleRate: 48_000, channels: [[1, 0]]).write(to: source)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory.appendingPathComponent("store"))
        let reference = M1ConvolutionIRStore.reference(sourceURL: source)

        let first = try store.load(reference: reference, targetSampleRate: 48_000)
        XCTAssertEqual(first.channels[0][0], 0.999_969, accuracy: 0.000_1)

        try wavPCM16(sampleRate: 48_000, channels: [[0.25, 0]]).write(to: source)
        let reloaded = try store.load(reference: reference, targetSampleRate: 48_000)
        XCTAssertEqual(reloaded.channels[0][0], 0.25, accuracy: 0.000_1)

        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try store.load(reference: reference, targetSampleRate: 48_000)) {
            XCTAssertEqual($0 as? M1ConvolutionIRError, .missingResource)
        }
    }

    func testBuilderBypassesMissingSourceAndRestoresItOnNextBuild() throws {
        let source = temporaryDirectory.appendingPathComponent("recoverable.wav")
        let reference = M1ConvolutionIRStore.reference(sourceURL: source)
        let node = M1ProcessingNode.convolution(ir: reference)
        let store = M1ConvolutionIRStore(directoryURL: temporaryDirectory)

        let missing = try M1ProcessingBuilder.build(
            nodes: [node],
            layout: stereoLayout(),
            irLoader: store
        )
        XCTAssertEqual(missing.stagesByChannel, [[], []])
        XCTAssertEqual(
            missing.diagnostics.convolutionBypasses,
            [
                M1ConvolutionBypassDiagnostic(
                    nodeID: node.id,
                    source: reference,
                    reason: .resource(.missingResource)
                ),
            ]
        )

        try wavFloat32(sampleRate: 48_000, channels: [[1, 0]]).write(to: source)
        let restored = try M1ProcessingBuilder.build(
            nodes: [node],
            layout: stereoLayout(),
            irLoader: store
        )
        XCTAssertTrue(restored.diagnostics.convolutionBypasses.isEmpty)
        XCTAssertEqual(restored.diagnostics.convolutionSources.map(\.nodeID), [node.id])
        XCTAssertEqual(restored.stagesByChannel.map(\.count), [1, 1])
    }

    func testBuilderBypassesSampleRateMismatchWithoutResampling() throws {
        let source = temporaryDirectory.appendingPathComponent("mismatched.wav")
        try wavFloat32(sampleRate: 44_100, channels: [[1, 0]]).write(to: source)
        let reference = M1ConvolutionIRStore.reference(sourceURL: source)
        let node = M1ProcessingNode.convolution(ir: reference)
        let result = try M1ProcessingBuilder.build(
            nodes: [node],
            layout: stereoLayout(),
            irLoader: M1ConvolutionIRStore(directoryURL: temporaryDirectory)
        )

        XCTAssertEqual(result.stagesByChannel, [[], []])
        XCTAssertEqual(
            result.diagnostics.convolutionBypasses,
            [
                M1ConvolutionBypassDiagnostic(
                    nodeID: node.id,
                    source: reference,
                    reason: .resource(.sampleRateMismatch(source: 44_100, target: 48_000))
                ),
            ]
        )
    }

    func testCancelledMissingSourceLoadPreservesCancellation() async {
        let reference = M1ConvolutionIRReference(sourcePath: "/missing/cancelled.wav")
        let store = M1ConvolutionIRStore()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try store.load(reference: reference, targetSampleRate: 48_000)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
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
        XCTAssertFalse(result.diagnostics.convolutionSources[0].hasPerformanceWarning)
        for stages in result.stagesByChannel {
            guard case .gain = stages[0], case let .convolution(nodeID, taps) = stages[1] else {
                return XCTFail("expected Gain followed by Convolution")
            }
            XCTAssertEqual(nodeID, convolution.id)
            XCTAssertFloatArraysEqual(taps, [1], accuracy: 0.000_1)
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

        let mismatched = try M1ProcessingBuilder.build(
            nodes: [.channels(selection: .identifiers([left])), convolution],
            layout: stereoLayout(),
            irLoader: fixture.store
        )
        XCTAssertEqual(mismatched.stagesByChannel, [[], []])
        XCTAssertEqual(
            mismatched.diagnostics.convolutionBypasses,
            [
                M1ConvolutionBypassDiagnostic(
                    nodeID: convolution.id,
                    source: reference,
                    reason: .channelCountMismatch(expected: 1, actual: 2)
                ),
            ]
        )
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

    func testBuilderAccumulatesSerialLatencyAndAllowsFormerTotalTapBoundary() throws {
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

        var longTaps = Array(repeating: Float.zero, count: 65_537)
        longTaps[0] = 1
        longTaps[longTaps.count - 1] = 0.5
        let long = try makeStore(channels: [longTaps])
        let compiled = try M1ProcessingBuilder.build(
            nodes: [.convolution(ir: long.reference!)],
            layout: stereoLayout(),
            irLoader: long.store
        )
        XCTAssertEqual(compiled.stagesByChannel.map(\.count), [1, 1])
        let prepared = try M1RuntimePreparedStateFactory.create(stagesByChannel: compiled.stagesByChannel)
        EAUM1PreparedStateDestroy(prepared)
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

    func testCancelledPreparedCreationStopsBeforeNativeWork() async {
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try M1RuntimePreparedStateFactory.create(stagesByChannel: [[
                    .convolution(nodeID: UUID(), taps: [1]),
                ]])
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }

    private func makeStore(channels: [[Float]]) throws -> (store: M1ConvolutionIRStore, reference: M1ConvolutionIRReference?) {
        let source = temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        try wavFloat32(sampleRate: 48_000, channels: channels).write(to: source)
        let store = M1ConvolutionIRStore(
            directoryURL: temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        )
        return (store, M1ConvolutionIRStore.reference(sourceURL: source))
    }

    private func reference(storageID: UUID) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(sourcePath: "/missing/\(storageID.uuidString).wav")
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
