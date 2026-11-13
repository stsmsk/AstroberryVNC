// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

extension Notification.Name {
    static let dismissAstroberryServerMenu = Notification.Name("DismissAstroberryServerMenu")
    static let focusAstroberryMainMenu = Notification.Name("FocusAstroberryMainMenu")
    static let dismissAstroberryMainMenu = Notification.Name("DismissAstroberryMainMenu")
}

struct MenuContentView: View {
    @ObservedObject var controller: ConnectionController
    let openSettingsAction: () -> Void
    @StateObject private var serverMenuPresenter = ServerMenuPresenter()
    @State private var mainMenuInteraction = MainMenuInteractionState()

    private var selectedName: String {
        guard let profile = controller.selectedProfile else { return "No Servers Configured" }
        return profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? profile.server : profile.displayName
    }

    private var serverSelectionIsDisabled: Bool {
        controller.isBusy || [.connecting, .connected, .disconnecting].contains(controller.status)
    }

    private var statusDetail: String {
        switch controller.status {
        case .disconnected:
            "Not connected"
        case .connecting, .disconnecting:
            selectedName
        case .connected:
            if let port = controller.activeLocalPort { "\(selectedName) · 127.0.0.1:\(port)" }
            else { selectedName }
        case .error:
            controller.lastError ?? "The connection could not be completed"
        }
    }

    private var connectionAction: ConnectionMenuAction {
        guard !controller.profiles.isEmpty else {
            return ConnectionMenuAction(
                title: "Connect to No Servers Configured", systemImage: "play.fill",
                operation: .connect, isEnabled: false
            )
        }
        if controller.status == .error, !controller.canRetrySelectedConnection {
            return ConnectionStatus.disconnected.menuAction(serverName: selectedName)
        }
        return controller.status.menuAction(serverName: selectedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            menuDivider

            serverMenu

            menuDivider

            MenuActionRow(
                itemID: .connection,
                title: connectionAction.title,
                systemImage: connectionAction.systemImage,
                isEnabled: connectionAction.isEnabled,
                isHighlighted: mainMenuInteraction.isHighlighted(.connection),
                highlightValue: mainMenuInteraction.accessibilityValue(for: .connection),
                accessibilityIdentifier: "connectionActionRow",
                onHoverChanged: mainMenuHoverChanged,
                action: performConnectionAction
            )
            .keyboardShortcut(connectionShortcut)

            menuDivider

            MenuActionRow(
                itemID: .settings,
                title: "Settings…",
                systemImage: "gearshape",
                isHighlighted: mainMenuInteraction.isHighlighted(.settings),
                highlightValue: mainMenuInteraction.accessibilityValue(for: .settings),
                accessibilityIdentifier: "settingsRow",
                onHoverChanged: mainMenuHoverChanged
            ) {
                openSettings()
            }
            .keyboardShortcut(",")

            menuDivider

            MenuActionRow(
                itemID: .quit,
                title: "Quit Astroberry VNC",
                systemImage: "power",
                isHighlighted: mainMenuInteraction.isHighlighted(.quit),
                highlightValue: mainMenuInteraction.accessibilityValue(for: .quit),
                accessibilityIdentifier: "quitRow",
                onHoverChanged: mainMenuHoverChanged
            ) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(width: 300)
        .background(
            MainMenuKeyboardBridge(
                isChildMenuPresented: serverMenuPresenter.interaction.isPresented,
                onKeyEvent: handleMainMenuKeyEvent
            )
        )
        .task { await controller.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAstroberryServerMenu)) { _ in
            serverMenuPresenter.dismiss()
        }
        .onChange(of: orderedMainMenuItemIDs) { _, itemIDs in
            mainMenuInteraction.reconcile(orderedItemIDs: itemIDs)
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(controller.status.color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status.title)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(statusDetail)
                if let advisory = controller.securityAdvisory {
                    Text(advisory)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(advisory)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(controller.status.title). \(statusDetail)")
    }

    private var serverMenu: some View {
        ServerPickerRow(
            presenter: serverMenuPresenter,
            profiles: controller.profiles,
            selectedProfileID: controller.selectedProfileID,
            selectedName: selectedName,
            isDisabled: serverSelectionIsDisabled,
            profileName: profileName,
            onSelect: { controller.selectedProfileID = $0 },
            onManage: { openServerSettings(addServer: false) },
            onAdd: { openServerSettings(addServer: true) },
            isHighlighted: mainMenuInteraction.isHighlighted(.server),
            highlightValue: mainMenuInteraction.accessibilityValue(for: .server),
            onHoverChanged: mainMenuHoverChanged,
            onRestoreParentFocus: restoreServerKeyboardFocus,
            onMoveParentKeyboard: moveMainMenuKeyboard
        )
    }

    private var menuDivider: some View {
        Divider().padding(.horizontal, 8)
    }

    private var connectionShortcut: KeyEquivalent {
        switch connectionAction.operation {
        case .disconnect, .disconnecting: "d"
        case .cancel: "."
        case .connect, .retry: "c"
        }
    }

    private func performConnectionAction() {
        switch connectionAction.operation {
        case .connect, .retry:
            Task { await controller.connect() }
        case .cancel, .disconnect:
            Task { await controller.disconnect() }
        case .disconnecting:
            break
        }
    }

    private func profileName(_ profile: VNCServerProfile) -> String {
        let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? profile.server : displayName
    }

    private func openServerSettings(addServer: Bool) {
        if addServer { controller.addProfile() }
        UserDefaults.standard.set("server:\(controller.selectedProfileID.uuidString)", forKey: "SettingsSidebarSelection")
        openSettings()
    }

    private func openSettings() {
        // Close both panels synchronously before making Settings the key window.
        serverMenuPresenter.dismiss()
        NotificationCenter.default.post(name: .dismissAstroberryMainMenu, object: nil)
        openSettingsAction()
    }

    private var orderedMainMenuItemIDs: [MainMenuItemID] {
        var items: [MainMenuItemID] = []
        if !serverSelectionIsDisabled { items.append(.server) }
        if connectionAction.isEnabled { items.append(.connection) }
        items.append(contentsOf: [.settings, .quit])
        return items
    }

    private func mainMenuHoverChanged(_ itemID: MainMenuItemID, _ isHovered: Bool) {
        if isHovered {
            mainMenuInteraction.pointerMoved(over: itemID)
            if itemID != .server { serverMenuPresenter.dismiss() }
        } else {
            mainMenuInteraction.pointerExited(itemID)
        }
    }

    private func handleMainMenuKeyEvent(_ event: NSEvent) -> Bool {
        guard !serverMenuPresenter.interaction.isPresented else { return false }
        switch event.keyCode {
        case 125: // Down
            moveMainMenuKeyboard(by: 1)
        case 126: // Up
            moveMainMenuKeyboard(by: -1)
        case 124: // Right
            guard mainMenuInteraction.keyboardItemID == .server,
                  !serverSelectionIsDisabled else { return false }
            mainMenuInteraction.suspendForChildMenu()
            serverMenuPresenter.presentFromKeyboard(entry: .selected)
        case 36, 49: // Return, Space
            guard let itemID = mainMenuInteraction.keyboardItemID else { return false }
            performMainMenuAction(itemID)
        default:
            return false
        }
        return true
    }

    private func performMainMenuAction(_ itemID: MainMenuItemID) {
        switch itemID {
        case .server:
            guard !serverSelectionIsDisabled else { return }
            mainMenuInteraction.suspendForChildMenu()
            serverMenuPresenter.presentFromKeyboard(entry: .selected)
        case .connection:
            guard connectionAction.isEnabled else { return }
            performConnectionAction()
        case .settings:
            openSettings()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func moveMainMenuKeyboard(by offset: Int) {
        let previous = mainMenuInteraction.keyboardItemID
        mainMenuInteraction.moveKeyboard(by: offset, orderedItemIDs: orderedMainMenuItemIDs)
        if mainMenuInteraction.keyboardItemID == .server, previous != .server {
            // Show the submenu as a preview; Right explicitly enters it.
            serverMenuPresenter.presentForParentKeyboardFocus()
        } else if mainMenuInteraction.keyboardItemID != .server {
            serverMenuPresenter.dismiss()
        }
    }

    private func restoreServerKeyboardFocus() {
        // Do not reopen automatically after Left/Escape returns from the child.
        mainMenuInteraction.activateKeyboard(initialItemID: .server)
        NotificationCenter.default.post(name: .focusAstroberryMainMenu, object: nil)
    }
}

private struct ServerPickerRow: View {
    @ObservedObject var presenter: ServerMenuPresenter
    let profiles: [VNCServerProfile]
    let selectedProfileID: UUID
    let selectedName: String
    let isDisabled: Bool
    let profileName: (VNCServerProfile) -> String
    let onSelect: (UUID) -> Void
    let onManage: () -> Void
    let onAdd: () -> Void
    let isHighlighted: Bool
    let highlightValue: String
    let onHoverChanged: (MainMenuItemID, Bool) -> Void
    let onRestoreParentFocus: () -> Void
    let onMoveParentKeyboard: (Int) -> Void

    var body: some View {
        Button(action: {
            presenter.openFromPointer()
        }) {
            HStack(spacing: 8) {
                Text("VNC Server")
                Spacer(minLength: 12)
                Text(selectedName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusEffectDisabled()
        .background(
            menuSelectionBackground(
                isVisible: !isDisabled && isHighlighted &&
                    (!presenter.interaction.isPresented || presenter.interaction.inputMode == .pointer)
            )
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        )
        .background {
            GeometryReader { proxy in
                ServerMenuAnchor(
                    presenter: presenter,
                    profiles: profiles,
                    selectedProfileID: selectedProfileID,
                    isDisabled: isDisabled,
                    profileName: profileName,
                    onSelect: onSelect,
                    onManage: onManage,
                    onAdd: onAdd,
                    onRestoreParentFocus: onRestoreParentFocus,
                    onMoveParentKeyboard: onMoveParentKeyboard
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
            }
        }
        .onHover { isHovered in
            onHoverChanged(.server, isHovered)
            presenter.triggerHoverChanged(isHovered)
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled { presenter.dismiss() }
        }
        .accessibilityLabel("VNC Server")
        .accessibilityValue("\(selectedName); \(interactionState)")
        .accessibilityIdentifier("serverMenuRow")
        .accessibilityHint(isDisabled ? "Unavailable during a connection" : "Shows the saved VNC servers")
        .help(isDisabled ? "The VNC server cannot be changed during a connection" : "Choose a VNC server")
    }

    private var interactionState: String {
        highlightValue
    }
}

private struct ServerMenuAnchor: NSViewRepresentable {
    let presenter: ServerMenuPresenter
    let profiles: [VNCServerProfile]
    let selectedProfileID: UUID
    let isDisabled: Bool
    let profileName: (VNCServerProfile) -> String
    let onSelect: (UUID) -> Void
    let onManage: () -> Void
    let onAdd: () -> Void
    let onRestoreParentFocus: () -> Void
    let onMoveParentKeyboard: (Int) -> Void

    func makeNSView(context: Context) -> ServerMenuAnchorView {
        ServerMenuAnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: ServerMenuAnchorView, context: Context) {
        nsView.presenter = presenter
        presenter.configure(
            anchorView: nsView,
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            isDisabled: isDisabled,
            profileName: profileName,
            onSelect: onSelect,
            onManage: onManage,
            onAdd: onAdd,
            onRestoreParentFocus: onRestoreParentFocus,
            onMoveParentKeyboard: onMoveParentKeyboard
        )
    }
}

private final class ServerMenuAnchorView: NSView {
    weak var presenter: ServerMenuPresenter?
}

@MainActor
private final class ServerMenuPresenter: NSObject, ObservableObject {
    enum KeyboardEntry {
        case first
        case last
        case selected
    }

    @Published private(set) var interaction = ServerMenuInteractionState()

    private weak var anchorView: NSView?
    private weak var parentWindow: NSWindow?
    private var profiles: [VNCServerProfile] = []
    private var selectedProfileID = UUID()
    private var isDisabled = false
    private var profileName: (VNCServerProfile) -> String = { $0.server }
    private var onSelect: (UUID) -> Void = { _ in }
    private var onManage: () -> Void = {}
    private var onAdd: () -> Void = {}
    private var onRestoreParentFocus: () -> Void = {}
    private var onMoveParentKeyboard: (Int) -> Void = { _ in }
    private var menuPanel: ServerMenuPanel?
    private var presentationTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var keyEventMonitor: Any?
    private var orderedItemIDs: [ServerMenuItemID] = []
    private var selectedItemID: ServerMenuItemID?
    private var keyboardFocusPreview = false
    private var suppressHoverReopenUntilExit = false

    func configure(
        anchorView: NSView,
        profiles: [VNCServerProfile],
        selectedProfileID: UUID,
        isDisabled: Bool,
        profileName: @escaping (VNCServerProfile) -> String,
        onSelect: @escaping (UUID) -> Void,
        onManage: @escaping () -> Void,
        onAdd: @escaping () -> Void,
        onRestoreParentFocus: @escaping () -> Void,
        onMoveParentKeyboard: @escaping (Int) -> Void
    ) {
        let becameDisabled = !self.isDisabled && isDisabled
        self.anchorView = anchorView
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.isDisabled = isDisabled
        self.profileName = profileName
        self.onSelect = onSelect
        self.onManage = onManage
        self.onAdd = onAdd
        self.onRestoreParentFocus = onRestoreParentFocus
        self.onMoveParentKeyboard = onMoveParentKeyboard
        if becameDisabled { dismiss() }
    }

    func triggerHoverChanged(_ isHovered: Bool) {
        let wasHovered = interaction.isTriggerHovered
        updateInteraction { $0.setTriggerHovered(isHovered) }
        if isHovered {
            dismissalTask?.cancel()
            guard !interaction.isPresented, !suppressHoverReopenUntilExit else { return }
            schedulePresentation()
        } else {
            suppressHoverReopenUntilExit = false
            presentationTask?.cancel()
            if wasHovered { scheduleDismissalIfOutside() }
        }
    }

    func openFromPointer() {
        // Clicking a hover-opened submenu must not unexpectedly close it.
        guard !interaction.isPresented else { return }
        suppressHoverReopenUntilExit = false
        presentPanel(keyboardEntry: nil, retryIfUnavailable: true, requireTriggerHover: false)
    }

    func presentForParentKeyboardFocus() {
        guard !isDisabled else { return }
        // Preserve this intent even if the anchor requires the one-frame retry.
        keyboardFocusPreview = true
        if !interaction.isPresented {
            presentPanel(keyboardEntry: nil, retryIfUnavailable: true, requireTriggerHover: false)
        }
    }

    func presentFromKeyboard(entry: KeyboardEntry) {
        keyboardFocusPreview = false
        presentationTask?.cancel()
        dismissalTask?.cancel()
        if interaction.isPresented {
            promoteToKeyboard(entry: entry)
        } else {
            presentPanel(keyboardEntry: entry, retryIfUnavailable: true, requireTriggerHover: false)
        }
    }

    func toggleFromKeyboard(entry: KeyboardEntry) {
        if interaction.isPresented { dismiss(restoreParentKeyboardFocus: true) }
        else { presentFromKeyboard(entry: entry) }
    }

    func dismiss(restoreParentKeyboardFocus: Bool = false) {
        presentationTask?.cancel()
        dismissalTask?.cancel()
        if restoreParentKeyboardFocus { suppressHoverReopenUntilExit = true }
        keyboardFocusPreview = false
        guard interaction.isPresented || menuPanel != nil else { return }
        removeKeyEventMonitor()
        let restorationWindow = parentWindow
        if let menuPanel {
            let childWasKey = menuPanel.isKeyWindow
            let parentWindow = menuPanel.parent ?? self.parentWindow
            menuPanel.parent?.removeChildWindow(menuPanel)
            menuPanel.orderOut(nil)
            if restoreParentKeyboardFocus {
                parentWindow?.makeKey()
            } else if childWasKey {
                parentWindow?.makeKey()
            }
        }
        self.menuPanel = nil
        parentWindow = nil
        orderedItemIDs = []
        selectedItemID = nil
        updateInteraction { $0.dismiss(retaining: restoreParentKeyboardFocus ? .keyboard : .pointer) }
        if restoreParentKeyboardFocus {
            restorationWindow?.makeKey()
            onRestoreParentFocus()
        }
    }

    private func schedulePresentation() {
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ServerMenuDismissalPolicy.presentationDelayMilliseconds))
            guard !Task.isCancelled, let self, self.interaction.isTriggerHovered else { return }
            self.presentPanel(
                keyboardEntry: nil,
                retryIfUnavailable: true,
                requireTriggerHover: true
            )
        }
    }

    private func presentPanel(
        keyboardEntry: KeyboardEntry?,
        retryIfUnavailable: Bool,
        requireTriggerHover: Bool
    ) {
        guard !isDisabled, !interaction.isPresented else { return }
        if requireTriggerHover, !interaction.isTriggerHovered { return }
        guard let anchorView, let parentWindow = anchorView.window else {
            if retryIfUnavailable {
                scheduleSingleAnchorRetry(
                    keyboardEntry: keyboardEntry,
                    requireTriggerHover: requireTriggerHover
                )
            }
            return
        }
        presentationTask?.cancel()

        let entries = ServerMenuSnapshot.entries(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            profileName: profileName
        )
        orderedItemIDs = entries.isEmpty
            ? [.addServer]
            : entries.map { .server($0.id) } + [.manageServers]
        selectedItemID = entries.first(where: \.isSelected).map { .server($0.id) }

        let content = ServerListView(
            entries: entries,
            presenter: self,
            onHoverChanged: { [weak self] isHovered in self?.listHoverChanged(isHovered) },
            onPointerAction: { [weak self] itemID in self?.performAction(itemID, fromKeyboard: false) }
        )
        let hostingController = NSHostingController(rootView: content)
        let size = panelSize(entryCount: entries.count)
        let panel = ServerMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.setContentSize(size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.setFrameOrigin(panelOrigin(for: size, anchorView: anchorView, parentWindow: parentWindow))

        self.parentWindow = parentWindow
        parentWindow.addChildWindow(panel, ordered: .above)
        menuPanel = panel
        if let keyboardEntry {
            updateInteraction { $0.presentKeyboard(initialItemID: initialItem(for: keyboardEntry)) }
        } else {
            updateInteraction { $0.presentPointer() }
        }
        installKeyEventMonitor()
        panel.orderFrontRegardless()
        if keyboardEntry != nil { makeChildKey() }
    }

    private func panelSize(entryCount: Int) -> NSSize {
        let rowCount = entryCount == 0 ? 2 : entryCount + 1
        let height = min(CGFloat(rowCount * 30 + 18), 360)
        return NSSize(width: 250, height: height)
    }

    private func scheduleSingleAnchorRetry(
        keyboardEntry: KeyboardEntry?,
        requireTriggerHover: Bool
    ) {
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.presentPanel(
                keyboardEntry: keyboardEntry,
                retryIfUnavailable: false,
                requireTriggerHover: requireTriggerHover
            )
        }
    }

    private func panelOrigin(for size: NSSize, anchorView: NSView, parentWindow: NSWindow) -> NSPoint {
        let anchorRect = parentWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? parentWindow.screen ?? NSScreen.main
        return ServerMenuPlacementCalculator.placement(
            anchorRect: anchorRect,
            panelSize: size,
            visibleFrame: screen?.visibleFrame ?? .zero
        ).origin
    }

    private func listHoverChanged(_ isHovered: Bool) {
        let wasHovered = interaction.isListHovered
        updateInteraction { $0.setListHovered(isHovered) }
        if isHovered {
            dismissalTask?.cancel()
            if interaction.isTriggerHovered {
                updateInteraction { $0.setTriggerHovered(false) }
            }
        }
        else if wasHovered { scheduleDismissalIfOutside() }
    }

    func itemHoverChanged(_ itemID: ServerMenuItemID, isHovered: Bool) {
        if isHovered {
            updateInteraction { $0.pointerMoved(over: itemID) }
        } else {
            updateInteraction { $0.pointerExited(itemID) }
        }
    }

    private func scheduleDismissalIfOutside() {
        guard interaction.isPresented,
              ServerMenuDismissalPolicy.shouldDismiss(
            isTriggerHovered: interaction.isTriggerHovered,
            isListHovered: interaction.isListHovered
        ) else { return }
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ServerMenuDismissalPolicy.delayMilliseconds))
            guard !Task.isCancelled, let self, self.interaction.isPresented,
                  ServerMenuDismissalPolicy.shouldDismiss(
                    isTriggerHovered: self.interaction.isTriggerHovered,
                    isListHovered: self.interaction.isListHovered
                  ) else { return }
            self.dismiss()
        }
    }

    private func initialItem(for entry: KeyboardEntry) -> ServerMenuItemID? {
        switch entry {
        case .first: orderedItemIDs.first
        case .last: orderedItemIDs.last
        case .selected: selectedItemID ?? orderedItemIDs.first
        }
    }

    private func promoteToKeyboard(entry: KeyboardEntry) {
        keyboardFocusPreview = false
        updateInteraction { $0.activateKeyboard(initialItemID: initialItem(for: entry)) }
        makeChildKey()
    }

    private func makeChildKey() {
        guard let menuPanel else { return }
        menuPanel.makeKey()
        if let contentView = menuPanel.contentView {
            menuPanel.makeFirstResponder(contentView)
        }
    }

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard interaction.isPresented,
              event.window === parentWindow || event.window === menuPanel else { return false }

        if keyboardFocusPreview && event.window === parentWindow {
            switch event.keyCode {
            case 125, 126: // While previewing, Up/Down still navigate the parent.
                let offset = event.keyCode == 125 ? 1 : -1
                dismiss()
                // Dispatch directly: SwiftUI's responder flag may not update in this event cycle.
                onMoveParentKeyboard(offset)
                return true
            case 124, 36, 49: // Right or activation enters the child.
                promoteToKeyboard(entry: .selected)
                return true
            case 123, 53: // Left/Escape close only the preview.
                dismiss(restoreParentKeyboardFocus: true)
                return true
            default:
                break
            }
        }
        switch event.keyCode {
        case 123: // Left
            dismiss(restoreParentKeyboardFocus: true)
        case 124: // Right
            if interaction.inputMode == .pointer { promoteToKeyboard(entry: .selected) }
        case 125: // Down
            if interaction.inputMode == .pointer { promoteToKeyboard(entry: .first) }
            else { updateInteraction { $0.moveKeyboard(by: 1, orderedItemIDs: orderedItemIDs) } }
        case 126: // Up
            if interaction.inputMode == .pointer { promoteToKeyboard(entry: .last) }
            else { updateInteraction { $0.moveKeyboard(by: -1, orderedItemIDs: orderedItemIDs) } }
        case 36, 49: // Return, Space
            if let itemID = interaction.activeItemID {
                performAction(itemID, fromKeyboard: true)
            }
        case 53: // Escape
            dismiss(restoreParentKeyboardFocus: true)
        default:
            return false
        }
        return true
    }

    private func performAction(_ itemID: ServerMenuItemID, fromKeyboard: Bool) {
        switch itemID {
        case .server(let id): onSelect(id)
        case .addServer: onAdd()
        case .manageServers: onManage()
        }
        dismiss(restoreParentKeyboardFocus: fromKeyboard)
    }

    private func updateInteraction(_ update: (inout ServerMenuInteractionState) -> Void) {
        var next = interaction
        update(&next)
        updateInteraction(to: next)
    }

    private func updateInteraction(to next: ServerMenuInteractionState) {
        if next != interaction { interaction = next }
    }

    deinit {
        presentationTask?.cancel()
        dismissalTask?.cancel()
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
    }
}

private final class ServerMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ServerListView: View {
    let entries: [ServerMenuEntry]
    @ObservedObject var presenter: ServerMenuPresenter
    let onHoverChanged: (Bool) -> Void
    let onPointerAction: (ServerMenuItemID) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    ServerListRow(title: "No Servers Configured", isEnabled: false)
                    Divider().padding(.horizontal, 8)
                    ServerListRow(
                        title: "Add Server…",
                        highlight: presenter.interaction.highlight(for: .addServer),
                        accessibilityIdentifier: "addServerRow",
                        onHoverChanged: { presenter.itemHoverChanged(.addServer, isHovered: $0) },
                        action: { onPointerAction(.addServer) }
                    )
                } else {
                    ForEach(entries) { entry in
                        let itemID = ServerMenuItemID.server(entry.id)
                        ServerListRow(
                            title: entry.title,
                            isSelected: entry.isSelected,
                            highlight: presenter.interaction.highlight(for: itemID),
                            accessibilityIdentifier: "serverOption-\(entry.id.uuidString)",
                            onHoverChanged: { presenter.itemHoverChanged(itemID, isHovered: $0) }
                        ) { onPointerAction(itemID) }
                    }
                    Divider().padding(.horizontal, 8)
                    ServerListRow(
                        title: "Manage Servers…",
                        highlight: presenter.interaction.highlight(for: .manageServers),
                        accessibilityIdentifier: "manageServersRow",
                        onHoverChanged: { presenter.itemHoverChanged(.manageServers, isHovered: $0) },
                        action: { onPointerAction(.manageServers) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
        .accessibilityLabel("VNC Servers")
        .accessibilityValue(presenter.interaction.inputMode == .keyboard ? "Keyboard Mode" : "Pointer Mode")
        .accessibilityIdentifier("serverMenuPanel")
    }
}

private struct ServerListRow: View {
    let title: String
    var isSelected = false
    var highlight: ServerMenuHighlight = .none
    var isEnabled = true
    var accessibilityIdentifier = "serverListRow"
    var onHoverChanged: (Bool) -> Void = { _ in }
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .accessibilityIdentifier("selectedServerCheckmark")
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(width: 14)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .background(
            menuSelectionBackground(isVisible: isEnabled && highlight != .none)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
        .onHover(perform: onHoverChanged)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        switch highlight {
        case .none: "Idle"
        case .pointer: "Hovered"
        case .keyboard: "Keyboard Highlighted"
        }
    }
}

private struct MenuActionRow: View {
    let itemID: MainMenuItemID
    let title: String
    let systemImage: String
    var isEnabled = true
    let isHighlighted: Bool
    let highlightValue: String
    let accessibilityIdentifier: String
    var onHoverChanged: (MainMenuItemID, Bool) -> Void = { _, _ in }
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .background(
            menuSelectionBackground(isVisible: isEnabled && isHighlighted)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        )
        .onHover {
            onHoverChanged(itemID, $0)
        }
        .accessibilityLabel(title)
        .accessibilityValue(highlightValue)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MainMenuKeyboardBridge: NSViewRepresentable {
    let isChildMenuPresented: Bool
    let onKeyEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MainMenuResponderView {
        let view = MainMenuResponderView(frame: .zero)
        view.installFocusObserver()
        return view
    }

    func updateNSView(_ nsView: MainMenuResponderView, context: Context) {
        nsView.isChildMenuPresented = isChildMenuPresented
        nsView.onKeyEvent = onKeyEvent
    }
}

private final class MainMenuResponderView: NSView {
    var isChildMenuPresented = false
    var onKeyEvent: (NSEvent) -> Bool = { _ in false }
    private var focusObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    func installFocusObserver() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: .focusAstroberryMainMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is emitted after submenu dismissal. The SwiftUI
            // represented `isChildMenuPresented` flag can still be stale this turn.
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !isChildMenuPresented, onKeyEvent(event) { return }
        super.keyDown(with: event)
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
}

private func menuSelectionBackground(isVisible: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isVisible ? Color.accentColor.opacity(0.18) : Color.clear)
}

private extension ConnectionStatus {
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .disconnecting: .orange
        case .error: .red
        case .disconnected: .secondary
        }
    }
}
