// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AstroberryCore

final class Build31_9_4AnimatedStatusTests: XCTestCase {
    func testSingleAnimatedHostIsDefaultAndCanFallBack() {
        XCTAssertTrue(AnimatedStatusItemPolicy.useAnimatedHost(arguments: ["Astroberry VNC"]))
        XCTAssertFalse(AnimatedStatusItemPolicy.useAnimatedHost(arguments: [
            "Astroberry VNC", "--legacy-static-menu"
        ]))
    }

    func testBothTransientStatesUseExactlyOneSecondPerRevolution() {
        XCTAssertEqual(AnimatedStatusItemPolicy.rotationDuration(
            for: .connecting, reduceMotion: false), 1.0)
        XCTAssertEqual(AnimatedStatusItemPolicy.rotationDuration(
            for: .disconnecting, reduceMotion: false), 1.0)
    }

    func testStaticStatesNeverRotate() {
        for status: ConnectionStatus in [.disconnected, .connected, .error] {
            XCTAssertNil(AnimatedStatusItemPolicy.rotationDuration(
                for: status, reduceMotion: false))
        }
    }

    func testReduceMotionSuppressesAllRotation() {
        for status: ConnectionStatus in [
            .disconnected, .connecting, .connected, .disconnecting, .error
        ] {
            XCTAssertNil(AnimatedStatusItemPolicy.rotationDuration(
                for: status, reduceMotion: true))
        }
    }
}
