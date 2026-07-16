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
}
