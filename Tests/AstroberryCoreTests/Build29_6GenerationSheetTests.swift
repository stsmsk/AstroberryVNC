// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build29_6GenerationSheetTests: XCTestCase {
    let destination = "/tmp/id_ed25519_brand_new"

    func testGenerateEnabledWithBothPassphraseFieldsEmpty() {
        XCTAssertTrue(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "", confirmation: ""
        ))
    }

    func testGenerateEnabledWithMatchingPassphrase() {
        XCTAssertTrue(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "correct horse", confirmation: "correct horse"
        ))
    }

    func testGenerateDisabledWhenDestinationIsMissing() {
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: nil, passphrase: "", confirmation: ""
        ))
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: "", passphrase: "", confirmation: ""
        ))
    }

    func testGenerateDisabledWhenPassphrasesDiffer() {
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "abc", confirmation: "def"
        ))
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "", confirmation: "abc"
        ))
    }

    func testGenerateDisabledWhenPassphraseContainsNewline() {
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "hello\nworld", confirmation: "hello\nworld"
        ))
        XCTAssertFalse(SSHKeyGenerationSubmission.canSubmit(
            destinationPath: destination, passphrase: "hello\rworld", confirmation: "hello\rworld"
        ))
    }
}
