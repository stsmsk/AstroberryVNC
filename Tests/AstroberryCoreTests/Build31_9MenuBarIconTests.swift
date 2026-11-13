// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_9MenuBarIconTests: XCTestCase {
    func testEachStatusHasDistinctCentralGlyph() {
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .disconnected), .none)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .connecting), .spinner)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .connected), .check)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .disconnecting), .progressArc)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .error), .exclamation)
    }

    func testNoStateAnimatesWhileStaticFallbackIsActive() {
        XCTAssertFalse(MenuBarStatusIconPresentation.liveAnimationEnabled)
        for status: ConnectionStatus in [.disconnected, .connecting, .connected, .disconnecting, .error] {
            XCTAssertFalse(MenuBarStatusIconPresentation.shouldAnimate(status: status, reduceMotion: false))
        }
    }

    func testReduceMotionStopsBothAnimations() {
        XCTAssertFalse(MenuBarStatusIconPresentation.shouldAnimate(status: .connecting, reduceMotion: true))
        XCTAssertFalse(MenuBarStatusIconPresentation.shouldAnimate(status: .disconnecting, reduceMotion: true))
        XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
            at: 123.75, status: .connecting, reduceMotion: true
        ), 0)
        XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
            at: 123.75, status: .disconnecting, reduceMotion: true
        ), 0)
    }

    func testConnectingFrameNeverAdvancesWithClock() {
        for time in [0.0, 0.125, 0.25, 0.875, 1.0, 1.125, 1000.0] {
            XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
                at: time, status: .connecting, reduceMotion: false
            ), 0)
        }
    }

    func testStaticStatesNeverAdvanceEvenAsClockChanges() {
        for status: ConnectionStatus in [.disconnected, .connected, .error] {
            XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
                at: 103.25, status: status, reduceMotion: false
            ), 0)
        }
    }

    func testNonFiniteOrNegativeClockNeverProducesInvalidFrame() {
        for clock in [Double.nan, Double.infinity, -Double.infinity, -1.0] {
            XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
                at: clock, status: .connecting, reduceMotion: false
            ), 0)
        }
    }

    func testDisconnectingUsesSameFrameClockButDifferentGlyph() {
        XCTAssertEqual(MenuBarStatusIconPresentation.frameIndex(
            at: 0.5, status: .disconnecting, reduceMotion: false
        ), 0)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .disconnecting), .progressArc)
        XCTAssertEqual(MenuBarStatusIconPresentation.glyph(for: .connecting), .spinner)
    }
}
