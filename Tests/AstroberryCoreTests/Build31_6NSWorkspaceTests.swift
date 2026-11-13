// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_6NSWorkspaceTests: XCTestCase {
    func testViewerArgumentsUseSafePasswordlessTunnel() {
        XCTAssertEqual(ViewerLaunchPolicy.arguments(localPort: 5970), [
            "-SecurityTypes=None", "-ReconnectOnError=0", "127.0.0.1::5970"
        ])
    }

    func testLaunchArgumentsDoNotContainOpenOrProcessDiscoveryFlags() {
        let args = ViewerLaunchPolicy.arguments(localPort: 5970)!
        XCTAssertFalse(args.contains("-na"))
        XCTAssertFalse(args.contains("--args"))
        XCTAssertFalse(args.contains(where: { $0.contains("pgrep") || $0.contains("kill") }))
    }

    func testRejectsInvalidForwardingPorts() {
        for port in [-1, 0, 65536, 100000] {
            XCTAssertNil(ViewerLaunchPolicy.arguments(localPort: port))
        }
    }

    func testFirstAndLastPortAreValid() {
        XCTAssertEqual(ViewerLaunchPolicy.arguments(localPort: 1)?.last, "127.0.0.1::1")
        XCTAssertEqual(ViewerLaunchPolicy.arguments(localPort: 65535)?.last, "127.0.0.1::65535")
    }

    func testRunningApplicationRequiresCleanup() {
        XCTAssertEqual(ViewerLaunchPolicy.resourceState(isTerminated: false), .running)
    }

    func testTerminatedApplicationIsSafeToRelease() {
        XCTAssertEqual(ViewerLaunchPolicy.resourceState(isTerminated: true), .stopped)
    }

    func testNoApplicationHandleHasNoOwnedViewer() {
        XCTAssertEqual(ViewerLaunchPolicy.resourceState(isTerminated: nil), .stopped)
    }
}
