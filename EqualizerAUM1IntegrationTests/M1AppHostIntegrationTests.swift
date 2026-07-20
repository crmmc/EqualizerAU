import XCTest
@testable import EqualizerAUM1

final class M1AppHostIntegrationTests: XCTestCase {
    func testM1HostLoadsWithoutStartingAudio() {
        XCTAssertEqual(M1RuntimeBootstrap.abiVersion, EAUM1_RUNTIME_ABI_VERSION)
    }
}
