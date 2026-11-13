// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class Build29_7WindowCommandTests: XCTestCase {
    func testCommandQClosesActiveSettingsOnly() {
        XCTAssertEqual(AppQuitShortcutPolicy.action(
            isCommandQ: true, settingsIsActive: true, explicitMenuQuit: false
        ), .closeSettings)
    }

    func testSecondCommandQAfterSettingsCloseIsIgnored() {
        XCTAssertEqual(AppQuitShortcutPolicy.action(
            isCommandQ: true, settingsIsActive: false, explicitMenuQuit: false
        ), .ignore)
    }

    func testMenuQuitStillTerminatesWithSettingsOpen() {
        XCTAssertEqual(AppQuitShortcutPolicy.action(
            isCommandQ: false, settingsIsActive: true, explicitMenuQuit: true
        ), .allowTermination)
    }

    func testNonKeyboardTerminationIsNotIntercepted() {
        XCTAssertEqual(AppQuitShortcutPolicy.action(
            isCommandQ: false, settingsIsActive: true, explicitMenuQuit: false
        ), .allowTermination)
    }

    func testCommandQWithModifiersIsNotInterpretedAsPlainCommandQ() {
        XCTAssertTrue(AppQuitShortcutPolicy.isCommandQ(
            characters: "q", hasCommand: true, hasShift: false,
            hasControl: false, hasOption: false
        ))
        XCTAssertFalse(AppQuitShortcutPolicy.isCommandQ(
            characters: "q", hasCommand: true, hasShift: true,
            hasControl: false, hasOption: false
        ))
        XCTAssertFalse(AppQuitShortcutPolicy.isCommandQ(
            characters: "w", hasCommand: true, hasShift: false,
            hasControl: false, hasOption: false
        ))
    }
}
