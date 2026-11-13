// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ServerMenuPlacement: Equatable {
    let origin: CGPoint
    let opensToRight: Bool
}

enum ServerMenuPlacementCalculator {
    static func placement(
        anchorRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        contentTopInset: CGFloat = 6,
        rowHeight: CGFloat = 30,
        overlap: CGFloat = 5
    ) -> ServerMenuPlacement {
        // The visual overlap is a design value, not an Apple-specified menu metric.
        let effectiveOverlap = min(max(overlap, 0), panelSize.width)
        let rightOrigin = anchorRect.maxX - effectiveOverlap
        let leftOrigin = anchorRect.minX - panelSize.width + effectiveOverlap
        let fitsRight = rightOrigin + panelSize.width <= visibleFrame.maxX
        let fitsLeft = leftOrigin >= visibleFrame.minX
        let opensToRight = fitsRight || !fitsLeft
        let proposedX = opensToRight ? rightOrigin : leftOrigin
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let x = min(max(proposedX, visibleFrame.minX), maximumX)

        let alignedTop = anchorRect.midY + contentTopInset + rowHeight / 2
        let proposedY = alignedTop - panelSize.height
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        let y = min(max(proposedY, visibleFrame.minY), maximumY)
        return ServerMenuPlacement(origin: CGPoint(x: x, y: y), opensToRight: opensToRight)
    }
}

enum SettingsWindowLayout {
    static let preferredContentSize = CGSize(width: 800, height: 650)
    static let minimumContentSize = CGSize(width: 620, height: 440)
    static let screenMargin: CGFloat = 24

    static func contentSize(visibleScreenSize: CGSize) -> CGSize {
        let availableWidth = max(0, visibleScreenSize.width - screenMargin * 2)
        let availableHeight = max(0, visibleScreenSize.height - screenMargin * 2)
        return CGSize(
            width: min(preferredContentSize.width, availableWidth),
            height: min(preferredContentSize.height, availableHeight)
        )
    }

    // Resizing is allowed, but do not require a minimum larger than the
    // available screen on a small display.
    static func minimumResizableContentSize(visibleScreenSize: CGSize) -> CGSize {
        let screenFittingSize = contentSize(visibleScreenSize: visibleScreenSize)
        return CGSize(
            width: min(minimumContentSize.width, screenFittingSize.width),
            height: min(minimumContentSize.height, screenFittingSize.height)
        )
    }
}

// Native NSMenu cannot grow to show long multiline connection errors reliably.
// Keep its status label concise; display and copy the complete message in Settings.
// Do not use a stored error after the status has recovered.
enum SettingsConnectionError {
    static func fullMessage(status: ConnectionStatus, lastError: String?) -> String? {
        guard status == .error, let lastError, !lastError.isEmpty else { return nil }
        return lastError
    }
}

// Pure helper keeps tab edge behavior testable without AppKit or a live Settings window.
enum SettingsTabNavigation {
    static func nextIndex(current: Int, offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + offset, 0), count - 1)
    }
}

// A sidebar is a single vertical sequence: General, then saved servers.
// Selection and keyboard focus stay in the sidebar on Up/Down. Only an
// explicit Right arrow can transfer focus to the Connection tab.
enum SettingsSidebarNavigation {
    static let generalTag = "general"
    static let noServersTag = "servers-empty"

    static func serverTag(_ id: UUID) -> String { "server:\(id.uuidString)" }

    static func selection(from current: String, offset: Int, serverIDs: [UUID]) -> String {
        let items = [generalTag] + (serverIDs.isEmpty ? [noServersTag] : serverIDs.map(serverTag))
        let index = items.firstIndex(of: current) ?? 0
        let destination = min(max(index + offset, 0), items.count - 1)
        return items[destination]
    }
}

// Keyboard transitions between the selected server in Settings' sidebar and
// the Connection/SSH Key/VNC Server tab strip. These decisions do not alter
// the active server or intercept arrow keys in the editable detail controls.
enum SettingsPaneDestination: Equatable {
    case connectionTab
    case sidebarServer
    case tab(Int)
    case unchanged
}

enum SettingsPaneNavigation {
    static func rightFromSidebar(hasSelectedServer: Bool) -> SettingsPaneDestination {
        hasSelectedServer ? .connectionTab : .unchanged
    }

    static func leftFromTab(currentIndex: Int, tabCount: Int) -> SettingsPaneDestination {
        guard tabCount > 0, (0..<tabCount).contains(currentIndex) else { return .unchanged }
        return currentIndex == 0 ? .sidebarServer : .tab(currentIndex - 1)
    }
}

// Native MenuBarExtra's state presentation is entirely declarative.
// A native NSMenu disables and greys out non-actionable rows; using a real
// Settings action for the status provides readable text and is accessible.
// The native menu title starts with a coloured emoji because SwiftUI may
// omit Label icons from NSMenu rows. The separately rendered menu-bar badge
// uses original colour rather than relying on .foregroundStyle tinting.
struct NativeMenuStatusPresentation: Equatable {
    let menuTitle: String
    let accessibilityLabel: String
    let helpText: String

    static func make(status: ConnectionStatus, serverName: String, hasProfiles: Bool) -> Self {
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = hasProfiles && !name.isEmpty ? name : "No server configured"
        switch status {
        case .disconnected:
            if !hasProfiles {
                return Self(menuTitle: "⚪ No VNC Servers Configured",
                            accessibilityLabel: "No VNC Servers Configured. Open Settings.",
                            helpText: "Add a VNC server in Settings to enable Connect")
            }
            return Self(menuTitle: "⚪ Disconnected · \(target)",
                        accessibilityLabel: "Disconnected. \(target). Open Settings.",
                        helpText: "Open Settings to view the connection configuration")
        case .connecting:
            return Self(menuTitle: "🟠 Connecting to \(target)…",
                        accessibilityLabel: "Connecting to \(target). Open Settings.",
                        helpText: "Open Settings to inspect the connection")
        case .connected:
            return Self(menuTitle: "🟢 Connected to \(target)",
                        accessibilityLabel: "Connected to \(target). Open Settings.",
                        helpText: "Open Settings to inspect the active server")
        case .disconnecting:
            return Self(menuTitle: "🟠 Disconnecting from \(target)…",
                        accessibilityLabel: "Disconnecting from \(target). Open Settings.",
                        helpText: "Open Settings to inspect the connection")
        case .error:
            return Self(menuTitle: "🔴 Connection Error · Details…",
                        accessibilityLabel: "Connection Error. Open Settings for details.",
                        helpText: "Open Settings for the full error message")
        }
    }
}

// Native MenuBarExtra policy: testable independently from macOS menu rendering.
// In particular, Cancel Connection remains available while connect() is busy,
// and Retry must not apply to another server or altered settings.
enum NativeMenuActionPolicy {
    static func canSelectServer(
        status: ConnectionStatus, isBusy: Bool, hasActiveSession: Bool = false
    ) -> Bool {
        // A failed Disconnect can leave a live tunnel despite `.error` status.
        // Treat it as a session until cleanup has actually succeeded.
        !hasActiveSession && !isBusy && (status == .disconnected || status == .error)
    }

    static func action(
        status: ConnectionStatus,
        serverName: String,
        hasProfiles: Bool,
        canRetrySelectedConnection: Bool
    ) -> ConnectionMenuAction {
        guard hasProfiles else {
            return ConnectionMenuAction(
                title: "Connect", systemImage: "play.fill",
                operation: .connect, isEnabled: false
            )
        }
        if status == .error && !canRetrySelectedConnection {
            return ConnectionStatus.disconnected.menuAction(serverName: serverName)
        }
        return status.menuAction(serverName: serverName)
    }
}

enum MainMenuItemID: Hashable, CaseIterable {
    case server
    case connection
    case settings
    case quit
}

struct MainMenuInteractionState: Equatable {
    private(set) var inputMode: ServerMenuInputMode = .pointer
    private(set) var hoveredItemID: MainMenuItemID?
    private(set) var keyboardItemID: MainMenuItemID?

    mutating func pointerMoved(over itemID: MainMenuItemID?) {
        inputMode = .pointer
        hoveredItemID = itemID
        keyboardItemID = nil
    }

    mutating func pointerExited(_ itemID: MainMenuItemID) {
        if hoveredItemID == itemID { hoveredItemID = nil }
    }

    mutating func activateKeyboard(initialItemID: MainMenuItemID?) {
        inputMode = .keyboard
        hoveredItemID = nil
        keyboardItemID = initialItemID
    }

    mutating func moveKeyboard(by offset: Int, orderedItemIDs: [MainMenuItemID]) {
        guard !orderedItemIDs.isEmpty else {
            activateKeyboard(initialItemID: nil)
            return
        }
        inputMode = .keyboard
        hoveredItemID = nil
        guard let keyboardItemID,
              let currentIndex = orderedItemIDs.firstIndex(of: keyboardItemID) else {
            self.keyboardItemID = offset < 0 ? orderedItemIDs.last : orderedItemIDs.first
            return
        }
        let count = orderedItemIDs.count
        self.keyboardItemID = orderedItemIDs[(currentIndex + offset + count) % count]
    }

    mutating func suspendForChildMenu() {
        hoveredItemID = nil
        keyboardItemID = nil
    }

    mutating func reconcile(orderedItemIDs: [MainMenuItemID]) {
        if let hoveredItemID, !orderedItemIDs.contains(hoveredItemID) {
            self.hoveredItemID = nil
        }
        if inputMode == .keyboard,
           let keyboardItemID,
           !orderedItemIDs.contains(keyboardItemID) {
            self.keyboardItemID = orderedItemIDs.first
        }
    }

    func isHighlighted(_ itemID: MainMenuItemID) -> Bool {
        switch inputMode {
        case .pointer: hoveredItemID == itemID
        case .keyboard: keyboardItemID == itemID
        }
    }

    func accessibilityValue(for itemID: MainMenuItemID) -> String {
        guard isHighlighted(itemID) else { return "Idle" }
        return inputMode == .keyboard ? "Keyboard Focus" : "Hovered"
    }
}

enum ServerMenuItemID: Hashable {
    case server(UUID)
    case addServer
    case manageServers
}

enum ServerMenuInputMode: Equatable {
    case pointer
    case keyboard
}

enum ServerMenuHighlight: Equatable {
    case none
    case pointer
    case keyboard
}

struct ServerMenuInteractionState: Equatable {
    private(set) var isPresented = false
    private(set) var inputMode: ServerMenuInputMode = .pointer
    private(set) var isTriggerHovered = false
    private(set) var isListHovered = false
    private(set) var hoveredItemID: ServerMenuItemID?
    private(set) var keyboardItemID: ServerMenuItemID?

    var activeItemID: ServerMenuItemID? {
        switch inputMode {
        case .pointer: hoveredItemID
        case .keyboard: keyboardItemID
        }
    }

    mutating func setTriggerHovered(_ isHovered: Bool) {
        isTriggerHovered = isHovered
    }

    mutating func setListHovered(_ isHovered: Bool) {
        isListHovered = isHovered
    }

    mutating func presentPointer() {
        isPresented = true
        inputMode = .pointer
        hoveredItemID = nil
        keyboardItemID = nil
    }

    mutating func presentKeyboard(initialItemID: ServerMenuItemID?) {
        isPresented = true
        inputMode = .keyboard
        hoveredItemID = nil
        keyboardItemID = initialItemID
    }

    mutating func pointerMoved(over itemID: ServerMenuItemID?) {
        inputMode = .pointer
        hoveredItemID = itemID
        keyboardItemID = nil
    }

    mutating func pointerExited(_ itemID: ServerMenuItemID) {
        if hoveredItemID == itemID { hoveredItemID = nil }
    }

    mutating func activateKeyboard(initialItemID: ServerMenuItemID?) {
        inputMode = .keyboard
        hoveredItemID = nil
        keyboardItemID = initialItemID
    }

    mutating func moveKeyboard(by offset: Int, orderedItemIDs: [ServerMenuItemID]) {
        guard !orderedItemIDs.isEmpty else {
            activateKeyboard(initialItemID: nil)
            return
        }
        inputMode = .keyboard
        hoveredItemID = nil
        guard let keyboardItemID,
              let currentIndex = orderedItemIDs.firstIndex(of: keyboardItemID) else {
            self.keyboardItemID = offset < 0 ? orderedItemIDs.last : orderedItemIDs.first
            return
        }
        let count = orderedItemIDs.count
        self.keyboardItemID = orderedItemIDs[(currentIndex + offset + count) % count]
    }

    mutating func dismiss(retaining inputMode: ServerMenuInputMode) {
        guard isPresented else { return }
        isPresented = false
        self.inputMode = inputMode
        isTriggerHovered = false
        isListHovered = false
        hoveredItemID = nil
        keyboardItemID = nil
    }

    func highlight(for itemID: ServerMenuItemID) -> ServerMenuHighlight {
        switch inputMode {
        case .pointer:
            hoveredItemID == itemID ? .pointer : .none
        case .keyboard:
            keyboardItemID == itemID ? .keyboard : .none
        }
    }
}

// A menu-bar utility does not quit with Command-Q. The only user-controlled
// normal Quit action is the explicit item in the native status menu. Genuine
// system termination (logout/restart/shutdown) remains unaffected.
enum AppQuitShortcutPolicy {
    enum Action: Equatable {
        case closeSettings
        case ignore
        case allowTermination
    }

    static func isCommandQ(
        characters: String?, hasCommand: Bool, hasShift: Bool,
        hasControl: Bool, hasOption: Bool
    ) -> Bool {
        hasCommand && !hasShift && !hasControl && !hasOption &&
            characters?.lowercased() == "q"
    }

    static func action(
        isCommandQ: Bool,
        settingsIsActive: Bool,
        explicitMenuQuit: Bool
    ) -> Action {
        guard isCommandQ && !explicitMenuQuit else { return .allowTermination }
        return settingsIsActive ? .closeSettings : .ignore
    }
}

// A known_hosts *absence* is not yet a host-key approval request. Approval
// becomes possible only after a successful fingerprint scan and must always
// require an explicit user decision. A failed scan is reported as an error.
enum SSHHostVerificationPresentation: Equatable {
    case notConfigured
    case checking
    case notVerified
    case approvalRequired
    case verified
    case error

    static func evaluate(
        configured: Bool, hasError: Bool,
        hasPendingApproval: Bool, hostIsKnown: Bool?
    ) -> Self {
        if hasError { return .error }
        if !configured { return .notConfigured }
        if hasPendingApproval { return .approvalRequired }
        switch hostIsKnown {
        case .some(true): return .verified
        case .some(false): return .notVerified
        case .none: return .checking
        }
    }

    var title: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .checking: return "Checking host key"
        case .notVerified: return "SSH host not verified"
        case .approvalRequired: return "Host key approval required"
        case .verified: return "Ready"
        case .error: return "Error"
        }
    }
}
