// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build26EmptyProfilesTests: XCTestCase {
    private let fallback = VNCServerProfile(
        id: UUID(uuidString: "26000000-0000-0000-0000-000000000001")!,
        displayName: "Astroberry", server: "astroberry.local", username: "astroberry"
    )
    private let second = VNCServerProfile(
        id: UUID(uuidString: "26000000-0000-0000-0000-000000000002")!,
        displayName: "Observatory", server: "observatory.local", username: "observer"
    )

    func testOnlyFirstLaunchCreatesMigrationProfile() {
        XCTAssertEqual(
            ServerProfileCollectionPolicy.restoredProfiles(savedProfiles: nil, firstLaunchProfile: fallback),
            [fallback]
        )
        XCTAssertEqual(
            ServerProfileCollectionPolicy.restoredProfiles(savedProfiles: [], firstLaunchProfile: fallback),
            []
        )
        XCTAssertEqual(
            ServerProfileCollectionPolicy.restoredProfiles(savedProfiles: [second], firstLaunchProfile: fallback),
            [second]
        )
    }

    func testEmptyCollectionCanBePersistedWithoutGeneratingDefault() throws {
        let persisted = try JSONEncoder().encode([VNCServerProfile]())
        let decoded = try JSONDecoder().decode([VNCServerProfile].self, from: persisted)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertTrue(ServerProfileCollectionPolicy.restoredProfiles(
            savedProfiles: decoded, firstLaunchProfile: fallback
        ).isEmpty)
    }

    func testLastDisconnectedServerCanBeRemovedButActiveCannot() {
        XCTAssertTrue(ServerProfileCollectionPolicy.canRemove(
            profiles: [fallback], profileID: fallback.id, activeProfileID: nil
        ))
        XCTAssertFalse(ServerProfileCollectionPolicy.canRemove(
            profiles: [fallback], profileID: fallback.id, activeProfileID: fallback.id
        ))
        XCTAssertTrue(ServerProfileCollectionPolicy.canRemove(
            profiles: [fallback, second], profileID: second.id, activeProfileID: fallback.id
        ))
        XCTAssertFalse(ServerProfileCollectionPolicy.canRemove(
            profiles: [], profileID: fallback.id, activeProfileID: nil
        ))
        XCTAssertFalse(ServerProfileCollectionPolicy.canRemove(
            profiles: [fallback], profileID: second.id, activeProfileID: nil
        ))
    }

    func testSelectionAfterRemovingLastServerIsEmpty() {
        XCTAssertNil(ServerProfileCollectionPolicy.replacementSelection(
            remainingProfiles: [], removedIndex: 0
        ))
        XCTAssertNil(ServerProfileCollectionPolicy.preferredSelection(
            profiles: [], savedID: fallback.id
        ))
        XCTAssertEqual(ServerProfileCollectionPolicy.replacementSelection(
            remainingProfiles: [second], removedIndex: 3
        ), second.id)
    }

    func testSavedSelectionIsPreservedOrFallsBackToFirst() {
        XCTAssertEqual(ServerProfileCollectionPolicy.preferredSelection(
            profiles: [fallback, second], savedID: second.id
        ), second.id)
        XCTAssertEqual(ServerProfileCollectionPolicy.preferredSelection(
            profiles: [fallback, second], savedID: UUID()
        ), fallback.id)
    }

    func testEmptyMenuHasNoConfiguredServersAndCannotConnect() {
        let presentation = NativeMenuStatusPresentation.make(
            status: .disconnected, serverName: "", hasProfiles: false
        )
        XCTAssertEqual(presentation.menuTitle, "⚪ No VNC Servers Configured")
        let action = NativeMenuActionPolicy.action(
            status: .disconnected, serverName: "", hasProfiles: false,
            canRetrySelectedConnection: false
        )
        XCTAssertEqual(action.title, "Connect")
        XCTAssertFalse(action.isEnabled)
    }

    func testSidebarKeyboardNavigationIncludesEmptyServersRow() {
        let empty = SettingsSidebarNavigation.noServersTag
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: SettingsSidebarNavigation.generalTag, offset: 1, serverIDs: []
        ), empty)
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: empty, offset: -1, serverIDs: []
        ), SettingsSidebarNavigation.generalTag)
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: empty, offset: 1, serverIDs: []
        ), empty)
    }
}
