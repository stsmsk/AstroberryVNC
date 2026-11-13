// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_3QuitCleanupTests: XCTestCase {
    private func assess(
        settled: Bool = true,
        viewer: QuitResourceState = .stopped,
        tunnel: QuitResourceState = .stopped,
        forwarding: QuitResourceState = .stopped
    ) -> ApplicationQuitCleanupResult {
        ApplicationQuitCleanupPolicy.assess(
            connectionTaskFinished: settled, viewer: viewer,
            tunnel: tunnel, forwarding: forwarding
        )
    }

    func testQuitAllowedOnlyAfterEveryResourceStopped() {
        XCTAssertEqual(assess(), .complete)
    }

    func testQuitIsBlockedWhileConnectIsStillRunning() {
        XCTAssertEqual(assess(settled: false),
                       .incomplete("An SSH connection operation is still running."))
    }

    func testQuitBlockedWhenSSHMasterStillRuns() {
        let result = assess(tunnel: .running)
        guard case .incomplete(let reason) = result else { return XCTFail("Quit should be blocked") }
        XCTAssertTrue(reason.contains("SSH tunnel is still running"))
    }

    func testQuitBlockedWhenViewerDidNotExit() {
        let result = assess(viewer: .running)
        guard case .incomplete(let reason) = result else { return XCTFail("Quit should be blocked") }
        XCTAssertTrue(reason.contains("TigerVNC Viewer"))
    }

    func testQuitBlockedIfLocalForwardingStillListens() {
        let result = assess(forwarding: .running)
        guard case .incomplete(let reason) = result else { return XCTFail("Quit should be blocked") }
        XCTAssertTrue(reason.contains("Local VNC forwarding"))
    }

    func testUnconfirmedSSHCheckNeverMeansStopped() {
        let result = assess(tunnel: .unknown("SSH control socket check timed out"))
        guard case .incomplete(let reason) = result else { return XCTFail("Quit should be blocked") }
        XCTAssertTrue(reason.contains("Could not verify SSH tunnel"))
    }

    func testMultipleProblemsAreAllReported() {
        let result = assess(viewer: .running, tunnel: .running,
                            forwarding: .unknown("lsof timeout"))
        guard case .incomplete(let reason) = result else { return XCTFail("Quit should be blocked") }
        XCTAssertTrue(reason.contains("TigerVNC Viewer"))
        XCTAssertTrue(reason.contains("SSH tunnel"))
        XCTAssertTrue(reason.contains("lsof timeout"))
    }
}
