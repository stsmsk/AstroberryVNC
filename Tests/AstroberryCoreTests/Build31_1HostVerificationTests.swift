// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_1HostVerificationTests: XCTestCase {
    func testChangedSSHHostWithoutKnownHostIsNotApprovalReady() {
        let status = SSHHostVerificationPresentation.evaluate(
            configured: true, hasError: false, hasPendingApproval: false,
            hostIsKnown: false
        )
        XCTAssertEqual(status, .notVerified)
        XCTAssertEqual(status.title, "SSH host not verified")
    }

    func testOnlyScannedFingerprintMayRequireApproval() {
        XCTAssertEqual(SSHHostVerificationPresentation.evaluate(
            configured: true, hasError: false, hasPendingApproval: true,
            hostIsKnown: false
        ), .approvalRequired)
    }

    func testTrustedAndCheckingStates() {
        XCTAssertEqual(SSHHostVerificationPresentation.evaluate(
            configured: true, hasError: false, hasPendingApproval: false,
            hostIsKnown: true
        ), .verified)
        XCTAssertEqual(SSHHostVerificationPresentation.evaluate(
            configured: true, hasError: false, hasPendingApproval: false,
            hostIsKnown: nil
        ), .checking)
    }

    func testInvalidAndFailedHostStates() {
        XCTAssertEqual(SSHHostVerificationPresentation.evaluate(
            configured: false, hasError: false, hasPendingApproval: false,
            hostIsKnown: nil
        ), .notConfigured)
        XCTAssertEqual(SSHHostVerificationPresentation.evaluate(
            configured: true, hasError: true, hasPendingApproval: false,
            hostIsKnown: false
        ), .error)
    }
}
