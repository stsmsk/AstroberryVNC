// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build30StabilityTests: XCTestCase {
    func testLatestStatusProbeWinsForSameKeyPath() {
        var requests = SSHKeyStatusRefreshRequests()
        let older = requests.begin(for: "/tmp/example-id_ed25519")
        XCTAssertTrue(requests.isCurrent(older, for: "/tmp/example-id_ed25519"))
        let newer = requests.begin(for: "/tmp/example-id_ed25519")
        XCTAssertFalse(requests.isCurrent(older, for: "/tmp/example-id_ed25519"))
        XCTAssertTrue(requests.isCurrent(newer, for: "/tmp/example-id_ed25519"))
    }

    func testDifferentKeyPathsHaveIndependentProbeOrder() {
        var requests = SSHKeyStatusRefreshRequests()
        let firstA = requests.begin(for: "/tmp/key-a")
        let firstB = requests.begin(for: "/tmp/key-b")
        _ = requests.begin(for: "/tmp/key-a")
        XCTAssertFalse(requests.isCurrent(firstA, for: "/tmp/key-a"))
        XCTAssertTrue(requests.isCurrent(firstB, for: "/tmp/key-b"))
        XCTAssertFalse(requests.isCurrent(firstB, for: "/tmp/key-a"))
    }

    func testExpandedConnectionErrorGuidanceKeepsOriginalDetails() {
        let cases: [(raw: String, expected: String)] = [
            ("sign_and_send_pubkey: signing failed: agent refused operation", "SSH agent could not sign"),
            ("WARNING: UNPROTECTED PRIVATE KEY FILE!", "private-key file permissions"),
            ("Network is unreachable", "SSH server is unreachable"),
            ("No route to host", "SSH server is unreachable"),
            ("Connection reset by peer", "closed by the remote host"),
            ("Connection closed by 192.0.2.1 port 22", "closed by the remote host")
        ]
        for entry in cases {
            let value = SSHConnectionErrorFormatter.description(for: entry.raw)
            XCTAssertTrue(value.contains(entry.expected), "Wrong diagnostic for \(entry.raw): \(value)")
            XCTAssertTrue(value.contains(entry.raw), "Original diagnostic must remain available")
        }
        XCTAssertEqual(SSHConnectionErrorFormatter.description(for: ""), "SSH tunnel or connection failed.")
    }
}
