// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build31ProcessExecutionTests: XCTestCase {
    func testLargeStdoutAndStderrDoNotDeadlock() {
        let result = SystemCommandRunner.executeCommand(
            "/bin/sh", arguments: ["-c", "yes X | head -c 200000; yes Y | head -c 200000 >&2"], timeout: 10)
        XCTAssertEqual(result.exitCode, 0, result.readableError)
        XCTAssertGreaterThan(result.output.utf8.count, 100_000)
        XCTAssertGreaterThan(result.error.utf8.count, 100_000)
    }

    func testOutputIsBoundedWhileChildKeepsRunning() {
        let result = SystemCommandRunner.executeCommand(
            "/bin/sh", arguments: ["-c", "yes Z | head -c 1200000"], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("[Output truncated after 1 MiB]"))
        XCTAssertLessThan(result.output.utf8.count, 1_050_000)
    }

    func testHungCommandTimesOut() {
        let before = Date()
        let result = SystemCommandRunner.executeCommand(
            "/bin/sleep", arguments: ["20"], timeout: 0.5)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.error.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(before), 6)
    }

    func testInputAndExitCodesArePreserved() {
        let result = SystemCommandRunner.executeCommand(
            "/bin/cat", arguments: [], input: "test-input\n", timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "test-input\n")
        let failed = SystemCommandRunner.executeCommand(
            "/bin/sh", arguments: ["-c", "echo specific-error >&2; exit 7"], timeout: 5)
        XCTAssertEqual(failed.exitCode, 7)
        XCTAssertTrue(failed.error.contains("specific-error"))
    }
}
