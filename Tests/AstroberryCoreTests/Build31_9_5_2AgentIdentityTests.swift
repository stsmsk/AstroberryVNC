// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import AstroberryCore

// All integration work uses a dedicated, disposable ssh-agent. It never
// touches the developer's login agent or the real ~/.ssh directory.
final class Build31_9_5_2AgentIdentityTests: XCTestCase {
    private let sampleA = "ssh-ed25519 " + Data([1, 2, 3, 4]).base64EncodedString()
    private let sampleB = "ssh-ed25519 " + Data([5, 6, 7, 8]).base64EncodedString()

    private func record(_ publicKey: String, path: String = "/unused/key") -> SSHAgentUsedKey {
        // The record is created at Connect, not read from disk at Quit.
        SSHAgentQuitKeyPolicy.record(path: path, publicKey: publicKey, previous: [])[0]
    }

    func testAbsentAgentIdentityDoesNotRequirePublicKeyFile() {
        let used = record(sampleA)
        XCTAssertEqual(SSHAgentQuitKeyPolicy.agentIdentityState(
            recorded: used, exitCode: 1, output: "", error: "The agent has no identities."
        ), .notLoaded)
        XCTAssertEqual(SSHAgentQuitKeyPolicy.agentIdentityState(
            recorded: used, exitCode: 0, output: sampleB + " other\n", error: ""
        ), .notLoaded)
    }

    func testLoadedIdentityAndExactSingleKeyRemovalInput() {
        let used = record(sampleA)
        XCTAssertEqual(SSHAgentQuitKeyPolicy.agentIdentityState(
            recorded: used, exitCode: 0, output: sampleB + " other\n" + sampleA + " user\n",
            error: ""
        ), .loaded)
        XCTAssertEqual(SSHAgentQuitKeyPolicy.removalInput(for: used), sampleA + "\n")
        XCTAssertEqual(SSHAgentQuitKeyPolicy.removalInput(for: used).split(separator: "\n").count, 1)
    }

    func testBadOrUnavailableListingCannotBeMistakenForNotLoaded() {
        let used = record(sampleA)
        let states: [SSHAgentKeyState] = [
            SSHAgentQuitKeyPolicy.agentIdentityState(recorded: used, exitCode: 2,
                output: "", error: "Could not open a connection to your authentication agent."),
            SSHAgentQuitKeyPolicy.agentIdentityState(recorded: used, exitCode: 0,
                output: "", error: ""),
            SSHAgentQuitKeyPolicy.agentIdentityState(recorded: used, exitCode: 0,
                output: sampleB + " other\n[Output truncated after 1 MiB]", error: ""),
            SSHAgentQuitKeyPolicy.agentIdentityState(recorded: used, exitCode: 1,
                output: "", error: "Agent refused operation")
        ]
        for state in states {
            guard case .unavailable = state else {
                return XCTFail("Unexpectedly treated an unverified agent as safe: \(state)")
            }
        }
    }

    func testMissingPubAndAbsentIdentityCompleteSuccessfullyInIsolatedAgent() async throws {
        try await withIsolatedAgent { runner, env, directory in
            let used = directory.appendingPathComponent("never-added").path
            let other = directory.appendingPathComponent("other").path
            try makeKey(other, env: env, addToAgent: true)
            try makeKey(used, env: env, addToAgent: false)
            guard let pub = runner.readPublicKey(path: used) else { throw FixtureError.missingPublicKey }
            let entry = record(pub, path: used)
            try FileManager.default.removeItem(atPath: used + ".pub")
            let first = await runner.removeRecordedKeyFromAgentForQuit(entry)
            XCTAssertNil(first)
            let otherState = await runner.agentKeyState(path: other)
            XCTAssertEqual(otherState, .loaded)
            // Retry is also safe and idempotent.
            let second = await runner.removeRecordedKeyFromAgentForQuit(entry)
            XCTAssertNil(second)
        }
    }

    func testLoadedIdentityRemovedWithoutPubAndUnrelatedKeyPreserved() async throws {
        try await withIsolatedAgent { runner, env, directory in
            let used = directory.appendingPathComponent("used").path
            let other = directory.appendingPathComponent("other").path
            try makeKey(used, env: env, addToAgent: true)
            try makeKey(other, env: env, addToAgent: true)
            guard let pub = runner.readPublicKey(path: used) else { throw FixtureError.missingPublicKey }
            let entry = record(pub, path: used)
            try FileManager.default.removeItem(atPath: used + ".pub")
            let first = await runner.removeRecordedKeyFromAgentForQuit(entry)
            XCTAssertNil(first)
            // Used file is still present; no key material was deleted.
            XCTAssertTrue(FileManager.default.fileExists(atPath: used))
            let otherState = await runner.agentKeyState(path: other)
            XCTAssertEqual(otherState, .loaded)
            let listing = try execute("/usr/bin/ssh-add", ["-L"], env: env)
            XCTAssertEqual(listing.exit, 0)
            XCTAssertFalse(listing.stdout.contains(entry.identity.body))
            let second = await runner.removeRecordedKeyFromAgentForQuit(entry)
            XCTAssertNil(second)
        }
    }

    func testChangedPubNeverCausesRemovalOfReplacementKey() async throws {
        try await withIsolatedAgent { runner, env, directory in
            let used = directory.appendingPathComponent("used").path
            let other = directory.appendingPathComponent("other").path
            try makeKey(used, env: env, addToAgent: true)
            try makeKey(other, env: env, addToAgent: true)
            guard let pub = runner.readPublicKey(path: used),
                  let otherPub = runner.readPublicKey(path: other) else { throw FixtureError.missingPublicKey }
            let entry = record(pub, path: used)
            // Public-key file now claims the OTHER identity: only the saved
            // immutable identity from successful Connect may be removed.
            try otherPub.write(toFile: used + ".pub", atomically: true, encoding: .utf8)
            let first = await runner.removeRecordedKeyFromAgentForQuit(entry)
            XCTAssertNil(first)
            let otherState = await runner.agentKeyState(path: other)
            XCTAssertEqual(otherState, .loaded)
        }
    }

    func testUnreachableAgentIsAnErrorRatherThanAnAbsentKey() async throws {
        let runner = SystemCommandRunner(agentEnvironmentOverrides: [
            "SSH_AUTH_SOCK": "/tmp/abvnc-missing-agent-\(UUID().uuidString).sock"
        ])
        let used = record(sampleA)
        let failure = await runner.removeRecordedKeyFromAgentForQuit(used)
        XCTAssertNotNil(failure)
        XCTAssertTrue((failure ?? "").contains("Could not verify SSH agent"))
    }

    private enum FixtureError: Error { case missingPublicKey }

    private func withIsolatedAgent(
        _ body: (SystemCommandRunner, [String: String], URL) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/abvnc-agent-31-9-5-2-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("agent.sock").path
        let initial = try execute("/usr/bin/ssh-agent", ["-a", socket, "-s"])
        guard initial.exit == 0,
              let range = initial.stdout.range(of: #"SSH_AGENT_PID=([0-9]+)"#, options: .regularExpression),
              let digits = initial.stdout[range].range(of: #"[0-9]+"#, options: .regularExpression),
              let pid = Int32(initial.stdout[range][digits]) else {
            return XCTFail("Could not start isolated SSH agent: \(initial.stderr)")
        }
        defer { _ = try? execute("/bin/kill", ["-TERM", String(pid)]) }
        let env = ["SSH_AUTH_SOCK": socket]
        let runner = SystemCommandRunner(agentEnvironmentOverrides: env)
        try await body(runner, env, directory)
    }

    private func makeKey(_ path: String, env: [String: String], addToAgent: Bool) throws {
        let keygen = try execute("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
        XCTAssertEqual(keygen.exit, 0, keygen.stderr)
        if addToAgent {
            let added = try execute("/usr/bin/ssh-add", ["-q", path], env: env)
            XCTAssertEqual(added.exit, 0, added.stderr)
        }
    }

    private func execute(
        _ path: String, _ args: [String], env: [String: String] = [:]
    ) throws -> (exit: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if !env.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(env) { _, value in value }
        }
        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        return (
            task.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
