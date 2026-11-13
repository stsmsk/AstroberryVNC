// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_9_2IconExperimentTests: XCTestCase {
    func testOutlineIsLighterAndStandMatches() {
        XCTAssertEqual(MenuBarIconStyle.monitorStrokeWidth, 1.20)
        XCTAssertEqual(MenuBarIconStyle.standStrokeWidth, MenuBarIconStyle.monitorStrokeWidth)
        XCTAssertLessThan(MenuBarIconStyle.monitorStrokeWidth, 1.45)
    }

    func testNormalLaunchKeepsStaticSafeFallback() {
        for state: ConnectionStatus in [.disconnected, .connecting, .connected, .disconnecting, .error] {
            XCTAssertFalse(MenuBarSymbolEffectExperiment.isActive(
                arguments: ["Astroberry VNC"], status: state, reduceMotion: false
            ))
        }
        XCTAssertFalse(MenuBarStatusIconPresentation.liveAnimationEnabled)
    }

    func testOptInOnlyAnimatesConnectingAndDisconnecting() {
        let arguments = ["Astroberry VNC", "--experimental-symbol-effect"]
        XCTAssertTrue(MenuBarSymbolEffectExperiment.isActive(
            arguments: arguments, status: .connecting, reduceMotion: false
        ))
        XCTAssertTrue(MenuBarSymbolEffectExperiment.isActive(
            arguments: arguments, status: .disconnecting, reduceMotion: false
        ))
        for state: ConnectionStatus in [.disconnected, .connected, .error] {
            XCTAssertFalse(MenuBarSymbolEffectExperiment.isActive(
                arguments: arguments, status: state, reduceMotion: false
            ))
        }
    }

    func testReduceMotionDisablesExperimentEvenWhenOptedIn() {
        for state: ConnectionStatus in [.connecting, .disconnecting] {
            XCTAssertFalse(MenuBarSymbolEffectExperiment.isActive(
                arguments: ["--experimental-symbol-effect"],
                status: state, reduceMotion: true
            ))
        }
    }

    func testConnectingAndDisconnectingUseDifferentSFSymbols() {
        XCTAssertEqual(MenuBarSymbolEffectExperiment.symbolName(for: .connecting), "circle.dotted")
        XCTAssertEqual(MenuBarSymbolEffectExperiment.symbolName(for: .disconnecting), "arrow.triangle.2.circlepath")
        for state: ConnectionStatus in [.disconnected, .connected, .error] {
            XCTAssertNil(MenuBarSymbolEffectExperiment.symbolName(for: state))
        }
    }
}
