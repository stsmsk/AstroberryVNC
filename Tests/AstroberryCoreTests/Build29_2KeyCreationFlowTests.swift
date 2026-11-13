// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build29_2KeyCreationFlowTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AstroberryVNC-B29-2-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testExistingPrivateKeyDisablesContinueAndSuggestsUnusedName() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("id_ed25519_test").path
        try "never overwrite".write(toFile: original, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_test", existing: []), .destinationOccupied)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.availableName(directory: folder.path, desiredName: "id_ed25519_test", existing: []), "id_ed25519_test-2")
        XCTAssertEqual(try String(contentsOfFile: original, encoding: .utf8), "never overwrite")
    }

    func testPublicKeyOnlyCollisionAlsoBlocksCreation() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("id_ed25519_test").path
        try "public".write(toFile: path + ".pub", atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_test", existing: []), .destinationOccupied)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.availableName(directory: folder.path, desiredName: "id_ed25519_test", existing: []), "id_ed25519_test-2")
        XCTAssertEqual(try String(contentsOfFile: path + ".pub", encoding: .utf8), "public")
    }

    func testNameReferencedByAnotherProfileBlocksCreationEvenIfNoFile() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reserved = folder.appendingPathComponent("id_ed25519_test").path
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_test", existing: [reserved]), .destinationOccupied)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.availableName(directory: folder.path, desiredName: "id_ed25519_test", existing: [reserved]), "id_ed25519_test-2")
    }

    func testSuffixSkipsBothPrivateAndPublicCollisions() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("custom_key").path
        try "private".write(toFile: original, atomically: true, encoding: .utf8)
        try "public".write(toFile: original + "-2.pub", atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.availableName(directory: folder.path, desiredName: "custom_key", existing: []), "custom_key-3")
    }

    func testInvalidFilenameAndMissingFolderCannotContinue() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "../wrong", existing: []), .invalidName)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id.pub", existing: []), .invalidName)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path + "/missing", fileName: "fresh_key", existing: []), .folderUnavailable)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "fresh_key", existing: []), .available)
    }

    func testMissingFolderNeverProducesInvalidFilenameWarning() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The filename shown in the user's screenshot is valid. A missing
        // folder must say so, rather than displaying character restrictions.
        let name = "id_ed25519_new-server.local-5"
        XCTAssertTrue(SSHKeyPathPolicy.validFileName(name))
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: "", fileName: name, existing: []), .folderUnavailable)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: name, existing: []), .available)
    }

    func testEmptyFilenameHasItsOwnMessageAndCannotContinue() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "", existing: []), .emptyName)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.Validation.emptyName.message,
                       "Enter a filename for the new SSH key pair.")
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_test", existing: []), .available)
    }

    func testFilenameValidationTracksEditsAndDoesNotLeaveStaleError() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "../bad", existing: []), .invalidName)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_new-server.local-5", existing: []), .available)
        let occupied = folder.appendingPathComponent("id_ed25519_new-server.local-5")
        try "key".write(to: occupied, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: occupied.lastPathComponent, existing: []), .destinationOccupied)
        XCTAssertEqual(SSHNewKeyDestinationPolicy.validate(directory: folder.path, fileName: "id_ed25519_new-server.local-6", existing: []), .available)
    }
}
