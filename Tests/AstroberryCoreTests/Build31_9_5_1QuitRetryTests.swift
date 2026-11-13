// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AstroberryCore

// These tests protect the policy used by AppDelegate's deferred Quit dialog.
// Native AppKit/modal integration still requires testing on macOS.
final class Build31_9_5_1QuitRetryTests: XCTestCase {
    func testRetryKeepsOriginalTerminateLaterPending() {
        XCTAssertEqual(
            QuitCleanupRetryPolicy.nextStep(for: .retryCleanup),
            .retryWhilePending
        )
    }

    func testRepeatedFailuresContinueToRetryWithoutAnyTerminationReply() {
        // Every failing retry is handled identically; no new terminate()
        // request or reply(true/false) may be triggered by the retry action.
        for _ in 0..<10 {
            XCTAssertEqual(
                QuitCleanupRetryPolicy.nextStep(for: .retryCleanup),
                .retryWhilePending
            )
        }
    }

    func testKeepRunningCancelsPendingQuit() {
        XCTAssertEqual(
            QuitCleanupRetryPolicy.nextStep(for: .keepRunning),
            .replyToPendingTermination(false)
        )
    }

    func testQuitAnywayApprovesPendingQuit() {
        XCTAssertEqual(
            QuitCleanupRetryPolicy.nextStep(for: .quitAnyway),
            .replyToPendingTermination(true)
        )
    }
}
