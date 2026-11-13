// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build28PassphraseTests: XCTestCase {
    private func tempKey() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroberryVNC-ssh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return (directory, directory.appendingPathComponent("id_ed25519").path)
    }

    func testInspectKeyPreservesPublicKeyComment() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let comment = "astroberry@astroberry.local via Astroberry VNC"
        let generated = await runner.generateSSHKey(path: item.path, passphrase: "", comment: comment)
        guard generated.exitCode == 0 else { XCTFail(generated.readableError); return }
        let saved = runner.readPublicKey(path: item.path)
        XCTAssertTrue(saved?.hasSuffix(comment) == true)
        switch await runner.inspectKey(path: item.path) {
        case .success(let inspection): XCTAssertEqual(inspection.publicKey, saved)
        case .failure(let error): XCTFail(error.localizedDescription)
        }
    }

    func testKeyWithoutPassphraseConnectReadiness() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(path: item.path, passphrase: "", comment: "build28-test")
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let readiness = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(readiness, .ready)
        switch await runner.inspectKey(path: item.path) {
        case .success(let inspection):
            XCTAssertTrue(inspection.fingerprint.contains("SHA256:"))
        case .failure(let error):
            XCTFail(error.localizedDescription)
        }
    }

    func testKeyPassphraseChangeAndRemovalPreservesPublicIdentity() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(
            path: item.path, passphrase: "demo-secret-1", comment: "build28-test"
        )
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let initialReadiness = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(initialReadiness, .needsPassphrase)
        let publicBefore = runner.readPublicKey(path: item.path)

        let changed = await runner.changeKeyPassphrase(
            path: item.path, current: "demo-secret-1", replacement: "demo-secret-2"
        )
        guard changed.exitCode == 0 else {
            XCTFail("Passphrase change failed: \(changed.readableError) (exit \(changed.exitCode))")
            return
        }
        let changedReadiness = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(changedReadiness, .needsPassphrase)
        XCTAssertEqual(runner.readPublicKey(path: item.path), publicBefore)

        let removed = await runner.changeKeyPassphrase(
            path: item.path, current: "demo-secret-2", replacement: ""
        )
        guard removed.exitCode == 0 else {
            XCTFail("Passphrase removal failed: \(removed.readableError) (exit \(removed.exitCode))")
            return
        }
        let removedReadiness = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(removedReadiness, .ready)
        XCTAssertEqual(runner.readPublicKey(path: item.path), publicBefore)
    }

    func testAddingPassphraseToUnencryptedKeyPreservesPublicIdentity() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(path: item.path, passphrase: "", comment: "build28-test")
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let originalPublicKey = runner.readPublicKey(path: item.path)
        let initialState = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(initialState, .ready)
        let changed = await runner.changeKeyPassphrase(path: item.path, current: "", replacement: "first-secret")
        guard changed.exitCode == 0 else {
            XCTFail("Adding passphrase failed: \(changed.readableError) (exit \(changed.exitCode))")
            return
        }
        let updatedState = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(updatedState, .needsPassphrase)
        XCTAssertEqual(runner.readPublicKey(path: item.path), originalPublicKey)
    }

    func testUnprotectedKeyRejectsNonemptyCurrentPassphrase() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(path: item.path, passphrase: "", comment: "build281-test")
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let unprotectedState = await runner.privateKeyProtectionState(path: item.path)
        XCTAssertEqual(unprotectedState, .unprotected)
        let originalPublic = runner.readPublicKey(path: item.path)
        let result = await runner.changeKeyPassphrase(path: item.path, current: "should-not-be-accepted", replacement: "new-secret")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(runner.readPublicKey(path: item.path), originalPublic)
        let stillUnprotected = await runner.privateKeyProtectionState(path: item.path)
        XCTAssertEqual(stillUnprotected, .unprotected)
    }

    // A private agent is essential: never add test keys to the user's login
    // ssh-agent. This also verifies the exact Expect/ssh-add flow used by Connect.
    func testEncryptedKeyUnlocksIntoIsolatedSSHAgent() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let isolated = try IsolatedSSHAgent()
        defer { isolated.stop() }
        let runner = SystemCommandRunner(agentEnvironmentOverrides: ["SSH_AUTH_SOCK": isolated.socketPath])
        let generated = await runner.generateSSHKey(path: item.path, passphrase: "agent-test-passphrase", comment: "build281-agent-test")
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let protectedOnDisk = await runner.privateKeyProtectionState(path: item.path)
        XCTAssertEqual(protectedOnDisk, .protected)
        let initialUnlockState = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(initialUnlockState, .needsPassphrase)
        let beforeAgentState = await runner.agentKeyState(path: item.path)
        XCTAssertEqual(beforeAgentState, .notLoaded)

        let incorrect = await runner.unlockKeyInAgent(path: item.path, passphrase: "wrong-passphrase")
        XCTAssertNotEqual(incorrect.exitCode, 0, "An incorrect passphrase must fail")
        XCTAssertNotEqual(incorrect.exitCode, 24, "Wrong passphrase must not hang until timeout: \(incorrect.readableError)")
        let wrongUnlockState = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(wrongUnlockState, .needsPassphrase)

        let unlocked = await runner.unlockKeyInAgent(path: item.path, passphrase: "agent-test-passphrase")
        XCTAssertEqual(unlocked.exitCode, 0, "ssh-add must accept the passphrase: \(unlocked.readableError)")
        let unlockedState = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(unlockedState, .ready)
        let afterAgentState = await runner.agentKeyState(path: item.path)
        XCTAssertEqual(afterAgentState, .loaded)
        // The key remains encrypted on disk even if agent has unlocked it.
        let protectedAfterAgentLoad = await runner.privateKeyProtectionState(path: item.path)
        XCTAssertEqual(protectedAfterAgentLoad, .protected)
    }

    private final class IsolatedSSHAgent {
        let socketPath: String
        private let directory: URL
        private let pid: Int32

        init() throws {
            // Keep UNIX-domain socket path short enough for macOS sun_path.
            directory = URL(fileURLWithPath: "/tmp/abvnc-agent-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            socketPath = directory.appendingPathComponent("agent.sock").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            process.arguments = ["-a", socketPath, "-s"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0,
                  let range = output.range(of: #"SSH_AGENT_PID=([0-9]+)"#, options: .regularExpression),
                  let idRange = output[range].range(of: #"[0-9]+"#, options: .regularExpression),
                  let pid = Int32(output[range][idRange]) else {
                throw NSError(domain: "Build28Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not launch isolated SSH agent."])
            }
            self.pid = pid
        }

        func stop() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/kill")
            process.arguments = ["-TERM", String(pid)]
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testWrongOldPassphraseDoesNotUnlockKey() async throws {
        let item = try tempKey()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(
            path: item.path, passphrase: "correct-test-secret", comment: "build28-test"
        )
        XCTAssertEqual(generated.exitCode, 0, generated.readableError)
        let attempt = await runner.changeKeyPassphrase(
            path: item.path, current: "wrong-test-secret", replacement: "something-else"
        )
        XCTAssertNotEqual(attempt.exitCode, 0)
        XCTAssertNotEqual(attempt.exitCode, 24, "Wrong-passphrase rejection must not be a timeout: \(attempt.readableError)")
        let readiness = await runner.keyUnlockState(path: item.path)
        XCTAssertEqual(readiness, .needsPassphrase)
    }
}
