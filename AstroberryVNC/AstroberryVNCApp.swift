// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

@main
struct AstroberryVNCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#if VISUAL_CHECK
    @StateObject private var controller = ConnectionController.visualCheck
#else
    @StateObject private var controller = ConnectionController.shared
#endif

    var body: some Scene {
#if VISUAL_CHECK
        WindowGroup("Astroberry VNC Visual Check") {
            VisualCheckView(controller: controller)
        }
        .defaultSize(width: 760, height: 520)
#else
        // SceneBuilder cannot conditionally declare Scene values with a
        // runtime `if`. Keep the legacy scene declared but insert its status
        // item only when --legacy-static-menu is present. The AppDelegate
        // creates the AppKit status item in the default mode; never show both.
        MenuBarExtra(isInserted: .constant(
            !AnimatedStatusItemPolicy.useAnimatedHost(
                arguments: ProcessInfo.processInfo.arguments
            )
        )) {
            NativeConnectionMenu(controller: controller)
        } label: {
            NativeConnectionMenuBarIcon(status: controller.status)
        }
        .menuBarExtraStyle(.menu)

        // Retain a SwiftUI application lifecycle while AppKit owns the one
        // visible status item in default mode. Settings windows continue to
        // be managed by the existing SettingsWindowCoordinator.
        Settings { EmptyView() }
#endif
    }
}

// Build 31.9.2: static astronomy icon by default, with an explicitly opt-in,
// nonpersistent SF Symbol pulse experiment. Build 31.9's TimelineView caused
// repeated native status-bar image/layout work on the user's Mac. Never
// reintroduce a clock or periodic Image redraw into the MenuBarExtra label.
// Run with --experimental-symbol-effect only for controlled Mac experiments;
// normally retain the Build 31.9.1 safe static behavior.
private struct NativeConnectionMenuBarIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let status: ConnectionStatus

    private var showExperimentalSymbol: Bool {
        MenuBarSymbolEffectExperiment.isActive(
            arguments: ProcessInfo.processInfo.arguments,
            status: status,
            reduceMotion: reduceMotion
        )
    }

    // Keep the exact Build 31.9.1 single-Image structure on normal launches;
    // only explicit experimental launches create the additional SF Symbol view.
    @ViewBuilder
    var body: some View {
        if showExperimentalSymbol,
           let symbol = MenuBarSymbolEffectExperiment.symbolName(for: status) {
            ZStack(alignment: .topLeading) {
                icon(showsCenterGlyph: false)
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        MenuBarStatusIconPainter.colour(
                            for: status, darkMode: colorScheme == .dark
                        )
                    )
                    .frame(width: 10.5, height: 10.5)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                    .offset(x: 12.35, y: 4.1)
                    .accessibilityHidden(true)
            }
            // The frame remains fixed. MenuBarExtra symbol effects still need
            // validation on the user's Intel Mac and may not work as in toolbars.
            .frame(width: 30, height: 22)
            .accessibilityLabel("Astroberry VNC, \(status.title)")
            .help("Astroberry VNC — \(status.title)")
        } else {
            icon(showsCenterGlyph: true)
                .accessibilityLabel("Astroberry VNC, \(status.title)")
                .help("Astroberry VNC — \(status.title)")
        }
    }

    private func icon(showsCenterGlyph: Bool) -> some View {
        Image(
            size: CGSize(width: 30, height: 22),
            label: Text("Astroberry VNC, \(status.title)")
        ) { context in
            MenuBarStatusIconPainter.draw(
                in: context, status: status, phase: 0,
                darkMode: colorScheme == .dark,
                showsCenterGlyph: showsCenterGlyph
            )
        }
        .renderingMode(.original)
        .interpolation(.high)
    }
}

// Coordinates are in a fixed 30×22 pt menu-bar drawing space. Build 31.9.2
// reduces monitor and stand strokes but retains the telescope/star/status size.
// This is a pure drawing layer; it never observes or changes SSH/VNC state.
private enum MenuBarStatusIconPainter {
    static func colour(for status: ConnectionStatus, darkMode: Bool) -> Color {
        switch status {
        case .disconnected:
            return darkMode ? Color(red: 0.88, green: 0.90, blue: 0.94)
                            : Color(red: 0.19, green: 0.24, blue: 0.31)
        case .connecting, .disconnecting:
            return darkMode ? Color(red: 0.37, green: 0.70, blue: 1.00)
                            : Color(red: 0.00, green: 0.40, blue: 0.82)
        case .connected:
            return darkMode ? Color(red: 0.29, green: 0.85, blue: 0.49)
                            : Color(red: 0.00, green: 0.55, blue: 0.19)
        case .error:
            return darkMode ? Color(red: 1.00, green: 0.42, blue: 0.48)
                            : Color(red: 0.87, green: 0.10, blue: 0.19)
        }
    }

    private static func sparkle(at center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 - .pi / 2
            let r = i.isMultiple(of: 2) ? radius : radius * 0.23
            let point = CGPoint(
                x: center.x + r * CGFloat(cos(angle)),
                y: center.y + r * CGFloat(sin(angle))
            )
            if i == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func draw(
        in context: GraphicsContext,
        status: ConnectionStatus,
        phase: Int,
        darkMode: Bool,
        showsCenterGlyph: Bool = true
    ) {
        let tint = colour(for: status, darkMode: darkMode)
        let stroke = StrokeStyle(
            lineWidth: MenuBarIconStyle.monitorStrokeWidth,
            lineCap: .round, lineJoin: .round
        )

        // Monitor outline and stand.
        let screen = Path(roundedRect: CGRect(x: 1.15, y: 1.1, width: 27.7, height: 16.1),
                          cornerRadius: 2.5)
        context.stroke(screen, with: .color(tint), style: stroke)
        var stand = Path()
        stand.move(to: CGPoint(x: 15, y: 17.25))
        stand.addLine(to: CGPoint(x: 15, y: 19.7))
        stand.move(to: CGPoint(x: 9.8, y: 20.55))
        stand.addLine(to: CGPoint(x: 20.2, y: 20.55))
        context.stroke(stand, with: .color(tint), style: StrokeStyle(
            lineWidth: MenuBarIconStyle.standStrokeWidth,
            lineCap: .round, lineJoin: .round
        ))

        // Compact telescope silhouette, angled towards the upper-right star.
        var tube = Path()
        tube.move(to: CGPoint(x: 4.0, y: 12.5))
        tube.addLine(to: CGPoint(x: 10.35, y: 9.2))
        tube.addLine(to: CGPoint(x: 11.65, y: 11.2))
        tube.addLine(to: CGPoint(x: 5.1, y: 14.5))
        tube.closeSubpath()
        context.fill(tube, with: .color(tint))
        var telescope = Path()
        telescope.move(to: CGPoint(x: 3.0, y: 14.0))
        telescope.addLine(to: CGPoint(x: 4.5, y: 13.2))
        telescope.move(to: CGPoint(x: 7.15, y: 13.35))
        telescope.addLine(to: CGPoint(x: 7.15, y: 14.25))
        telescope.move(to: CGPoint(x: 7.15, y: 14.25))
        telescope.addLine(to: CGPoint(x: 5.35, y: 16.2))
        telescope.move(to: CGPoint(x: 7.15, y: 14.25))
        telescope.addLine(to: CGPoint(x: 9.0, y: 16.2))
        context.stroke(telescope, with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round))

        // Distinctive star remains in the upper-right corner for every state.
        context.fill(sparkle(at: CGPoint(x: 24.2, y: 4.75), radius: 2.15), with: .color(tint))

        // Status is intentionally larger than the telescope.
        // Hide the static centre glyph only in the explicit symbol-effect trial.
        guard showsCenterGlyph else { return }
        switch MenuBarStatusIconPresentation.glyph(for: status) {
        case .none:
            break
        case .check:
            var check = Path()
            check.move(to: CGPoint(x: 14.0, y: 9.5))
            check.addLine(to: CGPoint(x: 16.8, y: 12.3))
            check.addLine(to: CGPoint(x: 22.1, y: 7.0))
            context.stroke(check, with: .color(tint),
                           style: StrokeStyle(lineWidth: 2.45, lineCap: .round, lineJoin: .round))
        case .exclamation:
            var mark = Path()
            mark.move(to: CGPoint(x: 18.0, y: 5.8))
            mark.addLine(to: CGPoint(x: 18.0, y: 10.65))
            context.stroke(mark, with: .color(tint),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 16.85, y: 12.0, width: 2.3, height: 2.3)),
                         with: .color(tint))
        case .spinner:
            let center = CGPoint(x: 17.6, y: 9.55)
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4 - .pi / 2
                let relative = (i - phase + 8) % 8
                let opacity = 1 - Double(relative) * 0.105
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * 4.0,
                    y: center.y + CGFloat(sin(angle)) * 4.0
                )
                let dot = Path(ellipseIn: CGRect(x: point.x - 0.85, y: point.y - 0.85,
                                                 width: 1.7, height: 1.7))
                context.fill(dot, with: .color(tint.opacity(opacity)))
            }
        case .progressArc:
            let start = Double((7 - phase + 8) % 8) * 45 - 90
            var arc = Path()
            arc.addArc(center: CGPoint(x: 17.6, y: 9.55), radius: 4.15,
                       startAngle: .degrees(start), endAngle: .degrees(start + 250),
                       clockwise: false)
            context.stroke(arc, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.85, lineCap: .round))
        }
    }
}

// Mark a deliberate Quit selected from the status menu. The macOS Command-Q
// event must not be able to disguise this action as a shortcut to close Settings.
@MainActor
enum AppQuitRequest {
    private static var menuQuitPending = false

    static func requestMenuQuit() {
        menuQuitPending = true
        NSApplication.shared.terminate(nil)
    }

    static func consumeMenuQuit() -> Bool {
        let requested = menuQuitPending
        menuQuitPending = false
        return requested
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCleanupTask: Task<Void, Never>?
    // True throughout the *single* deferred termination request, including
    // every Retry Cleanup attempt and the warning dialog. Reply to AppKit
    // exactly once, only after the user chooses the final outcome.
    private var quitRequestInProgress = false
    // Do not rely solely on applicationShouldTerminate: a second Command-Q
    // after Settings closes can arrive through the native Quit key equivalent.
    // Swallow Command-Q before NSApplication dispatches that menu action.
    private var commandQEventMonitor: Any?
#if !VISUAL_CHECK
    private var animatedStatusMenu: AnimatedStatusMenuCoordinator?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !VISUAL_CHECK
        if AnimatedStatusItemPolicy.useAnimatedHost(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            let host = AnimatedStatusMenuCoordinator(controller: ConnectionController.shared)
            animatedStatusMenu = host
            host.start()
        }
        commandQEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isCommandQ = AppQuitShortcutPolicy.isCommandQ(
                characters: event.charactersIgnoringModifiers,
                hasCommand: event.modifierFlags.contains(.command),
                hasShift: event.modifierFlags.contains(.shift),
                hasControl: event.modifierFlags.contains(.control),
                hasOption: event.modifierFlags.contains(.option)
            )
            guard isCommandQ else { return event }
            // Close Settings only if it is the foreground window. With an
            // attached sheet, the coordinator deliberately leaves it open.
            // If Settings is not active, Command-Q is a no-op.
            SettingsWindowCoordinator.closeSettingsForCommandQ()
            return nil
        }
        Task { await ConnectionController.shared.refreshStatus() }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
#if !VISUAL_CHECK
        if let commandQEventMonitor { NSEvent.removeMonitor(commandQEventMonitor) }
        animatedStatusMenu?.stop()
        animatedStatusMenu = nil
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if VISUAL_CHECK
        return .terminateNow
#else
        // Never bypass a pending explicit cleanup with a second Quit action.
        if quitRequestInProgress {
            // A second menu Quit during cleanup must not leave its explicit
            // marker behind after the first request is cancelled.
            _ = AppQuitRequest.consumeMenuQuit()
            return .terminateLater
        }
        let explicitlyRequestedByMenu = AppQuitRequest.consumeMenuQuit()
        let event = sender.currentEvent
        let isCommandQ = event?.type == .keyDown && AppQuitShortcutPolicy.isCommandQ(
            characters: event?.charactersIgnoringModifiers,
            hasCommand: event?.modifierFlags.contains(.command) ?? false,
            hasShift: event?.modifierFlags.contains(.shift) ?? false,
            hasControl: event?.modifierFlags.contains(.control) ?? false,
            hasOption: event?.modifierFlags.contains(.option) ?? false
        )
        switch AppQuitShortcutPolicy.action(
            isCommandQ: isCommandQ,
            settingsIsActive: SettingsWindowCoordinator.isSettingsActive,
            explicitMenuQuit: explicitlyRequestedByMenu
        ) {
        case .closeSettings:
            SettingsWindowCoordinator.closeSettingsForCommandQ()
            return .terminateCancel
        case .ignore:
            return .terminateCancel
        case .allowTermination:
            break
        }

        // Only status-menu Quit owns this interactive cleanup workflow.
        // Do not block a macOS logout/shutdown on an NSAlert dialog.
        guard explicitlyRequestedByMenu else { return .terminateNow }

        quitRequestInProgress = true
        startQuitCleanup(sender: sender)
        return .terminateLater
#endif
    }

    // Reuse the original pending AppKit termination request for every retry.
    // Sending NSApplication.terminate(nil) here would create a nested Quit
    // request while the first request is being resolved (Build 31.9.5 bug).
    private func startQuitCleanup(sender: NSApplication) {
        precondition(quitRequestInProgress && terminationCleanupTask == nil)
        terminationCleanupTask = Task { [weak self] in
            let resourceCleanup = await ConnectionController.shared.prepareForApplicationQuit()
            let outcome: ApplicationQuitCleanupResult
            switch resourceCleanup {
            case .complete:
                outcome = await ConnectionController.shared.removeUsedSSHKeysFromAgentForMenuQuit()
            case .incomplete:
                // Never remove agent keys while an SSH tunnel may still be alive.
                outcome = resourceCleanup
            }
            self?.completeQuitRequest(outcome, sender: sender)
        }
    }

    private func completeQuitRequest(_ outcome: ApplicationQuitCleanupResult, sender: NSApplication) {
        terminationCleanupTask = nil
        switch outcome {
        case .complete:
            quitRequestInProgress = false
            sender.reply(toApplicationShouldTerminate: true)
        case .incomplete(let reason):
            // The first .terminateLater is still pending. DO NOT reply(false)
            // before the alert and DO NOT call terminate() again for Retry.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Finish Quit Cleanup"
            alert.informativeText = reason + "\n\nAstroberry VNC is still running. You can retry cleanup, keep the app open, or explicitly quit anyway. Quit Anyway may leave an SSH tunnel, Viewer or an SSH-agent identity active."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Retry Cleanup")
            alert.addButton(withTitle: "Quit Anyway")
            NSApp.activate()
            let choice: QuitCleanupAlertChoice
            switch alert.runModal() {
            case .alertSecondButtonReturn: choice = .retryCleanup
            case .alertThirdButtonReturn: choice = .quitAnyway
            default: choice = .keepRunning
            }
            switch QuitCleanupRetryPolicy.nextStep(for: choice) {
            case .retryWhilePending:
                // Leave the same termination reply pending, even if another
                // attempt fails. The warning will be displayed again.
                startQuitCleanup(sender: sender)
            case .replyToPendingTermination(let allowQuit):
                quitRequestInProgress = false
                sender.reply(toApplicationShouldTerminate: allowQuit)
            }
        }
    }
}

#if !VISUAL_CHECK
/// The production menu is native. No NSStatusItem, NSPanel or key-event
/// monitors are created by the application for the main or child menu.
/// ConnectionController is unchanged and remains the single source of truth.
@MainActor
private struct NativeConnectionMenu: View {
    @ObservedObject var controller: ConnectionController

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
            // Failed disconnect: offer another cleanup attempt, not a new tunnel.
            return ConnectionMenuAction(
                title: "Retry Disconnect from \(selectedName)", systemImage: "stop.fill",
                operation: .disconnect, isEnabled: !controller.isBusy
            )
        }
        return NativeMenuActionPolicy.action(
            status: controller.status,
            serverName: selectedName,
            hasProfiles: !controller.profiles.isEmpty,
            canRetrySelectedConnection: controller.canRetrySelectedConnection
        )
    }

    private var statusPresentation: NativeMenuStatusPresentation {
        NativeMenuStatusPresentation.make(
            status: controller.status,
            serverName: selectedName,
            hasProfiles: !controller.profiles.isEmpty
        )
    }

    var body: some View {
        // A disabled native menu item is always rendered grey, even for a
        // successful connection. Make this a meaningful, enabled action:
        // selecting the status opens Settings for connection details.
        // The text includes a state glyph because native menus may suppress
        // the SF Symbol icon of a SwiftUI Label.
        Button(statusPresentation.menuTitle) { showSettings() }
            .help(controller.lastError ?? controller.securityAdvisory ??
                  statusPresentation.helpText)
            .accessibilityLabel(statusPresentation.accessibilityLabel)
        if let error = SettingsConnectionError.fullMessage(
            status: controller.status, lastError: controller.lastError
        ) {
            // A native menu cannot reliably wrap long text. Keep the state
            // item readable and offer one-click access to the entire message.
            Button("Copy Full Error Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
            .help("Copy the complete connection error, without truncation")
        }

        Divider()

        if controller.profiles.isEmpty {
            // The empty collection is intentional, not an SSH disconnect error.
            Button("VNC Server", systemImage: "server.rack") { }
                .disabled(true)
            Button("Connect", systemImage: "play.fill") { }
                .disabled(true)
            Divider()
            Button("Add VNC Server…", systemImage: "plus") {
                let newID = controller.addProfile()
                showSettings(editingProfileID: newID)
            }
        } else {
        Menu {
            ForEach(controller.profiles) { profile in
                // A Label's systemImage is suppressed by native macOS menus.
                // A Toggle uses the native NSMenuItem checkmark state instead.
                // These toggles are mutually exclusive: clicking the selected
                // profile again never clears the selection.
                Toggle(displayName(for: profile), isOn: Binding(
                    get: { controller.selectedProfileID == profile.id },
                    set: { shouldSelect in
                        if shouldSelect {
                            // Selection does not initiate an SSH/VNC connection.
                            controller.selectedProfileID = profile.id
                        }
                    }
                ))
            }

            Divider()

            Button("Add Server…", systemImage: "plus") {
                let newID = controller.addProfile()
                showSettings(editingProfileID: newID)
            }
            Button("Manage Servers…", systemImage: "gearshape") {
                showSettings()
            }
        } label: {
            Label("VNC Server: \(selectedName)", systemImage: "server.rack")
        }
        .disabled(!NativeMenuActionPolicy.canSelectServer(
            status: controller.status,
            isBusy: controller.isBusy,
            hasActiveSession: controller.connectedProfileID != nil
        ))

        Button {
            performConnectionAction(connectionAction.operation)
        } label: {
            Label(connectionAction.title, systemImage: connectionAction.systemImage)
        }
        .disabled(!connectionAction.isEnabled)
        }

        Divider()

        Button("Settings…", systemImage: "gearshape") { showSettings() }

        Divider()

        Button("Quit Astroberry VNC", systemImage: "power") {
            AppQuitRequest.requestMenuQuit()
        }
    }

    private func performConnectionAction(_ operation: ConnectionMenuOperation) {
        switch operation {
        case .connect, .retry:
            // This is still the user-initiated native-menu event. Request
            // activation now, before async key checks suspend the connection.
            // A later activation request alone may not receive keyboard focus
            // when a different application was frontmost at menu selection.
            NSApp.activate()
            Task { await controller.connect() }
        case .cancel, .disconnect:
            Task { await controller.disconnect() }
        case .disconnecting:
            break
        }
    }

    private func showSettings(editingProfileID: UUID? = nil) {
        // Let NSMenu finish its native close/selection handling before
        // activating a separate Settings NSWindow. Reuses the existing window.
        DispatchQueue.main.async {
            SettingsWindowCoordinator.presentOnActiveSpace(
                controller: controller, editingProfileID: editingProfileID
            )
        }
    }
}
#endif
