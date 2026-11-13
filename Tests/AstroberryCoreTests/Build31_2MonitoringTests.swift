// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31_2MonitoringTests: XCTestCase {
    func testOnlyOneHealthProbeCanRunForASession() {
        var gate = ConnectionHealthMonitoringState()
        let session = gate.beginSession()
        let probe = gate.beginProbe(for: session)
        XCTAssertNotNil(probe)
        XCTAssertNil(gate.beginProbe(for: session), "Timer and observer must never overlap")
        XCTAssertTrue(gate.accepts(session: session, probe: probe!))
        gate.endProbe(for: session, probe: probe!)
        XCTAssertNotNil(gate.beginProbe(for: session))
    }

    func testDisconnectRejectsDelayedHealthResult() {
        var gate = ConnectionHealthMonitoringState()
        let session = gate.beginSession()
        let probe = gate.beginProbe(for: session)!
        gate.invalidateSession() // User initiated Disconnect while SSH check awaited.
        XCTAssertFalse(gate.accepts(session: session, probe: probe))
        XCTAssertNil(gate.beginProbe(for: session))
    }

    func testReconnectionDoesNotAcceptPriorSessionResult() {
        var gate = ConnectionHealthMonitoringState()
        let oldSession = gate.beginSession()
        let oldProbe = gate.beginProbe(for: oldSession)!
        gate.invalidateSession()
        let newSession = gate.beginSession()
        let newProbe = gate.beginProbe(for: newSession)!
        XCTAssertNotEqual(oldSession, newSession)
        XCTAssertFalse(gate.accepts(session: oldSession, probe: oldProbe))
        gate.endProbe(for: oldSession, probe: oldProbe)
        XCTAssertTrue(gate.accepts(session: newSession, probe: newProbe), "Old task must not clear a new probe")
    }

    func testOldTimerCannotStartProbeOnNextSession() {
        var gate = ConnectionHealthMonitoringState()
        let oldSession = gate.beginSession()
        _ = gate.beginSession()
        XCTAssertNil(gate.beginProbe(for: oldSession))
    }

    func testCompletedProbeTokenIsNotReusable() {
        var gate = ConnectionHealthMonitoringState()
        let session = gate.beginSession()
        let oldProbe = gate.beginProbe(for: session)!
        gate.endProbe(for: session, probe: oldProbe)
        let newProbe = gate.beginProbe(for: session)!
        XCTAssertFalse(gate.accepts(session: session, probe: oldProbe))
        XCTAssertTrue(gate.accepts(session: session, probe: newProbe))
    }

    func testHealthySessionIsUnaffected() {
        XCTAssertEqual(ConnectionHealthEvaluation.evaluate(
            tunnelAlive: true, forwardingAlive: true, viewerAlive: true
        ), .healthy)
    }

    func testViewerClosureTakesPrecedenceOverTunnelFailure() {
        XCTAssertEqual(ConnectionHealthEvaluation.evaluate(
            tunnelAlive: false, forwardingAlive: false, viewerAlive: false
        ), .viewerClosed)
    }

    func testLostTunnelAndLostForwardingAreDistinct() {
        XCTAssertEqual(ConnectionHealthEvaluation.evaluate(
            tunnelAlive: false, forwardingAlive: true, viewerAlive: true
        ), .tunnelStopped)
        XCTAssertEqual(ConnectionHealthEvaluation.evaluate(
            tunnelAlive: true, forwardingAlive: false, viewerAlive: true
        ), .forwardingStopped)
    }
}
