// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import AstroberryCore

final class Build31_9_5SSHAgentQuitTests: XCTestCase {
    private let ed25519A = "ssh-ed25519 " + Data([1, 2, 3, 4]).base64EncodedString()
    private let ed25519B = "ssh-ed25519 " + Data([5, 6, 7, 8]).base64EncodedString()

    func testDefaultOffOrNonMenuQuitCannotRemoveKeys() {
        XCTAssertFalse(SSHAgentQuitKeyPolicy.isEnabledForQuit(
            preferenceEnabled: false, explicitMenuQuit: true
        ))
        XCTAssertFalse(SSHAgentQuitKeyPolicy.isEnabledForQuit(
            preferenceEnabled: true, explicitMenuQuit: false
        ))
        XCTAssertTrue(SSHAgentQuitKeyPolicy.isEnabledForQuit(
            preferenceEnabled: true, explicitMenuQuit: true
        ))
        XCTAssertEqual(SSHAgentQuitKeyPolicy.preferenceKey, "RemoveUsedSSHKeysFromAgentOnQuit")
    }

    func testUsesDistinctIdentitiesAndDeduplicatesSharedKeys() {
        let one = SSHAgentQuitKeyPolicy.record(path: "~/.ssh/a", publicKey: ed25519A,
                                                previous: [])
        XCTAssertEqual(one.count, 1)
        let shared = SSHAgentQuitKeyPolicy.record(path: "~/.ssh/also-a", publicKey: ed25519A,
                                                   previous: one)
        XCTAssertEqual(shared, one)
        let two = SSHAgentQuitKeyPolicy.record(path: "~/.ssh/b", publicKey: ed25519B,
                                                previous: shared)
        XCTAssertEqual(two.count, 2)
        XCTAssertNotEqual(two[0].identity, two[1].identity)
    }

    func testNoRecordForUnparseablePublicKey() {
        XCTAssertTrue(SSHAgentQuitKeyPolicy.record(path: "/tmp/bad", publicKey: "not a key",
                                                    previous: []).isEmpty)
    }

    func testChangedOrMissingPublicKeyCannotRemoveDifferentIdentity() {
        guard let used = SSHAgentQuitKeyPolicy.record(
            path: "/tmp/a", publicKey: ed25519A, previous: []
        ).first else { return XCTFail("Expected recorded key") }
        XCTAssertTrue(SSHAgentQuitKeyPolicy.matchesRecordedIdentity(
            used, currentPublicKey: ed25519A + " changed-comment"
        ))
        XCTAssertFalse(SSHAgentQuitKeyPolicy.matchesRecordedIdentity(
            used, currentPublicKey: ed25519B
        ))
        XCTAssertFalse(SSHAgentQuitKeyPolicy.matchesRecordedIdentity(
            used, currentPublicKey: nil
        ))
        // Never feed a multi-line .pub file to ssh-add -d: it might contain
        // more than one identity and remove unrelated keys.
        XCTAssertFalse(SSHAgentQuitKeyPolicy.matchesRecordedIdentity(
            used, currentPublicKey: ed25519A + "\n" + ed25519B
        ))
    }

    // macOS integration test: isolate all SSH commands from the user's
    // login ssh-agent, and never change any key under the user's ~/.ssh.
    func testQuitRemovalDoesNotTouchUnrelatedKeyInIsolatedAgent() async throws {
        let directory = URL(fileURLWithPath: "/tmp/abvnc-quit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("agent.sock").path
        let initial = try execute("/usr/bin/ssh-agent", ["-a", socket, "-s"])
        guard initial.exit == 0,
              let range = initial.stdout.range(of: #"SSH_AGENT_PID=([0-9]+)"#, options: .regularExpression),
              let digits = initial.stdout[range].range(of: #"[0-9]+"#, options: .regularExpression),
              let agentPID = Int32(initial.stdout[range][digits]) else {
            return XCTFail("Could not start isolated SSH agent: \(initial.stderr)")
        }
        defer { _ = try? execute("/bin/kill", ["-TERM", String(agentPID)]) }
        let env = ["SSH_AUTH_SOCK": socket]
        let usedPath = directory.appendingPathComponent("used").path
        let otherPath = directory.appendingPathComponent("unrelated").path
        for path in [usedPath, otherPath] {
            let created = try execute("/usr/bin/ssh-keygen", [
                "-q", "-t", "ed25519", "-N", "", "-f", path
            ])
            XCTAssertEqual(created.exit, 0, created.stderr)
            let added = try execute("/usr/bin/ssh-add", ["-q", path], environment: env)
            XCTAssertEqual(added.exit, 0, added.stderr)
        }
        let runner = SystemCommandRunner(agentEnvironmentOverrides: env)
        let beforeUsed = await runner.agentKeyState(path: usedPath)
        let beforeOther = await runner.agentKeyState(path: otherPath)
        XCTAssertEqual(beforeUsed, .loaded)
        XCTAssertEqual(beforeOther, .loaded)
        guard let key = runner.readPublicKey(path: usedPath),
              let record = SSHAgentQuitKeyPolicy.record(path: usedPath, publicKey: key, previous: []).first else {
            return XCTFail("Could not record generated key")
        }
        let error = await runner.removeRecordedKeyFromAgentForQuit(record)
        XCTAssertNil(error)
        let afterUsed = await runner.agentKeyState(path: usedPath)
        let afterOther = await runner.agentKeyState(path: otherPath)
        XCTAssertEqual(afterUsed, .notLoaded)
        XCTAssertEqual(afterOther, .loaded)
        // Calling Quit cleanup again must not fail or touch other identities.
        let secondError = await runner.removeRecordedKeyFromAgentForQuit(record)
        XCTAssertNil(secondError)
        let otherStillLoaded = await runner.agentKeyState(path: otherPath)
        XCTAssertEqual(otherStillLoaded, .loaded)
    }

    private func execute(
        _ path: String, _ args: [String], environment: [String: String] = [:]
    ) throws -> (exit: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if !environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        return (task.terminationStatus,
                String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
