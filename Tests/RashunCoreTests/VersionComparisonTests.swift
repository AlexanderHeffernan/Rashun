import XCTest
@testable import RashunCore

final class VersionComparisonTests: XCTestCase {

    func testVersionString_prefersEnvironmentVariable() {
        let version = Versioning.versionString(
            environment: ["RASHUN_VERSION": "9.8.7"],
            generatedVersion: "1.2.3",
            bundleVersionProvider: { "16.0" },
            nearbyInfoPlistVersion: { "4.5.6" }
        )
        XCTAssertEqual(version, "9.8.7")
    }

    func testVersionString_prefersGeneratedVersionOverNearbyInfoPlist() {
        let version = Versioning.versionString(
            environment: [:],
            generatedVersion: "1.2.3",
            bundleVersionProvider: { nil },
            nearbyInfoPlistVersion: { "4.5.6" }
        )
        XCTAssertEqual(version, "1.2.3")
    }

    func testVersionString_fallsBackToNearbyInfoPlistWhenGeneratedIsDefault() {
        let version = Versioning.versionString(
            environment: [:],
            generatedVersion: "0.0.0",
            bundleVersionProvider: { nil },
            nearbyInfoPlistVersion: { "4.5.6" }
        )
        XCTAssertEqual(version, "4.5.6")
    }

    func testNewer_patchBump() {
        XCTAssertTrue(isNewerVersion("0.1.2", than: "0.1.1"))
    }

    func testNewer_minorBump() {
        XCTAssertTrue(isNewerVersion("0.2.0", than: "0.1.9"))
    }

    func testNewer_majorBump() {
        XCTAssertTrue(isNewerVersion("1.0.0", than: "0.9.9"))
    }

    func testNotNewer_sameVersion() {
        XCTAssertFalse(isNewerVersion("0.1.1", than: "0.1.1"))
    }

    func testNotNewer_olderPatch() {
        XCTAssertFalse(isNewerVersion("0.1.0", than: "0.1.1"))
    }

    func testNotNewer_olderMinor() {
        XCTAssertFalse(isNewerVersion("0.1.5", than: "0.2.0"))
    }

    func testNewer_differentLengths() {
        XCTAssertTrue(isNewerVersion("0.1.1", than: "0.1"))
    }

    func testNotNewer_shorterVersionEqual() {
        XCTAssertFalse(isNewerVersion("0.1", than: "0.1.0"))
    }

    func testNewer_twoDigitComponents() {
        XCTAssertTrue(isNewerVersion("0.10.0", than: "0.9.0"))
    }
}
