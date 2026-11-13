// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AstroberryCore

final class ServerMenuInteractionStateTests: XCTestCase {
    private let first = ServerMenuItemID.server(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    private let second = ServerMenuItemID.server(UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)

    func testPointerPresentationHasNoImplicitKeyboardHighlight() {
        var state = ServerMenuInteractionState()
        state.presentPointer()

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.inputMode, .pointer)
        XCTAssertNil(state.keyboardItemID)
        XCTAssertNil(state.activeItemID)
        XCTAssertEqual(state.highlight(for: first), .none)
    }

    func testPointerAndKeyboardHighlightsAreExclusive() {
        var state = ServerMenuInteractionState()
        state.presentPointer()
        state.pointerMoved(over: second)
        XCTAssertEqual(state.activeItemID, second)
        XCTAssertEqual(state.highlight(for: second), .pointer)
        XCTAssertEqual(state.highlight(for: first), .none)

        state.activateKeyboard(initialItemID: first)
        XCTAssertEqual(state.activeItemID, first)
        XCTAssertNil(state.hoveredItemID)
        XCTAssertEqual(state.highlight(for: first), .keyboard)
        XCTAssertEqual(state.highlight(for: second), .none)

        state.pointerMoved(over: second)
        XCTAssertNil(state.keyboardItemID)
        XCTAssertEqual(state.highlight(for: first), .none)
        XCTAssertEqual(state.highlight(for: second), .pointer)
    }

    func testKeyboardMovementUsesStableItemIDs() {
        var state = ServerMenuInteractionState()
        state.presentKeyboard(initialItemID: second)
        let items = [first, second, .manageServers]

        state.moveKeyboard(by: 1, orderedItemIDs: items)
        XCTAssertEqual(state.keyboardItemID, .manageServers)
        state.moveKeyboard(by: 1, orderedItemIDs: items)
        XCTAssertEqual(state.keyboardItemID, first)
        state.moveKeyboard(by: -1, orderedItemIDs: items)
        XCTAssertEqual(state.keyboardItemID, .manageServers)
    }

    func testSyntheticTriggerHoverDoesNotStealKeyboardMode() {
        var state = ServerMenuInteractionState()
        state.presentKeyboard(initialItemID: first)
        state.dismiss(retaining: .keyboard)

        state.setTriggerHovered(true)

        XCTAssertEqual(state.inputMode, .keyboard)
        XCTAssertTrue(state.isTriggerHovered)
    }

    func testDismissIsIdempotentAndClearsTransientState() {
        var state = ServerMenuInteractionState()
        state.setTriggerHovered(true)
        state.presentPointer()
        state.setListHovered(true)
        state.pointerMoved(over: first)
        state.dismiss(retaining: .pointer)
        let dismissed = state

        state.dismiss(retaining: .keyboard)
        XCTAssertEqual(state, dismissed)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.isTriggerHovered)
        XCTAssertFalse(state.isListHovered)
        XCTAssertNil(state.hoveredItemID)
        XCTAssertNil(state.keyboardItemID)
    }
}

final class MainMenuInteractionStateTests: XCTestCase {
    private let enabledItems: [MainMenuItemID] = [.server, .connection, .settings, .quit]

    func testKeyboardMovementUsesOrderedEnabledItems() {
        var state = MainMenuInteractionState()
        state.moveKeyboard(by: 1, orderedItemIDs: enabledItems)
        XCTAssertEqual(state.keyboardItemID, .server)
        state.moveKeyboard(by: 1, orderedItemIDs: enabledItems)
        XCTAssertEqual(state.keyboardItemID, .connection)
        state.moveKeyboard(by: -1, orderedItemIDs: enabledItems)
        XCTAssertEqual(state.keyboardItemID, .server)
        state.moveKeyboard(by: -1, orderedItemIDs: enabledItems)
        XCTAssertEqual(state.keyboardItemID, .quit)
    }

    func testDisabledItemIsSkippedByCallerSuppliedOrder() {
        var state = MainMenuInteractionState()
        let withoutConnection: [MainMenuItemID] = [.server, .settings, .quit]
        state.activateKeyboard(initialItemID: .server)
        state.moveKeyboard(by: 1, orderedItemIDs: withoutConnection)
        XCTAssertEqual(state.keyboardItemID, .settings)
    }

    func testPointerAndKeyboardHighlightsAreExclusiveInMainMenu() {
        var state = MainMenuInteractionState()
        state.pointerMoved(over: .settings)
        XCTAssertTrue(state.isHighlighted(.settings))
        XCTAssertEqual(state.accessibilityValue(for: .settings), "Hovered")

        state.activateKeyboard(initialItemID: .quit)
        XCTAssertNil(state.hoveredItemID)
        XCTAssertFalse(state.isHighlighted(.settings))
        XCTAssertTrue(state.isHighlighted(.quit))
        XCTAssertEqual(state.accessibilityValue(for: .quit), "Keyboard Focus")

        state.pointerMoved(over: .server)
        XCTAssertNil(state.keyboardItemID)
        XCTAssertTrue(state.isHighlighted(.server))
    }

    func testNoImplicitActionTargetAndChildSuspension() {
        var state = MainMenuInteractionState()
        XCTAssertNil(state.keyboardItemID)
        state.activateKeyboard(initialItemID: .server)
        state.suspendForChildMenu()
        XCTAssertNil(state.keyboardItemID)
        XCTAssertNil(state.hoveredItemID)
    }

    func testDisabledFocusedItemMovesToFirstEnabledItem() {
        var state = MainMenuInteractionState()
        state.activateKeyboard(initialItemID: .server)
        state.reconcile(orderedItemIDs: [.connection, .settings, .quit])
        XCTAssertEqual(state.keyboardItemID, .connection)
    }
}

final class ServerMenuPlacementCalculatorTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panelSize = CGSize(width: 250, height: 168)

    func testOpensWithFivePointRightOverlapWhenSpaceIsAvailable() {
        let anchor = CGRect(x: 100, y: 500, width: 300, height: 36)
        let placement = ServerMenuPlacementCalculator.placement(
            anchorRect: anchor, panelSize: panelSize, visibleFrame: visibleFrame
        )
        XCTAssertTrue(placement.opensToRight)
        XCTAssertEqual(placement.origin.x, anchor.maxX - 5)
        XCTAssertEqual(placement.origin.y + panelSize.height - 6 - 15, anchor.midY)
    }

    func testOpensWithFivePointLeftOverlapWhenRightSideDoesNotFit() {
        let anchor = CGRect(x: 1100, y: 500, width: 300, height: 36)
        let placement = ServerMenuPlacementCalculator.placement(
            anchorRect: anchor, panelSize: panelSize, visibleFrame: visibleFrame
        )
        XCTAssertFalse(placement.opensToRight)
        XCTAssertEqual(placement.origin.x + panelSize.width, anchor.minX + 5)
    }

    func testCustomOverlapIsAppliedOnlyOnceInPointCoordinates() {
        let anchor = CGRect(x: 100, y: 500, width: 300, height: 36)
        let placement = ServerMenuPlacementCalculator.placement(
            anchorRect: anchor, panelSize: panelSize, visibleFrame: visibleFrame, overlap: 3
        )
        XCTAssertEqual(placement.origin.x, anchor.maxX - 3)
    }

    func testClampsToVisibleEdgesWhenNeitherSideFits() {
        let narrowScreen = CGRect(x: 100, y: 200, width: 220, height: 160)
        let placement = ServerMenuPlacementCalculator.placement(
            anchorRect: CGRect(x: 120, y: 330, width: 180, height: 36),
            panelSize: panelSize,
            visibleFrame: narrowScreen
        )
        XCTAssertEqual(placement.origin.x, narrowScreen.minX)
        XCTAssertEqual(placement.origin.y, narrowScreen.minY)
    }

    func testUsesAbsoluteCoordinatesForSecondaryDisplay() {
        let secondary = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let anchor = CGRect(x: -1200, y: 500, width: 300, height: 36)
        let placement = ServerMenuPlacementCalculator.placement(
            anchorRect: anchor, panelSize: panelSize, visibleFrame: secondary
        )
        XCTAssertEqual(placement.origin.x, anchor.maxX - 5)
        XCTAssertGreaterThanOrEqual(placement.origin.y, secondary.minY)
    }
}

final class SettingsSidebarNavigationTests: XCTestCase {
    private let first = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!

    func testSettingsPresentationStartsAtGeneral() {
        XCTAssertEqual(SettingsSidebarNavigation.generalTag, "general")
    }

    func testDownFromGeneralSelectsFirstServerWithoutEnteringTabs() {
        let next = SettingsSidebarNavigation.selection(
            from: "general", offset: 1, serverIDs: [first, second]
        )
        XCTAssertEqual(next, SettingsSidebarNavigation.serverTag(first))
    }

    func testUpAndDownMoveBetweenServers() {
        let down = SettingsSidebarNavigation.selection(
            from: SettingsSidebarNavigation.serverTag(first),
            offset: 1, serverIDs: [first, second]
        )
        XCTAssertEqual(down, SettingsSidebarNavigation.serverTag(second))
        let up = SettingsSidebarNavigation.selection(
            from: down, offset: -1, serverIDs: [first, second]
        )
        XCTAssertEqual(up, SettingsSidebarNavigation.serverTag(first))
    }

    func testUpFromFirstServerReturnsToGeneralAndClampsAtEdges() {
        let up = SettingsSidebarNavigation.selection(
            from: SettingsSidebarNavigation.serverTag(first),
            offset: -1, serverIDs: [first, second]
        )
        XCTAssertEqual(up, "general")
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: "general", offset: -1, serverIDs: [first, second]
        ), "general")
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: SettingsSidebarNavigation.serverTag(second), offset: 1,
            serverIDs: [first, second]
        ), SettingsSidebarNavigation.serverTag(second))
    }

    func testEmptyServerListAndMissingSelectionAreSafe() {
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: "general", offset: 1, serverIDs: []
        ), SettingsSidebarNavigation.noServersTag)
        XCTAssertEqual(SettingsSidebarNavigation.selection(
            from: "server:deleted", offset: 1, serverIDs: [first]
        ), SettingsSidebarNavigation.serverTag(first))
    }
}

final class SettingsPaneNavigationTests: XCTestCase {
    func testServerRowRightMovesToConnectionWithoutChangingSelection() {
        XCTAssertEqual(SettingsPaneNavigation.rightFromSidebar(hasSelectedServer: true), .connectionTab)
        XCTAssertEqual(SettingsPaneNavigation.rightFromSidebar(hasSelectedServer: false), .unchanged)
    }

    func testConnectionLeftMovesBackToSelectedServer() {
        XCTAssertEqual(SettingsPaneNavigation.leftFromTab(currentIndex: 0, tabCount: 3), .sidebarServer)
    }

    func testOtherTabsLeftNavigateWithinTabStrip() {
        XCTAssertEqual(SettingsPaneNavigation.leftFromTab(currentIndex: 1, tabCount: 3), .tab(0))
        XCTAssertEqual(SettingsPaneNavigation.leftFromTab(currentIndex: 2, tabCount: 3), .tab(1))
        XCTAssertEqual(SettingsPaneNavigation.leftFromTab(currentIndex: 3, tabCount: 3), .unchanged)
    }
}

final class SettingsWindowLayoutTests: XCTestCase {
    func testUsesPreferredSizeOnNormalDisplay() {
        XCTAssertEqual(
            SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 1440, height: 900)),
            CGSize(width: 800, height: 650)
        )
    }

    func testFitsWithinSmallVisibleArea() {
        XCTAssertEqual(
            SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 800, height: 600)),
            CGSize(width: 752, height: 552)
        )
    }

    func testFitsIntermediateVisibleAreaWithoutClipping() {
        XCTAssertEqual(
            SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 1000, height: 680)),
            CGSize(width: 800, height: 632)
        )
    }

    func testNeverExceedsEvenAnExtremelySmallVisibleArea() {
        XCTAssertEqual(
            SettingsWindowLayout.contentSize(visibleScreenSize: CGSize(width: 500, height: 400)),
            CGSize(width: 452, height: 352)
        )
    }

    func testResizableMinimumOnNormalDisplay() {
        XCTAssertEqual(
            SettingsWindowLayout.minimumResizableContentSize(visibleScreenSize: CGSize(width: 1440, height: 900)),
            CGSize(width: 620, height: 440)
        )
    }

    func testResizableMinimumNeverExceedsTinyDisplay() {
        XCTAssertEqual(
            SettingsWindowLayout.minimumResizableContentSize(visibleScreenSize: CGSize(width: 500, height: 400)),
            CGSize(width: 452, height: 352)
        )
    }
}

final class ProfileFeedbackOperationTrackerTests: XCTestCase {
    private let firstProfileID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let secondProfileID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    func testNewerOperationInvalidatesOlderResultForSameProfileAndDomain() {
        var tracker = ProfileFeedbackOperationTracker()
        let older = tracker.begin(profileID: firstProfileID, domain: .hostKey)
        let newer = tracker.begin(profileID: firstProfileID, domain: .hostKey)
        XCTAssertFalse(tracker.isCurrent(older, profileID: firstProfileID, domain: .hostKey))
        XCTAssertTrue(tracker.isCurrent(newer, profileID: firstProfileID, domain: .hostKey))
    }

    func testProfilesAndDomainsHaveIndependentOperationTokens() {
        var tracker = ProfileFeedbackOperationTracker()
        let firstHost = tracker.begin(profileID: firstProfileID, domain: .hostKey)
        let firstKey = tracker.begin(profileID: firstProfileID, domain: .sshKey)
        let secondHost = tracker.begin(profileID: secondProfileID, domain: .hostKey)
        XCTAssertTrue(tracker.isCurrent(firstHost, profileID: firstProfileID, domain: .hostKey))
        XCTAssertTrue(tracker.isCurrent(firstKey, profileID: firstProfileID, domain: .sshKey))
        XCTAssertTrue(tracker.isCurrent(secondHost, profileID: secondProfileID, domain: .hostKey))
    }

    func testInvalidationAndProfileRemovalDiscardOutstandingResults() {
        var tracker = ProfileFeedbackOperationTracker()
        let host = tracker.begin(profileID: firstProfileID, domain: .hostKey)
        let key = tracker.begin(profileID: firstProfileID, domain: .sshKey)
        tracker.invalidate(profileID: firstProfileID, domain: .hostKey)
        XCTAssertFalse(tracker.isCurrent(host, profileID: firstProfileID, domain: .hostKey))
        XCTAssertTrue(tracker.isCurrent(key, profileID: firstProfileID, domain: .sshKey))
        tracker.remove(profileID: firstProfileID)
        XCTAssertFalse(tracker.isCurrent(key, profileID: firstProfileID, domain: .sshKey))
    }

    func testFeedbackValuesRemainSeparatedByProfileUUID() {
        var feedbackByProfile: [UUID: ProfileSettingsFeedback] = [:]
        feedbackByProfile[firstProfileID] = ProfileSettingsFeedback(hostKeyError: "first server error")
        feedbackByProfile[secondProfileID] = ProfileSettingsFeedback(keyMessage: "second server success")
        XCTAssertEqual(feedbackByProfile[firstProfileID]?.hostKeyError, "first server error")
        XCTAssertNil(feedbackByProfile[secondProfileID]?.hostKeyError)
        XCTAssertEqual(feedbackByProfile[secondProfileID]?.keyMessage, "second server success")
    }
}

final class SettingsTabNavigationTests: XCTestCase {
    func testLeftAndRightFollowThreeTabsWithoutWrapping() {
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 0, offset: 1, count: 3), 1)
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 1, offset: 1, count: 3), 2)
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 2, offset: -1, count: 3), 1)
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 1, offset: -1, count: 3), 0)
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 0, offset: -1, count: 3), 0)
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 2, offset: 1, count: 3), 2)
    }

    func testEmptyTabListIsSafe() {
        XCTAssertEqual(SettingsTabNavigation.nextIndex(current: 0, offset: 1, count: 0), 0)
    }
}

final class NativeMenuActionPolicyTests: XCTestCase {
    func testServerSelectionAllowedOnlyWhenDisconnectedOrRecoverableErrorAndIdle() {
        XCTAssertTrue(NativeMenuActionPolicy.canSelectServer(status: .disconnected, isBusy: false))
        XCTAssertTrue(NativeMenuActionPolicy.canSelectServer(status: .error, isBusy: false))
        XCTAssertFalse(NativeMenuActionPolicy.canSelectServer(status: .connecting, isBusy: true))
        XCTAssertFalse(NativeMenuActionPolicy.canSelectServer(status: .connected, isBusy: false))
        XCTAssertFalse(NativeMenuActionPolicy.canSelectServer(status: .disconnecting, isBusy: true))
        XCTAssertFalse(NativeMenuActionPolicy.canSelectServer(status: .disconnected, isBusy: true))
    }

    func testNativeMenuDisablesConnectionWhenNoProfilesExist() {
        let action = NativeMenuActionPolicy.action(
            status: .disconnected,
            serverName: "No Servers Configured",
            hasProfiles: false,
            canRetrySelectedConnection: false
        )
        XCTAssertFalse(action.isEnabled)
        XCTAssertEqual(action.operation, .connect)
    }

    func testCancelRemainsAvailableWhileConnecting() {
        let action = NativeMenuActionPolicy.action(
            status: .connecting, serverName: "astroberry",
            hasProfiles: true, canRetrySelectedConnection: false
        )
        XCTAssertEqual(action.operation, .cancel)
        XCTAssertTrue(action.isEnabled)
    }

    func testRetryIsScopedToSameProfileAndUnchangedSettings() {
        let retry = NativeMenuActionPolicy.action(
            status: .error, serverName: "astroberry",
            hasProfiles: true, canRetrySelectedConnection: true
        )
        XCTAssertEqual(retry.operation, .retry)
        let connect = NativeMenuActionPolicy.action(
            status: .error, serverName: "other",
            hasProfiles: true, canRetrySelectedConnection: false
        )
        XCTAssertEqual(connect.operation, .connect)
        XCTAssertEqual(connect.title, "Connect to other")
    }

    func testDisconnectAndDisconnectingHaveDifferentAvailability() {
        let active = NativeMenuActionPolicy.action(
            status: .connected, serverName: "astroberry",
            hasProfiles: true, canRetrySelectedConnection: false
        )
        XCTAssertEqual(active.operation, .disconnect)
        XCTAssertTrue(active.isEnabled)
        let closing = NativeMenuActionPolicy.action(
            status: .disconnecting, serverName: "astroberry",
            hasProfiles: true, canRetrySelectedConnection: false
        )
        XCTAssertEqual(closing.operation, .disconnecting)
        XCTAssertFalse(closing.isEnabled)
    }
}

// Build 19 status-visibility regression tests. These pure policies do not
// exercise native menu rendering; that remains a macOS Release test.
final class NativeMenuStatusPresentationTests: XCTestCase {
    func testConnectedHasReadableActionTitleAndDistinctBadge() {
        let status = NativeMenuStatusPresentation.make(
            status: .connected, serverName: "astroberry", hasProfiles: true
        )
        XCTAssertEqual(status.menuTitle, "🟢 Connected to astroberry")
        XCTAssertTrue(status.accessibilityLabel.contains("Open Settings"))
    }

    func testDisconnectedShowsTargetAndRemainsActionable() {
        let status = NativeMenuStatusPresentation.make(
            status: .disconnected, serverName: "astroberry", hasProfiles: true
        )
        XCTAssertEqual(status.menuTitle, "⚪ Disconnected · astroberry")
    }

    func testAllFiveStatesHaveColouredNativeStatusIndicators() {
        let expected: [(ConnectionStatus, String)] = [
            (.disconnected, "⚪"),
            (.connecting, "🟠"),
            (.connected, "🟢"),
            (.disconnecting, "🟠"),
            (.error, "🔴")
        ]
        for (state, icon) in expected {
            let presentation = NativeMenuStatusPresentation.make(
                status: state, serverName: "astroberry", hasProfiles: true
            )
            XCTAssertTrue(presentation.menuTitle.hasPrefix(icon + " "))
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
            XCTAssertFalse(presentation.helpText.isEmpty)
        }
    }

    func testNoProfileDoesNotClaimConnectedServer() {
        let status = NativeMenuStatusPresentation.make(
            status: .disconnected, serverName: "ignored", hasProfiles: false
        )
        XCTAssertEqual(status.menuTitle, "⚪ No VNC Servers Configured")
    }

    func testBusyStatesAreExplicit() {
        let connecting = NativeMenuStatusPresentation.make(
            status: .connecting, serverName: "astroberry", hasProfiles: true
        )
        let disconnecting = NativeMenuStatusPresentation.make(
            status: .disconnecting, serverName: "astroberry", hasProfiles: true
        )
        XCTAssertTrue(connecting.menuTitle.contains("Connecting"))
        XCTAssertTrue(disconnecting.menuTitle.contains("Disconnecting"))
        XCTAssertNotEqual(connecting.menuTitle, disconnecting.menuTitle)
    }

    func testErrorOpensDetailsAndHasWarningBadge() {
        let status = NativeMenuStatusPresentation.make(
            status: .error, serverName: "astroberry", hasProfiles: true
        )
        XCTAssertTrue(status.menuTitle.contains("Connection Error"))
        XCTAssertTrue(status.menuTitle.contains("Details"))
    }
}
