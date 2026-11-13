// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build22SettingsTests: XCTestCase {
    func testPreferredSettingsContentSize() {
        XCTAssertEqual(SettingsWindowLayout.preferredContentSize, CGSize(width: 800, height: 650))
    }

    func testSettingsFitsVisibleScreenWithMargins() {
        XCTAssertEqual(SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 1440, height: 900)),
                       CGSize(width: 800, height: 650))
        XCTAssertEqual(SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 760, height: 530)),
                       CGSize(width: 712, height: 482))
        XCTAssertEqual(SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 760, height: 520)),
                       CGSize(width: 712, height: 472))
    }

    func testConnectionErrorIsNotTruncated() {
        let detailed = "Private key is missing or unreadable: The file \"id_ed25519_new-server.local\" could not be read. Try a valid key path."
        XCTAssertEqual(SettingsConnectionError.fullMessage(status: .error, lastError: detailed), detailed)
    }

    func testConnectionErrorHiddenAfterRecovery() {
        let oldError = "previous failed connection"
        XCTAssertNil(SettingsConnectionError.fullMessage(status: .connected, lastError: oldError))
        XCTAssertNil(SettingsConnectionError.fullMessage(status: .disconnected, lastError: oldError))
        XCTAssertNil(SettingsConnectionError.fullMessage(status: .error, lastError: nil))
    }
}
