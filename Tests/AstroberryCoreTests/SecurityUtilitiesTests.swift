// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class SecurityUtilitiesTests: XCTestCase {
    func testLocalForwardCheckInspectsSSHListenerWithoutConnecting() {
        XCTAssertEqual(
            SystemCommandRunner.localForwardListenerArguments(port: 5901),
            ["-nP", "-a", "-c", "ssh", "-iTCP@127.0.0.1:5901", "-sTCP:LISTEN", "-Fp"]
        )
    }

    func testViewerLaunchArgumentsKeepPasswordlessSecurityAndNoReconnect() {
        XCTAssertEqual(ViewerLaunchPolicy.arguments(localPort: 5901), [
            "-SecurityTypes=None", "-ReconnectOnError=0", "127.0.0.1::5901"
        ])
    }

    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZha2VLZXlCb2R5MDEyMzQ1Njc4OTAxMjM0NTY= first"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE90aGVyS2V5Qm9keTAxMjM0NTY3ODkwMTIzNDU= other"

    func testPublicKeyCommentIsPreservedOnFirstRegistration() {
        let comment = "astroberry@astroberry.local via Astroberry VNC"
        let annotated = "\(keyA.split(separator: " ")[0]) \(keyA.split(separator: " ")[1]) \(comment)"
        let normalized = AuthorizedPublicKeyLine.normalized(annotated)
        XCTAssertEqual(normalized, annotated)
        let appended = AuthorizedKeysEditor.appendingIfMissing(annotated, to: "")
        XCTAssertTrue(appended.changed)
        XCTAssertEqual(appended.contents, annotated + "\n")
    }

    func testExistingKeyDoesNotLoseCommentsOrOptions() {
        let restricted = "from=\"192.168.0.0/16\",no-pty \(keyA)\n"
        let annotated = "\(keyA.split(separator: " ")[0]) \(keyA.split(separator: " ")[1]) new-name"
        let appended = AuthorizedKeysEditor.appendingIfMissing(annotated, to: restricted)
        XCTAssertFalse(appended.changed)
        XCTAssertEqual(appended.contents, restricted)
    }

    func testMultilinePublicKeyIsRejectedBeforeRegistration() {
        let attack = keyA + "\ncommand=\"malicious\" " + keyB
        XCTAssertNil(AuthorizedPublicKeyLine.normalized(attack))
        let appended = AuthorizedKeysEditor.appendingIfMissing(attack, to: "")
        XCTAssertFalse(appended.changed)
        XCTAssertEqual(appended.contents, "")
    }

    func testSSHConnectionErrorsGiveActionableCategories() {
        XCTAssertTrue(SSHConnectionErrorFormatter.description(for: "Permission denied (publickey)")
            .contains("public-key authentication"))
        XCTAssertTrue(SSHConnectionErrorFormatter.description(for: "Connection refused")
            .contains("SSH server refused"))
        XCTAssertTrue(SSHConnectionErrorFormatter.description(for: "Host key verification failed")
            .contains("fingerprint"))
        XCTAssertTrue(SSHConnectionErrorFormatter.description(for: "Operation timed out")
            .contains("timeout"))
        XCTAssertTrue(SSHConnectionErrorFormatter.description(for: "Could not resolve hostname")
            .contains("resolved"))
    }

    func testEmptyFileAppendsKey() {
        let result = AuthorizedKeysEditor.appendingIfMissing(keyA, to: "")
        XCTAssertTrue(result.changed)
        XCTAssertTrue(AuthorizedKeysEditor.contains(keyA, in: result.contents))
    }

    func testSameKeyWithDifferentCommentIsNotDuplicated() {
        let existing = keyA.replacingOccurrences(of: "first", with: "old-comment") + "\n"
        let result = AuthorizedKeysEditor.appendingIfMissing(keyA, to: existing)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.contents, existing)
    }

    func testOptionPrefixedKeyIsRecognized() {
        let existing = "from=\"192.168.0.0/16\",no-pty \(keyA)\n"
        XCTAssertTrue(AuthorizedKeysEditor.contains(keyA, in: existing))
    }

    func testDifferentKeyIsAppendedWithoutChangingExistingLine() {
        let existing = "no-port-forwarding \(keyA)\n"
        let result = AuthorizedKeysEditor.appendingIfMissing(keyB, to: existing)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.contents.hasPrefix(existing))
        XCTAssertTrue(AuthorizedKeysEditor.contains(keyB, in: result.contents))
    }

    func testInvalidLineIsPreserved() {
        let existing = "# keep this comment\nnot-a-key\n"
        let result = AuthorizedKeysEditor.appendingIfMissing(keyA, to: existing)
        XCTAssertTrue(result.contents.hasPrefix(existing))
    }

    func testServerValidationRejectsNonLoopbackVNC() {
        var profile = VNCServerProfile(server: "astroberry.local", username: "astroberry")
        profile.vncHost = "0.0.0.0"
        XCTAssertTrue(ServerSettingsValidator.validate(profile).contains("VNC host must be loopback-only."))
    }

    func testSharedViewerAndTimeoutOverrideLegacyProfileValues() {
        var profile = VNCServerProfile(server: "astroberry.local", username: "astroberry")
        profile.viewerPath = ""
        profile.connectTimeout = 0
        let errors = ServerSettingsValidator.validate(
            profile, viewerPath: "/Applications/TigerVNC.app", connectTimeout: 10
        )
        XCTAssertFalse(errors.contains("TigerVNC Viewer path is required."))
        XCTAssertFalse(errors.contains("Timeout must be between 1 and 120 seconds."))
    }

    func testSharedViewerAndTimeoutAreValidated() {
        let profile = VNCServerProfile(server: "astroberry.local", username: "astroberry")
        let errors = ServerSettingsValidator.validate(profile, viewerPath: "", connectTimeout: 0)
        XCTAssertTrue(errors.contains("TigerVNC Viewer path is required."))
        XCTAssertTrue(errors.contains("Timeout must be between 1 and 120 seconds."))
    }

    func testSelectedPrivateKeyPathSurvivesPersistence() throws {
        let selectedPath = "/Users/example/.ssh/id_ed25519_existing"
        let profile = VNCServerProfile(
            server: "astroberry.local",
            username: "astroberry",
            privateKeyPath: selectedPath
        )

        let restored = try JSONDecoder().decode(
            VNCServerProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(restored.privateKeyPath, selectedPath)
    }

    func testConnectionMenuActionMatchesEveryConnectionState() {
        let server = "Observatory"
        XCTAssertEqual(ConnectionStatus.disconnected.menuAction(serverName: server).title, "Connect to Observatory")
        XCTAssertEqual(ConnectionStatus.disconnected.menuAction(serverName: server).operation, .connect)
        XCTAssertEqual(ConnectionStatus.connecting.menuAction(serverName: server).operation, .cancel)
        XCTAssertEqual(ConnectionStatus.connected.menuAction(serverName: server).title, "Disconnect from Observatory")
        XCTAssertEqual(ConnectionStatus.connected.menuAction(serverName: server).operation, .disconnect)
        XCTAssertEqual(ConnectionStatus.error.menuAction(serverName: server).title, "Retry Observatory")
        XCTAssertEqual(ConnectionStatus.error.menuAction(serverName: server).operation, .retry)
        XCTAssertFalse(ConnectionStatus.disconnecting.menuAction(serverName: server).isEnabled)
    }

    func testServerMenuDismissalRequiresPointerOutsideTriggerAndList() {
        XCTAssertFalse(ServerMenuDismissalPolicy.shouldDismiss(isTriggerHovered: true, isListHovered: false))
        XCTAssertFalse(ServerMenuDismissalPolicy.shouldDismiss(isTriggerHovered: false, isListHovered: true))
        XCTAssertFalse(ServerMenuDismissalPolicy.shouldDismiss(isTriggerHovered: true, isListHovered: true))
        XCTAssertTrue(ServerMenuDismissalPolicy.shouldDismiss(isTriggerHovered: false, isListHovered: false))
        XCTAssertGreaterThanOrEqual(ServerMenuDismissalPolicy.presentationDelayMilliseconds, 0)
        XCTAssertLessThanOrEqual(ServerMenuDismissalPolicy.presentationDelayMilliseconds, 150)
        XCTAssertGreaterThan(ServerMenuDismissalPolicy.delayMilliseconds, 0)
    }

    func testServerMenuSnapshotPreservesAllProfilesAndOneSelection() {
        let first = VNCServerProfile(displayName: "First", server: "first.local", username: "astroberry")
        let second = VNCServerProfile(displayName: "Second", server: "second.local", username: "astroberry")
        let third = VNCServerProfile(displayName: "Third", server: "third.local", username: "astroberry")
        let name: (VNCServerProfile) -> String = { $0.displayName }

        XCTAssertTrue(ServerMenuSnapshot.entries(
            profiles: [], selectedProfileID: UUID(), profileName: name
        ).isEmpty)

        let single = ServerMenuSnapshot.entries(
            profiles: [first], selectedProfileID: first.id, profileName: name
        )
        XCTAssertEqual(single.map(\.title), ["First"])
        XCTAssertEqual(single.filter(\.isSelected).count, 1)

        let three = ServerMenuSnapshot.entries(
            profiles: [first, second, third], selectedProfileID: second.id, profileName: name
        )
        XCTAssertEqual(three.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(three.filter(\.isSelected).map(\.id), [second.id])
    }

    func testRetrySignatureRequiresSameServerAndUnchangedSettings() {
        let first = VNCServerProfile(displayName: "First", server: "first.local", username: "astroberry")
        var changed = first
        changed.vncPort = 5999
        let other = VNCServerProfile(displayName: "Other", server: "other.local", username: "astroberry")
        let failed = ConnectionAttemptSignature(
            profile: first, keyDirectory: "~/.ssh",
            viewerPath: "/Applications/TigerVNC.app", connectTimeout: 10
        )

        XCTAssertEqual(failed, ConnectionAttemptSignature(
            profile: first, keyDirectory: "~/.ssh",
            viewerPath: "/Applications/TigerVNC.app", connectTimeout: 10
        ))
        XCTAssertNotEqual(failed, ConnectionAttemptSignature(
            profile: other, keyDirectory: "~/.ssh",
            viewerPath: "/Applications/TigerVNC.app", connectTimeout: 10
        ))
        XCTAssertNotEqual(failed, ConnectionAttemptSignature(
            profile: changed, keyDirectory: "~/.ssh",
            viewerPath: "/Applications/TigerVNC.app", connectTimeout: 10
        ))
        XCTAssertNotEqual(failed, ConnectionAttemptSignature(
            profile: first, keyDirectory: "~/.ssh",
            viewerPath: "/Applications/TigerVNC.app", connectTimeout: 20
        ))
    }

    func testED25519GenerationInspectionAndNoOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AstroberryCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("id_ed25519_test").path
        let runner = SystemCommandRunner()
        let first = await runner.generateSSHKey(path: path, passphrase: "", comment: "test")
        XCTAssertEqual(first.exitCode, 0, first.readableError)
        switch await runner.inspectKey(path: path) {
        case .success(let inspection):
            XCTAssertTrue(inspection.publicKey.hasPrefix("ssh-ed25519 "))
            XCTAssertTrue(inspection.fingerprint.contains("SHA256:"))
        case .failure(let error): XCTFail(error.localizedDescription)
        }
        let second = await runner.generateSSHKey(path: path, passphrase: "", comment: "test")
        XCTAssertNotEqual(second.exitCode, 0)
    }
}
