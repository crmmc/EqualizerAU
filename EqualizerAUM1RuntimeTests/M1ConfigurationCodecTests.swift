import Foundation
import XCTest

final class M1ConfigurationCodecTests: XCTestCase {
    func testCanonicalRoundTripPreservesNodeOrderAndNormalizesChannels() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let source = Data(
            """
            {"nodes":[{"type":"preamp","channels":[" l ","02"],"gainDB":-3.5,"isEnabled":true,"id":"\(firstID.uuidString)"},{"gainDB":4,"id":"\(secondID.uuidString)","isEnabled":false,"channels":"all","type":"preamp"}],"effectsEnabled":false,"schemaVersion":1}
            """.utf8
        )

        let decoded = try M1ConfigurationCodec.decode(source)

        XCTAssertEqual(decoded.snapshot.nodes.map(\.kind), [.channels, .preamp, .channels, .preamp])
        XCTAssertEqual(
            decoded.snapshot.nodes.filter { $0.kind == .preamp }.map(\.id),
            [firstID, secondID]
        )
        XCTAssertEqual(
            decoded.snapshot.nodes[0].channels,
            .identifiers([M1ChannelIdentifier("L")!, M1ChannelIdentifier("2")!])
        )
        XCTAssertEqual(decoded.snapshot.nodes[2].channels, .all)
        XCTAssertTrue(decoded.data.last == 0x0A)
        XCTAssertEqual(decoded, try M1ConfigurationCodec.decode(decoded.data))
        let text = try XCTUnwrap(String(data: decoded.data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"channels\" : \"all\""))
        XCTAssertTrue(text.contains("\"type\" : \"preamp\""))
    }

    func testInitialAndRecoveryConfigurationsAreTransparent() throws {
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let initial = M1ConfigurationSnapshot.initial(nodeID: nodeID)

        XCTAssertTrue(initial.effectsEnabled)
        XCTAssertEqual(initial.nodes.count, 1)
        XCTAssertEqual(initial.nodes[0].id, nodeID)
        XCTAssertEqual(initial.nodes[0].gainDB, 0)
        XCTAssertEqual(initial.nodes[0].channels, .all)
        XCTAssertEqual(M1ConfigurationSnapshot.transparentRecovery.nodes, [])
        XCTAssertNoThrow(try M1ProcessingBuilder.validate(nodes: initial.nodes))
    }

    func testCanonicalFourMiBBudgetAcceptsBoundaryAndRejectsNextByte() throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let small = configuration(id: id, channel: "X")
        let smallSize = try M1ConfigurationCodec.encode(small).data.count
        let boundaryLength = M1ConfigurationCodec.maximumDataSize - smallSize + 1
        let boundary = configuration(id: id, channel: String(repeating: "X", count: boundaryLength))

        let encoded = try M1ConfigurationCodec.encode(boundary)
        XCTAssertEqual(encoded.data.count, M1ConfigurationCodec.maximumDataSize)
        XCTAssertEqual(try M1ConfigurationCodec.decode(encoded.data), encoded)

        var oversizedData = encoded.data
        oversizedData.append(0x20)
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(oversizedData))

        let oversized = configuration(id: id, channel: String(repeating: "X", count: boundaryLength + 1))
        XCTAssertThrowsError(try M1ConfigurationCodec.encode(oversized)) { error in
            guard case let M1ConfigurationCodecError.exceedsMaximumSize(actual, maximum) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, maximum + 1)
        }
    }

    func testUnsupportedSchemaAndUnknownNodeAreRejected() {
        let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let unsupported = Data(
            "{\"schemaVersion\":3,\"effectsEnabled\":true,\"nodes\":[]}".utf8
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(unsupported)) { error in
            XCTAssertEqual(error as? M1ConfigurationCodecError, .unsupportedSchema(3))
        }

        let unknown = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"biquad\"}]}".utf8
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(unknown)) { error in
            XCTAssertEqual(error as? M1ConfigurationCodecError, .unknownNodeType("biquad"))
        }
    }

    func testVersionOneMigrationIsDeterministicAndVersionTwoOmitsPreampChannels() throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let source = Data(
            "{\"schemaVersion\":1,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":-6,\"channels\":[\"L\"]}]}".utf8
        )

        let first = try M1ConfigurationCodec.decode(source)
        let second = try M1ConfigurationCodec.decode(source)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshot.nodes.map(\.kind), [.channels, .preamp])
        XCTAssertEqual(first.snapshot.nodes[1].id, id)
        let text = try XCTUnwrap(String(data: first.data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(text.contains("\"type\" : \"channels\""))
        XCTAssertFalse(text.contains("\"channels\" : \"all\""))
    }

    func testVersionOneMigrationAvoidsDeterministicIDCollisions() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let seed = Data(
            "{\"schemaVersion\":1,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(firstID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"channels\":[\"L\"]}]}".utf8
        )
        let collidingID = try M1ConfigurationCodec.decode(seed).snapshot.nodes[0].id
        let source = Data(
            "{\"schemaVersion\":1,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(firstID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"channels\":[\"L\"]},{\"id\":\"\(collidingID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"channels\":\"all\"}]}".utf8
        )

        let first = try M1ConfigurationCodec.decode(source)
        let second = try M1ConfigurationCodec.decode(source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.snapshot.nodes.map(\.id)).count, first.snapshot.nodes.count)
        XCTAssertEqual(first.snapshot.nodes.filter { $0.kind == .preamp }.map(\.id), [firstID, collidingID])
    }

    func testVersionTwoRejectsFieldsOwnedByAnotherNodeKind() {
        let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let channelsWithGain = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"channels\",\"channels\":\"all\",\"gainDB\":1}]}".utf8
        )
        let preampWithChannels = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":1,\"channels\":\"all\"}]}".utf8
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(channelsWithGain))
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(preampWithChannels))
    }

    func testVersionTwoRejectsUnknownTopLevelAndNodeFields() {
        let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let unknownTopLevel = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[],\"future\":true}".utf8
        )
        let unknownNodeField = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"future\":true}]}".utf8
        )
        let duplicateTopLevel = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"effectsEnabled\":false,\"nodes\":[]}".utf8
        )
        let duplicateNodeField = Data(
            "{\"schemaVersion\":2,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"gainDB\":1}]}".utf8
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(unknownTopLevel))
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(unknownNodeField))
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(duplicateTopLevel))
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(duplicateNodeField))
    }

    func testCanonicalFormattingPreservesSlashesAndHasOneTrailingLF() throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let encoded = try M1ConfigurationCodec.encode(configuration(id: id, channel: "A/B"))
        let text = try XCTUnwrap(String(data: encoded.data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"A/B\""))
        XCTAssertFalse(text.contains("A\\/B"))
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(text.hasSuffix("}\n\n"))
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"effectsEnabled\"")?.lowerBound),
            try XCTUnwrap(text.range(of: "\"nodes\"")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"nodes\"")?.lowerBound),
            try XCTUnwrap(text.range(of: "\"schemaVersion\"")?.lowerBound)
        )
    }

    func testDeviceIndependentValidationRejectsInvalidNodesWithoutLayout() {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let duplicate = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [
                M1PreampNode(id: id, isEnabled: true, gainDB: 0, channels: .all),
                M1PreampNode(id: id, isEnabled: true, gainDB: 0, channels: .all)
            ]
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.encode(duplicate)) { error in
            XCTAssertEqual(
                error as? M1ConfigurationCodecError,
                .invalidConfiguration(.duplicateNodeID(id))
            )
        }

        let outOfRange = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [M1PreampNode(id: id, isEnabled: true, gainDB: 100.1, channels: .all)]
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.encode(outOfRange))
    }

    func testEmptyAndDuplicateChannelSelectionsAreRejectedOnDecode() {
        let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        for channels in ["[]", "[\"L\",\" l \"]"] {
            let data = Data(
                "{\"schemaVersion\":1,\"effectsEnabled\":true,\"nodes\":[{\"id\":\"\(id)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":0,\"channels\":\(channels)}]}".utf8
            )
            XCTAssertThrowsError(try M1ConfigurationCodec.decode(data))
        }
    }

    private func configuration(id: UUID, channel: String) -> M1ConfigurationSnapshot {
        M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [
                M1PreampNode(
                    id: id,
                    isEnabled: true,
                    gainDB: 0,
                    channels: .identifiers([M1ChannelIdentifier(channel)!])
                )
            ]
        )
    }
}
