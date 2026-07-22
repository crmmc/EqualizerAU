import Foundation
import XCTest
@testable import EqualizerAUM1

final class M1RuntimeBootstrapTests: XCTestCase {
    func testAppLinksIndependentRuntime() {
        XCTAssertEqual(M1RuntimeBootstrap.abiVersion, EAUM1_RUNTIME_ABI_VERSION)
    }

    func testAppBuildIncludesTypedProcessingModel() {
        let node = M1PreampNode(
            id: UUID(),
            isEnabled: true,
            gainDB: 0,
            channels: .all
        )

        XCTAssertTrue(node.isEnabled)
        XCTAssertEqual(node.channels, .all)
    }

    func testAppProhibitsMultipleLaunchServicesInstances() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool,
            true
        )
    }
}
