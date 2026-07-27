import XCTest

@testable import Rashun

final class TailscaleServeControllerTests: XCTestCase {
    func testParsesRunningIdentityAndTrimsDNSDot() {
        let data = Data(
            #"{"BackendState":"Running","Self":{"DNSName":"rashun-mac.example.ts.net."}}"#.utf8)
        let value = TailscaleServeController.parseIdentity(data)
        XCTAssertEqual(value?.dnsName, "rashun-mac.example.ts.net")
        XCTAssertEqual(value?.running, true)
    }

    func testRecognizesOnlyRashunRootProxy() {
        let enabled = Data(
            #"{"Web":{"rashun-mac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}"#
                .utf8)
        let other = Data(
            #"{"Web":{"rashun-mac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
                .utf8)
        XCTAssertEqual(
            TailscaleServeController.parseServeStatus(
                enabled, dnsName: "rashun-mac.example.ts.net")?
                .enabled, true)
        XCTAssertEqual(
            TailscaleServeController.parseServeStatus(
                enabled, dnsName: "rashun-mac.example.ts.net")?
                .conflict, false)
        XCTAssertEqual(
            TailscaleServeController.parseServeStatus(other, dnsName: "rashun-mac.example.ts.net")?
                .enabled, false)
        XCTAssertEqual(
            TailscaleServeController.parseServeStatus(other, dnsName: "rashun-mac.example.ts.net")?
                .conflict, true)
    }

    func testParseServeStatusUsesConfiguredPort() {
        let data = Data(
            #"{"Web":{"rashun-mac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9123"}}}}}"#
                .utf8)

        let status = TailscaleServeController.parseServeStatus(
            data, dnsName: "rashun-mac.example.ts.net", port: 9123)

        XCTAssertEqual(status?.enabled, true)
        XCTAssertEqual(status?.conflict, false)
    }

    func testSyncServerPortValidation() {
        XCTAssertTrue(SettingsStore.isValidSyncServerPort(8787))
        XCTAssertTrue(SettingsStore.isValidSyncServerPort(65_535))
        XCTAssertFalse(SettingsStore.isValidSyncServerPort(0))
        XCTAssertFalse(SettingsStore.isValidSyncServerPort(65_536))
    }

    func testPortDraftValidationPreservesDefaultAndBounds() {
        XCTAssertEqual(SyncPreferencesViewModel.validatedPort("8787"), 8787)
        XCTAssertEqual(SyncPreferencesViewModel.validatedPort("1"), 1)
        XCTAssertEqual(SyncPreferencesViewModel.validatedPort("65535"), 65_535)
        XCTAssertNil(SyncPreferencesViewModel.validatedPort(""))
        XCTAssertNil(SyncPreferencesViewModel.validatedPort("0"))
        XCTAssertNil(SyncPreferencesViewModel.validatedPort("65536"))
        XCTAssertNil(SyncPreferencesViewModel.validatedPort("not-a-port"))
    }
}
