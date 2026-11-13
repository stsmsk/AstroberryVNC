// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_7QuitViewerTests: XCTestCase {
    func testExplicitQuitCanEscalateForStillRunningViewer() {
        XCTAssertTrue(ViewerTerminationPolicy.shouldForceTerminate(
            forceIfNeeded: true, isTerminated: false
        ))
    }

    func testOrdinaryDisconnectNeverForceTerminatesViewer() {
        XCTAssertFalse(ViewerTerminationPolicy.shouldForceTerminate(
            forceIfNeeded: false, isTerminated: false
        ))
    }

    func testAlreadyTerminatedViewerNeverEscalates() {
        XCTAssertFalse(ViewerTerminationPolicy.shouldForceTerminate(
            forceIfNeeded: true, isTerminated: true
        ))
    }

    func testQuitStillChecksViewerStateBeforeAcceptingCleanup() {
        XCTAssertEqual(ApplicationQuitCleanupPolicy.assess(
            connectionTaskFinished: true, viewer: .running, tunnel: .stopped,
            forwarding: .stopped
        ), .incomplete("TigerVNC Viewer is still running."))
    }
}
