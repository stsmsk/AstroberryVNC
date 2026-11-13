// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_4VNCBindingTests: XCTestCase {
    private let port = 5970

    private func line(_ local: String) -> String {
        "LISTEN 0 5 \(local) 0.0.0.0:*"
    }

    private func inspect(_ output: String) -> VNCBindingState {
        RemoteVNCBindingInspector.inspect(output: output, port: port)
    }

    private func assertUnconfirmed(_ output: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unconfirmed(let reason) = inspect(output) else {
            return XCTFail("Expected unconfirmed, got \(inspect(output))", file: file, line: line)
        }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }

    private func assertUnsafe(_ output: String, address: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(inspect(output), .unsafe(address), file: file, line: line)
    }

    func testSingleIPv4LoopbackPasses() {
        XCTAssertEqual(inspect(line("127.0.0.1:5970")), .loopbackOnly)
    }

    func testOtherIPv4LoopbackIn127BlockPasses() {
        XCTAssertEqual(inspect(line("127.0.0.2:5970")), .loopbackOnly)
    }

    func testBracketedAndUnbracketedIPv6LoopbackPass() {
        XCTAssertEqual(inspect(line("[::1]:5970")), .loopbackOnly)
        XCTAssertEqual(inspect(line("::1:5970")), .loopbackOnly)
        XCTAssertEqual(inspect(line("[0:0:0:0:0:0:0:1]:5970")), .loopbackOnly)
    }

    func testMultipleSafeListenersPass() {
        XCTAssertEqual(inspect(line("127.0.0.1:5970") + "\n" + line("[::1]:5970")), .loopbackOnly)
    }

    func testOptionalTcpNetidPrefixPasses() {
        XCTAssertEqual(inspect("tcp " + line("127.0.0.1:5970")), .loopbackOnly)
        XCTAssertEqual(inspect("tcp6 " + line("[::1]:5970")), .loopbackOnly)
    }

    func testWildcardIPv4AndIPv6AreUnsafe() {
        assertUnsafe(line("0.0.0.0:5970"), address: "0.0.0.0:5970")
        assertUnsafe(line("[::]:5970"), address: "[::]:5970")
        assertUnsafe(line(":::5970"), address: ":::5970")
        assertUnsafe(line("*:5970"), address: "*:5970")
    }

    func testNonLoopbackIPv4AndIPv6AreUnsafe() {
        assertUnsafe(line("192.168.0.2:5970"), address: "192.168.0.2:5970")
        assertUnsafe(line("[fe80::1]:5970"), address: "[fe80::1]:5970")
        assertUnsafe(line("[2001:db8::1]:5970"), address: "[2001:db8::1]:5970")
    }

    func testAnyUnsafeListenerOverridesSafeListeners() {
        let output = line("127.0.0.1:5970") + "\n" + line("0.0.0.0:5970")
        assertUnsafe(output, address: "0.0.0.0:5970")
    }

    func testUnsafeListenerOverridesOtherMalformedLines() {
        let output = "unexpected row\n" + line("[::1]:5970") + "\n" + line("[::]:5970")
        assertUnsafe(output, address: "[::]:5970")
    }

    func testMalformedAndShortRowsCannotSilentlyPass() {
        assertUnconfirmed("LISTEN 0 5")
        assertUnconfirmed("random output")
        assertUnconfirmed("LISTEN - 5 127.0.0.1:5970 0.0.0.0:*")
        assertUnconfirmed("LISTEN 0 5 [::1:5970 [::]:*")
    }

    func testMixedSafeAndMalformedOutputIsUnconfirmed() {
        assertUnconfirmed(line("127.0.0.1:5970") + "\nnot a listener")
    }

    func testWrongPortAndUnexpectedHeaderAreUnconfirmed() {
        assertUnconfirmed(line("127.0.0.1:5971"))
        assertUnconfirmed("State Recv-Q Send-Q Local Peer\n" + line("127.0.0.1:5970"))
    }

    func testUnknownHostnameIsUnconfirmed() {
        assertUnconfirmed(line("localhost:5970"))
        assertUnconfirmed(line("127.0.0.1%lo:5970"))
    }

    func testEmptyAndTruncatedOutputAreUnconfirmed() {
        assertUnconfirmed("")
        assertUnconfirmed(" \n ")
        assertUnconfirmed(line("127.0.0.1:5970") + "\n[Output truncated after 1 MiB]")
    }

    func testInvalidRequestedPortCannotPass() {
        guard case .unconfirmed = RemoteVNCBindingInspector.inspect(output: line("127.0.0.1:5970"), port: 0) else {
            return XCTFail("Port zero must fail closed")
        }
    }

    func testSafetyGateAllowsOnlyVerifiedLoopback() {
        XCTAssertNil(VNCBindingSafetyGate.connectionFailure(for: .loopbackOnly, remotePort: port))
        let unsafe = VNCBindingSafetyGate.connectionFailure(for: .unsafe("0.0.0.0:5970"), remotePort: port)
        XCTAssertTrue(unsafe?.localizedDescription.contains("non-loopback") ?? false)
        let unknown = VNCBindingSafetyGate.connectionFailure(for: .unconfirmed("ss is not installed"), remotePort: port)
        XCTAssertTrue(unknown?.localizedDescription.contains("connection was blocked") ?? false)
        XCTAssertTrue(unknown?.localizedDescription.contains("ss is not installed") ?? false)
        XCTAssertTrue(unknown?.localizedDescription.contains(":5970") ?? false)
    }
}
