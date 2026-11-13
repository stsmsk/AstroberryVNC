// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

// A deterministic one-shot suspension point for the *fake* launch closure.
// No sleeps, process creation, SSH connections or real VNC instances.
private actor SuspendedViewerLaunch {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func launch() async -> Int {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return 42
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct LifecycleSnapshot: Sendable {
    let events: [String]
    let viewer: Int?
    let tunnelStarted: Bool
    let wasCancelled: Bool
    let viewerCleanupStillRunning: Bool
}

@MainActor
private final class FakeCancellationSession {
    var cancelRequested = false
    var viewer: Int?
    var tunnelStarted = true
    var events: [String] = []

    func checkCancellation() throws {
        events.append("check")
        if cancelRequested { throw CancellationError() }
    }

    func stopViewer(success: Bool = true) async -> QuitResourceState {
        events.append("stopViewer")
        if success { viewer = nil; return .stopped }
        return .running
    }

    func stopTunnel() async {
        events.append("stopTunnel")
        tunnelStarted = false
    }

    func rollback(viewerWillStop: Bool = true) async -> QuitResourceState {
        await ConnectionAttemptRollback.run(
            tunnelWasStarted: tunnelStarted,
            stopViewer: { await self.stopViewer(success: viewerWillStop) },
            stopTunnel: { await self.stopTunnel() }
        )
    }

    func snapshot(cancelled: Bool, viewerCleanupStillRunning: Bool = false) -> LifecycleSnapshot {
        LifecycleSnapshot(
            events: events, viewer: viewer, tunnelStarted: tunnelStarted,
            wasCancelled: cancelled, viewerCleanupStillRunning: viewerCleanupStillRunning
        )
    }
}

@MainActor
private enum CancellationScenarios {
    static func beforeLaunch() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        session.cancelRequested = true
        var caughtCancellation = false
        do {
            try await ConnectionViewerLaunchBoundary.run(
                checkCancellation: { try session.checkCancellation() },
                launchViewer: { session.events.append("launch"); return 42 },
                rememberViewer: { session.viewer = $0; session.events.append("remember") }
            )
        } catch is CancellationError {
            caughtCancellation = true
            _ = await session.rollback()
        } catch { }
        return session.snapshot(cancelled: caughtCancellation)
    }

    static func duringLaunch() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        let gate = SuspendedViewerLaunch()
        let operation = Task { @MainActor in
            do {
                try await ConnectionViewerLaunchBoundary.run(
                    checkCancellation: { try session.checkCancellation() },
                    launchViewer: {
                        session.events.append("launch")
                        return await gate.launch()
                    },
                    rememberViewer: { session.viewer = $0; session.events.append("remember") }
                )
                return false
            } catch is CancellationError {
                _ = await session.rollback()
                return true
            } catch { return false }
        }
        await gate.waitForEntry()  // exactly while fake launch is suspended
        session.cancelRequested = true
        await gate.release()
        let cancelled = await operation.value
        return session.snapshot(cancelled: cancelled)
    }

    static func immediatelyAfterLaunch() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        var caughtCancellation = false
        do {
            try await ConnectionViewerLaunchBoundary.run(
                checkCancellation: { try session.checkCancellation() },
                launchViewer: { session.events.append("launch"); return 42 },
                rememberViewer: {
                    session.viewer = $0
                    session.events.append("remember")
                    session.cancelRequested = true // deterministic cancellation at handoff
                }
            )
        } catch is CancellationError {
            caughtCancellation = true
            _ = await session.rollback()
        } catch { }
        return session.snapshot(cancelled: caughtCancellation)
    }

    static func failedCleanupPreservesHandle() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        var caughtCancellation = false
        var viewerStillRunning = false
        do {
            try await ConnectionViewerLaunchBoundary.run(
                checkCancellation: { try session.checkCancellation() },
                launchViewer: { session.events.append("launch"); return 42 },
                rememberViewer: {
                    session.viewer = $0; session.events.append("remember")
                    session.cancelRequested = true
                }
            )
        } catch is CancellationError {
            caughtCancellation = true
            let result = await session.rollback(viewerWillStop: false)
            viewerStillRunning = result == .running
        } catch { }
        return session.snapshot(cancelled: caughtCancellation, viewerCleanupStillRunning: viewerStillRunning)
    }

    static func normalLaunch() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        var cancelled = false
        do {
            try await ConnectionViewerLaunchBoundary.run(
                checkCancellation: { try session.checkCancellation() },
                launchViewer: { session.events.append("launch"); return 42 },
                rememberViewer: { session.viewer = $0; session.events.append("remember") }
            )
        } catch { cancelled = true }
        return session.snapshot(cancelled: cancelled)
    }

    static func rollbackBeforeTunnelStart() async -> LifecycleSnapshot {
        let session = FakeCancellationSession()
        session.tunnelStarted = false
        _ = await session.rollback()
        return session.snapshot(cancelled: false)
    }
}

final class Build31_8CancellationTests: XCTestCase {
    func testCancelBeforeLaunchNeverStartsViewerAndRollsBackTunnel() async {
        let state = await CancellationScenarios.beforeLaunch()
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.events, ["check", "stopViewer", "stopTunnel"])
        XCTAssertNil(state.viewer)
        XCTAssertFalse(state.tunnelStarted)
    }

    func testCancelWhileLaunchAwaitsRemembersHandleBeforeRollback() async {
        let state = await CancellationScenarios.duringLaunch()
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.events, ["check", "launch", "remember", "check", "stopViewer", "stopTunnel"])
        XCTAssertNil(state.viewer)
        XCTAssertFalse(state.tunnelStarted)
    }

    func testCancelImmediatelyAfterLaunchRollsBackInOrder() async {
        let state = await CancellationScenarios.immediatelyAfterLaunch()
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.events, ["check", "launch", "remember", "check", "stopViewer", "stopTunnel"])
        XCTAssertNil(state.viewer)
        XCTAssertFalse(state.tunnelStarted)
    }

    func testViewerCleanupFailureDoesNotForgetOwnedHandle() async {
        let state = await CancellationScenarios.failedCleanupPreservesHandle()
        XCTAssertTrue(state.wasCancelled)
        XCTAssertTrue(state.viewerCleanupStillRunning)
        XCTAssertEqual(state.viewer, 42)
        XCTAssertFalse(state.tunnelStarted)
        XCTAssertEqual(Array(state.events.suffix(2)), ["stopViewer", "stopTunnel"])
    }

    func testNormalLaunchDoesNotRunRollback() async {
        let state = await CancellationScenarios.normalLaunch()
        XCTAssertFalse(state.wasCancelled)
        XCTAssertEqual(state.events, ["check", "launch", "remember", "check"])
        XCTAssertEqual(state.viewer, 42)
        XCTAssertTrue(state.tunnelStarted)
    }

    func testRollbackNeverStopsTunnelThatWasNotStarted() async {
        let state = await CancellationScenarios.rollbackBeforeTunnelStart()
        XCTAssertEqual(state.events, ["stopViewer"])
        XCTAssertFalse(state.tunnelStarted)
    }
}
