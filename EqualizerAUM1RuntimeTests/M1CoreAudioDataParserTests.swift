import AudioToolbox
import CoreAudio
import Foundation
import XCTest

final class M1CoreAudioDataParserTests: XCTestCase {
    func testCompactTaggedStereoLayoutExpandsWithoutReadingPastHeader() throws {
        let data = channelLayoutData(tag: kAudioChannelLayoutTag_Stereo)
        let positions = try M1CoreAudioDataParser.semanticPositions(data, expectedCount: 2)
        XCTAssertEqual(positions.map { $0?.rawValue }, ["L", "R"])
    }

    func testBitmapLayoutExpandsExplicitSpeakerPositions() throws {
        let bitmap = AudioChannelBitmap(rawValue: (1 << 0) | (1 << 1) | (1 << 2))
        let data = channelLayoutData(
            tag: kAudioChannelLayoutTag_UseChannelBitmap,
            bitmap: bitmap
        )
        let positions = try M1CoreAudioDataParser.semanticPositions(data, expectedCount: 3)
        XCTAssertEqual(positions.map { $0?.rawValue }, ["L", "R", "C"])
    }

    func testDescriptionLayoutPreservesUnknownPositionAsNil() throws {
        let data = descriptionLayoutData(labels: [
            kAudioChannelLabel_Left,
            kAudioChannelLabel_Unknown,
            kAudioChannelLabel_Right,
        ])
        let positions = try M1CoreAudioDataParser.semanticPositions(data, expectedCount: 3)
        XCTAssertEqual(positions[0]?.rawValue, "L")
        XCTAssertNil(positions[1])
        XCTAssertEqual(positions[2]?.rawValue, "R")
    }

    func testTruncatedAndCountMismatchedLayoutsAreRejected() throws {
        let compact = channelLayoutData(tag: kAudioChannelLayoutTag_Stereo)
        XCTAssertThrowsError(
            try M1CoreAudioDataParser.semanticPositions(Data(compact.dropLast()), expectedCount: 2)
        )
        XCTAssertThrowsError(
            try M1CoreAudioDataParser.semanticPositions(compact, expectedCount: 3)
        )

        var descriptions = descriptionLayoutData(labels: [kAudioChannelLabel_Left])
        descriptions.removeLast()
        XCTAssertThrowsError(
            try M1CoreAudioDataParser.semanticPositions(descriptions, expectedCount: 1)
        )
    }

    func testPCMFormatRequiresExactNativePackedFloatGeometry() {
        let validInterleaved = M1HALPCMFormat(
            sampleRate: 48_000,
            channelCount: 2,
            isNativeFloat32: true,
            isPacked: true,
            isNonInterleaved: false,
            framesPerPacket: 1,
            bytesPerFrame: 8,
            bytesPerPacket: 8
        )
        XCTAssertTrue(validInterleaved.isSupported)

        let validPlanar = M1HALPCMFormat(
            sampleRate: 48_000,
            channelCount: 2,
            isNativeFloat32: true,
            isPacked: true,
            isNonInterleaved: true,
            framesPerPacket: 1,
            bytesPerFrame: 4,
            bytesPerPacket: 4
        )
        XCTAssertTrue(validPlanar.isSupported)

        let invalidValues = [
            M1HALPCMFormat(sampleRate: .infinity, channelCount: 2, isNativeFloat32: true, isPacked: true, isNonInterleaved: false, framesPerPacket: 1, bytesPerFrame: 8, bytesPerPacket: 8),
            M1HALPCMFormat(sampleRate: 48_000, channelCount: 2, isNativeFloat32: false, isPacked: true, isNonInterleaved: false, framesPerPacket: 1, bytesPerFrame: 8, bytesPerPacket: 8),
            M1HALPCMFormat(sampleRate: 48_000, channelCount: 2, isNativeFloat32: true, isPacked: false, isNonInterleaved: false, framesPerPacket: 1, bytesPerFrame: 8, bytesPerPacket: 8),
            M1HALPCMFormat(sampleRate: 48_000, channelCount: 2, isNativeFloat32: true, isPacked: true, isNonInterleaved: false, framesPerPacket: 2, bytesPerFrame: 8, bytesPerPacket: 8),
            M1HALPCMFormat(sampleRate: 48_000, channelCount: 2, isNativeFloat32: true, isPacked: true, isNonInterleaved: false, framesPerPacket: 1, bytesPerFrame: 4, bytesPerPacket: 4),
        ]
        XCTAssertTrue(invalidValues.allSatisfy { !$0.isSupported })
    }
}

private func channelLayoutData(
    tag: AudioChannelLayoutTag,
    bitmap: AudioChannelBitmap = AudioChannelBitmap(rawValue: 0)
) -> Data {
    let headerSize = MemoryLayout<AudioChannelLayout>.offset(
        of: \AudioChannelLayout.mChannelDescriptions
    )!
    var data = Data(count: headerSize)
    write(tag, to: &data, at: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelLayoutTag)!)
    write(bitmap, to: &data, at: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelBitmap)!)
    write(UInt32(0), to: &data, at: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mNumberChannelDescriptions)!)
    return data
}

private func descriptionLayoutData(labels: [AudioChannelLabel]) -> Data {
    let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(
        of: \AudioChannelLayout.mChannelDescriptions
    )!
    var data = Data(count: descriptionsOffset + labels.count * MemoryLayout<AudioChannelDescription>.stride)
    write(
        kAudioChannelLayoutTag_UseChannelDescriptions,
        to: &data,
        at: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelLayoutTag)!
    )
    write(
        UInt32(labels.count),
        to: &data,
        at: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mNumberChannelDescriptions)!
    )
    for (index, label) in labels.enumerated() {
        var description = AudioChannelDescription()
        description.mChannelLabel = label
        write(
            description,
            to: &data,
            at: descriptionsOffset + index * MemoryLayout<AudioChannelDescription>.stride
        )
    }
    return data
}

private func write<T>(_ value: T, to data: inout Data, at offset: Int) {
    var value = value
    withUnsafeBytes(of: &value) { bytes in
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
