// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
// Build 31.9.4 — one native NSStatusItem provides animation and the menu.
// SSH / TigerVNC lifetime remains exclusively in ConnectionController.

import AppKit
import Combine

@MainActor
final class AnimatedStatusMenuCoordinator: NSObject, NSMenuDelegate {
    private let controller: ConnectionController
    private var statusItem: NSStatusItem?
    private var overlay: AnimatedStatusIconOverlay?
    private let menu = NSMenu(title: "Astroberry VNC")
    private var cancellables: Set<AnyCancellable> = []
    private weak var statusMenuItem: NSMenuItem?
    private weak var connectionMenuItem: NSMenuItem?
    private weak var serverMenuItem: NSMenuItem?

    init(controller: ConnectionController) {
        self.controller = controller
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 34)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.title = ""
        button.image = nil
        let icon = AnimatedStatusIconOverlay(frame: button.bounds)
        icon.autoresizingMask = [.width, .height]
        button.addSubview(icon)
        overlay = icon
        statusItem = item
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateStatus(controller.status)

        // This subscription observes the existing published status; it never
        // writes controller state or refreshes the status-bar button image.
        controller.$status.sink { [weak self] next in
            Task { @MainActor [weak self] in self?.updateStatus(next) }
        }.store(in: &cancellables)
        controller.$isBusy.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshVisibleItemTitles() }
        }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    func stop() {
        cancellables.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        menu.delegate = nil
        statusItem?.menu = nil
        overlay?.removeFromSuperview()
        overlay = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func updateStatus(_ status: ConnectionStatus) {
        overlay?.setStatus(status)
        statusItem?.button?.toolTip = "Astroberry VNC — \(status.title)"
        refreshVisibleItemTitles()
    }

    @objc private func accessibilityChanged(_ notification: Notification) {
        overlay?.refreshReduceMotion()
    }

    // Called on each menu open; no timer or polling is needed. Native NSMenu
    // handles mouse navigation, submenus, keyboard arrows, Return and Escape.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let status = NativeMenuStatusPresentation.make(
            status: controller.status, serverName: selectedName,
            hasProfiles: !controller.profiles.isEmpty
        )
        let statusItem = addItem(status.menuTitle, action: #selector(openSettings(_:)))
        statusItem.toolTip = controller.lastError ?? controller.securityAdvisory ?? status.helpText
        statusMenuItem = statusItem

        if let error = SettingsConnectionError.fullMessage(
            status: controller.status, lastError: controller.lastError
        ) {
            let copy = addItem("Copy Full Error Message", action: #selector(copyError(_:)))
            copy.representedObject = error
        }
        menu.addItem(.separator())

        if controller.profiles.isEmpty {
            let server = addItem("VNC Server", action: nil)
            server.isEnabled = false
            let connect = addItem("Connect", action: nil)
            connect.isEnabled = false
            connectionMenuItem = connect
            menu.addItem(.separator())
            addItem("Add VNC Server…", action: #selector(addServer(_:)))
        } else {
            let parent = addItem("VNC Server: \(selectedName)", action: nil)
            serverMenuItem = parent
            let sub = NSMenu(title: "VNC Server")
            sub.autoenablesItems = false
            for profile in controller.profiles {
                let item = NSMenuItem(
                    title: displayName(for: profile),
                    action: #selector(selectServer(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id.uuidString
                item.state = profile.id == controller.selectedProfileID ? .on : .off
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let add = NSMenuItem(title: "Add Server…", action: #selector(addServer(_:)),
                                 keyEquivalent: "")
            add.target = self
            sub.addItem(add)
            let manage = NSMenuItem(title: "Manage Servers…",
                                    action: #selector(openSettings(_:)), keyEquivalent: "")
            manage.target = self
            sub.addItem(manage)
            parent.submenu = sub

            let action = connectionAction
            let connect = addItem(action.title, action: #selector(performConnection(_:)))
            connect.isEnabled = action.isEnabled
            connectionMenuItem = connect
        }

        menu.addItem(.separator())
        addItem("Settings…", action: #selector(openSettings(_:)))
        menu.addItem(.separator())
        addItem("Quit Astroberry VNC", action: #selector(quit(_:)))
        refreshVisibleItemTitles()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private var selectedName: String {
        guard let profile = controller.selectedProfile else { return "No Servers Configured" }
        return displayName(for: profile)
    }

    private func displayName(for profile: VNCServerProfile) -> String {
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? profile.server : name
    }

    private var connectionAction: ConnectionMenuAction {
        if controller.status == .error && controller.connectedProfileID != nil {
            return ConnectionMenuAction(
                title: "Retry Disconnect from \(selectedName)", systemImage: "stop.fill",
                operation: .disconnect, isEnabled: !controller.isBusy
            )
        }
        return NativeMenuActionPolicy.action(
            status: controller.status, serverName: selectedName,
            hasProfiles: !controller.profiles.isEmpty,
            canRetrySelectedConnection: controller.canRetrySelectedConnection
        )
    }

    private func refreshVisibleItemTitles() {
        if let statusMenuItem {
            let status = NativeMenuStatusPresentation.make(
                status: controller.status, serverName: selectedName,
                hasProfiles: !controller.profiles.isEmpty
            )
            statusMenuItem.title = status.menuTitle
        }
        if let connectionMenuItem {
            let action = connectionAction
            connectionMenuItem.title = action.title
            connectionMenuItem.isEnabled = action.isEnabled
        }
        serverMenuItem?.isEnabled = NativeMenuActionPolicy.canSelectServer(
            status: controller.status, isBusy: controller.isBusy,
            hasActiveSession: controller.connectedProfileID != nil
        )
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let uuid = UUID(uuidString: id),
              controller.profiles.contains(where: { $0.id == uuid }),
              NativeMenuActionPolicy.canSelectServer(
                  status: controller.status, isBusy: controller.isBusy,
                  hasActiveSession: controller.connectedProfileID != nil
              ) else { return }
        controller.selectedProfileID = uuid
    }

    @objc private func performConnection(_ sender: NSMenuItem) {
        let action = connectionAction
        guard action.isEnabled else { return }
        switch action.operation {
        case .connect, .retry:
            NSApp.activate()
            Task { await controller.connect() }
        case .cancel, .disconnect:
            Task { await controller.disconnect() }
        case .disconnecting:
            break
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        showSettings()
    }

    @objc private func addServer(_ sender: NSMenuItem) {
        let id = controller.addProfile()
        showSettings(editingProfileID: id)
    }

    private func showSettings(editingProfileID: UUID? = nil) {
        // Open after native tracking has completed; avoids focus/Space races.
        DispatchQueue.main.async { [controller] in
            SettingsWindowCoordinator.presentOnActiveSpace(
                controller: controller, editingProfileID: editingProfileID
            )
        }
    }

    @objc private func copyError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        AppQuitRequest.requestMenuQuit()
    }
}
