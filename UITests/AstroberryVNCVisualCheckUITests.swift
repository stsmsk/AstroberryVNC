// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

final class AstroberryVNCVisualCheckUITests: XCTestCase {
    private let app = XCUIApplication()
    private let astroberryID = "serverOption-10000000-0000-0000-0000-000000000001"
    private let observatoryID = "serverOption-10000000-0000-0000-0000-000000000002"
    private let backupID = "serverOption-10000000-0000-0000-0000-000000000003"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.windows["Astroberry VNC Visual Check"].waitForExistence(timeout: 5))
    }

    func testServerHoverSelectionRetryAndRepeatedOpening() throws {
        let serverRow = app.buttons["serverMenuRow"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 3))
        serverRow.hover()

        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons[observatoryID].exists)
        XCTAssertTrue(app.buttons[backupID].exists)
        XCTAssertEqual(app.images.matching(identifier: "selectedServerCheckmark").count, 1)

        app.buttons[observatoryID].click()
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Connect to Observatory"))
        XCTAssertTrue(waitForValue(serverRow, containing: "Idle"))

        app.buttons["scenario-failure-retry"].click()
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Retry Observatory"))
        serverRow.hover()
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        app.buttons[astroberryID].click()
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Connect to Astroberry"))

        for _ in 0..<20 {
            serverRow.hover()
            XCTAssertTrue(app.buttons[observatoryID].waitForExistence(timeout: 1))
            app.buttons["connectionActionRow"].hover()
            XCTAssertFalse(app.buttons[observatoryID].waitForExistence(timeout: 1))
        }

        for identifier in ["serverMenuRow", "connectionActionRow", "settingsRow", "quitRow"] {
            let row = app.buttons[identifier]
            row.hover()
            XCTAssertTrue((row.value as? String)?.contains("Hovered") == true, "Missing hover state for \(identifier)")
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Astroberry-VNC-Visual-Check"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testConnectingRemainsResponsiveWithoutSSH() throws {
        app.buttons["scenario-connecting"].click()
        XCTAssertTrue(app.buttons["connectionActionRow"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Cancel Connection"))
        XCTAssertTrue(app.buttons["settingsRow"].exists)
        XCTAssertTrue(app.buttons["quitRow"].exists)

        app.buttons["scenario-disconnected"].click()
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Connect to Astroberry"))
    }

    func testMainMenuKeyboardTraversalAndParentChildFocus() throws {
        let serverRow = app.buttons["serverMenuRow"]
        let connectionRow = app.buttons["connectionActionRow"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 3))

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(serverRow, containing: "Keyboard Focus"))
        // Preview is visible while navigation still belongs to the parent.
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(connectionRow, containing: "Keyboard Focus"))
        XCTAssertFalse(app.buttons[astroberryID].waitForExistence(timeout: 1))
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(serverRow, containing: "Keyboard Focus"))
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForValue(app.buttons[astroberryID], containing: "Keyboard Highlighted"))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertFalse(app.buttons[astroberryID].waitForExistence(timeout: 1))
        XCTAssertTrue(waitForValue(serverRow, containing: "Keyboard Focus"))
    }

    func testMouseOpenThenKeyboardSelectionAndEscape() throws {
        let serverRow = app.buttons["serverMenuRow"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 3))

        serverRow.click()
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForValue(serverRow, containing: "Idle"))
        XCTAssertTrue(waitForValue(app.buttons[astroberryID], containing: "Idle"))

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(app.buttons[astroberryID], containing: "Keyboard Highlighted"))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(app.buttons[observatoryID], containing: "Keyboard Highlighted"))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["connectionActionRow"].label.contains("Connect to Observatory"))

        serverRow.click()
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons[astroberryID].waitForExistence(timeout: 1))

        for _ in 0..<10 {
            serverRow.click()
            XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 1))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.buttons[astroberryID].waitForExistence(timeout: 1))
        }
    }

    func testPointerAndKeyboardHighlightsDoNotOverlap() throws {
        let serverRow = app.buttons["serverMenuRow"]
        serverRow.click()
        XCTAssertTrue(app.buttons[astroberryID].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForValue(app.buttons[astroberryID], containing: "Idle"))

        app.buttons[backupID].hover()
        XCTAssertTrue(waitForValue(app.buttons[backupID], containing: "Hovered"))
        XCTAssertTrue(waitForValue(app.buttons[astroberryID], containing: "Idle"))

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitForValue(app.buttons["manageServersRow"], containing: "Keyboard Highlighted"))
        XCTAssertTrue(waitForValue(app.buttons[backupID], containing: "Idle"))

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertFalse(app.buttons[astroberryID].waitForExistence(timeout: 1))
        XCTAssertTrue(waitForValue(serverRow, containing: "Keyboard Focus"))
    }

    func testQuitTerminatesApplication() throws {
        let quitRow = app.buttons["quitRow"]
        XCTAssertTrue(quitRow.waitForExistence(timeout: 3))

        quitRow.click()

        let stopped = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: stopped, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    private func waitForValue(_ element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 2) == .completed
    }
}
