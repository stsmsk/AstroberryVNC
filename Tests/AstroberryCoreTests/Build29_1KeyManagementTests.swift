// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build29_1KeyManagementTests: XCTestCase {
    private func profile(_ name: String, host: String, path: String = "") -> VNCServerProfile {
        VNCServerProfile(displayName: name, server: host, username: "astroberry", privateKeyPath: path)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AstroberryVNC-B29-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLegacyKeyPathIsPinnedAndDoesNotChangeWithSSHHost() {
        let legacy = profile("Pi", host: "astroberry.local")
        let directory = "/tmp/ssh-test-keys"
        let pinned = SSHKeyPathPolicy.pinLegacyPaths([legacy], directory: directory)
        XCTAssertEqual(pinned[0].privateKeyPath, "/tmp/ssh-test-keys/id_ed25519_astroberry.local")
        var edited = pinned[0]
        edited.server = "different.local"
        XCTAssertEqual(edited.privateKeyPath, pinned[0].privateKeyPath)
        XCTAssertEqual(SSHKeyPathPolicy.pinLegacyPaths([edited], directory: "/tmp/other")[0].privateKeyPath, pinned[0].privateKeyPath)
    }

    func testSuggestedNewKeyNameCanBeIndependentOfOldHost() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SSHKeyPathPolicy.distinctPath(host: "new-server.local", directory: directory.path, existing: [])
        let next = SSHKeyPathPolicy.distinctPath(host: "new-server.local", directory: directory.path, existing: [first])
        XCTAssertEqual(URL(fileURLWithPath: first).lastPathComponent, "id_ed25519_new-server.local")
        XCTAssertEqual(URL(fileURLWithPath: next).lastPathComponent, "id_ed25519_new-server.local-2")
        try "reserved".write(toFile: next + ".pub", atomically: true, encoding: .utf8)
        let third = SSHKeyPathPolicy.distinctPath(host: "new-server.local", directory: directory.path, existing: [first])
        XCTAssertEqual(URL(fileURLWithPath: third).lastPathComponent, "id_ed25519_new-server.local-3")
    }

    func testRenameMovesPairWithoutChangingContentsAndUpdatesSharedReferences() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("id_ed25519_old").path
        let privateData = Data([0, 1, 2, 3, 255])
        let publicText = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE shared comment\n"
        try privateData.write(to: URL(fileURLWithPath: source))
        try publicText.write(toFile: source + ".pub", atomically: true, encoding: .utf8)
        let first = profile("A", host: "a.local", path: source)
        let second = profile("B", host: "b.local", path: source)
        let third = profile("C", host: "c.local", path: directory.appendingPathComponent("other").path)
        let sharedIDs = Set([first.id, second.id])
        let rename = SSHKeyPairRenamer.rename(path: source, toFileName: "renamed_key")
        guard case .success(let target) = rename else {
            XCTFail("Key pair should be renamed: \(rename)"); return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), privateData)
        XCTAssertEqual(try String(contentsOfFile: target + ".pub", encoding: .utf8), publicText)
        let updated = SSHKeyPathPolicy.replacingReferences(in: [first, second, third], profileIDs: sharedIDs, to: target)
        XCTAssertEqual(updated[0].privateKeyPath, target)
        XCTAssertEqual(updated[1].privateKeyPath, target)
        XCTAssertEqual(updated[2].privateKeyPath, third.privateKeyPath)
    }

    func testRenameRealEd25519PairPreservesFingerprint() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("id_ed25519_before").path
        let runner = SystemCommandRunner()
        let generated = await runner.generateSSHKey(
            path: source, passphrase: "", comment: "build29-1-rename-test"
        )
        guard generated.exitCode == 0 else { XCTFail(generated.readableError); return }
        let originalPublic = runner.readPublicKey(path: source)
        let originalInspection = await runner.inspectKey(path: source)
        guard case .success(let before) = originalInspection else {
            XCTFail("Could not inspect disposable test key"); return
        }
        let renamed = SSHKeyPairRenamer.rename(path: source, toFileName: "id_ed25519_after")
        guard case .success(let newPath) = renamed else {
            XCTFail("Could not rename disposable test key: \(renamed)"); return
        }
        XCTAssertEqual(runner.readPublicKey(path: newPath), originalPublic)
        switch await runner.inspectKey(path: newPath) {
        case .success(let after): XCTAssertEqual(after.fingerprint, before.fingerprint)
        case .failure(let error): XCTFail(error.localizedDescription)
        }
    }

    func testRenameRejectsDestinationCollisionWithoutTouchingSource() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("key").path
        let destination = directory.appendingPathComponent("occupied").path
        try "secret".write(toFile: source, atomically: true, encoding: .utf8)
        try "public".write(toFile: source + ".pub", atomically: true, encoding: .utf8)
        try "other".write(toFile: destination + ".pub", atomically: true, encoding: .utf8)
        if case .success = SSHKeyPairRenamer.rename(path: source, toFileName: "occupied") {
            XCTFail("Must never overwrite an existing public key")
        }
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOfFile: source + ".pub", encoding: .utf8), "public")
        XCTAssertEqual(try String(contentsOfFile: destination + ".pub", encoding: .utf8), "other")
    }

    func testRenameRejectsSymlinkAndUnsafeNames() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("key").path
        try "secret".write(toFile: source, atomically: true, encoding: .utf8)
        try "pub".write(toFile: source + ".pub", atomically: true, encoding: .utf8)
        for invalid in ["", "../other", ".", "..", ".hidden", "id.pub", "with spaces", "a/b"] {
            XCTAssertFalse(SSHKeyPathPolicy.validFileName(invalid), "Accepted invalid filename: \(invalid)")
        }
        let link = directory.appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)
        try "pub".write(toFile: link + ".pub", atomically: true, encoding: .utf8)
        if case .success = SSHKeyPairRenamer.rename(path: link, toFileName: "changed") {
            XCTFail("Must never rename a symbolic-link key")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }

    func testConnectedKeyMayNotBeRenamedButOtherProfileMayChooseDifferentKey() {
        let active = profile("Active", host: "astroberry.local", path: "/tmp/shared")
        let other = profile("Other", host: "elsewhere.local", path: "/tmp/shared")
        XCTAssertTrue(SessionProfileEditingPolicy.sameKeyFile(active.privateKeyPath, other.privateKeyPath))
        var selected = other
        selected.privateKeyPath = "/tmp/new-independent-key"
        XCTAssertTrue(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: other, proposed: selected, sessionProfileID: active.id
        ))
        var activeEdited = active
        activeEdited.privateKeyPath = "/tmp/new-independent-key"
        XCTAssertFalse(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: active, proposed: activeEdited, sessionProfileID: active.id
        ))
    }
}
