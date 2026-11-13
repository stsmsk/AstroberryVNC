// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_9_3SlimFrameTests: XCTestCase {
    func testMonitorAndStandHaveNewMatchedStrokeWidth() {
        XCTAssertEqual(MenuBarIconStyle.monitorStrokeWidth, 1.20)
        XCTAssertEqual(MenuBarIconStyle.standStrokeWidth, 1.20)
        XCTAssertLessThan(MenuBarIconStyle.monitorStrokeWidth, 1.45)
    }

    func testProductionStillUsesStaticStatusPresentation() {
        XCTAssertFalse(MenuBarStatusIconPresentation.liveAnimationEnabled)
        for state: ConnectionStatus in [.disconnected, .connecting, .connected, .disconnecting, .error] {
            XCTAssertFalse(MenuBarStatusIconPresentation.shouldAnimate(status: state, reduceMotion: false))
        }
    }

    func testAllFiveStatusMarkersArePreserved() {
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .disconnected), .none)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .connecting), .spinner)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .connected), .check)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .disconnecting), .progressArc)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .error), .exclamation)
    }
}
