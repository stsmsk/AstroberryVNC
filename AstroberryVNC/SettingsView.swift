// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum ServerSettingsTab: String, CaseIterable, Identifiable {
    case connection, sshKey, vnc

    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: "Connection"
        case .sshKey: "SSH Key"
        case .vnc: "VNC Server"
        }
    }
    var icon: String {
        switch self {
        case .connection: "network"
        case .sshKey: "key"
        case .vnc: "display"
        }
    }
}

// NSViewRepresentable is deliberately scoped to the tab strip: it does not capture
// arrow keys while a TextField, SecureField, or other settings control is editing.
private struct SettingsSegmentedTabControl: NSViewRepresentable {
    @Binding var selection: String
    // A request is issued only when the user presses Right in the server sidebar.
    // Keeping it separate from selection prevents tab updates from stealing focus.
    let focusRequest: Int
    let onMoveToSidebar: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onMoveToSidebar: onMoveToSidebar)
    }

    func makeNSView(context: Context) -> KeyboardNavigableSegmentedControl {
        // A newly created tab strip inherits the *current* request generation.
        // Without this baseline, navigating General → Server reconstructs the
        // control and an old request incorrectly steals focus from the sidebar.
        context.coordinator.lastFocusRequest = focusRequest
        let tabs = ServerSettingsTab.allCases
        let control = KeyboardNavigableSegmentedControl(
            labels: tabs.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.focusRingType = .default
        control.refusesFirstResponder = false
        control.setAccessibilityLabel("Server settings tabs")
        control.selectedSegment = tabs.firstIndex { $0.rawValue == selection } ?? 0
        control.onMoveToSidebar = { [weak coordinator = context.coordinator] in
            coordinator?.onMoveToSidebar()
        }
        return control
    }

    func updateNSView(_ control: KeyboardNavigableSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let tabs = ServerSettingsTab.allCases
        let index = tabs.firstIndex { $0.rawValue == selection } ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        context.coordinator.onMoveToSidebar = onMoveToSidebar
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Let SwiftUI finish updating the tab strip before changing AppKit's
            // firstResponder. Never refocus for normal tab selection updates.
            DispatchQueue.main.async { [weak control] in
                guard let control, let window = control.window else { return }
                window.makeFirstResponder(control)
            }
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var onMoveToSidebar: () -> Void
        var lastFocusRequest = 0

        init(selection: Binding<String>, onMoveToSidebar: @escaping () -> Void) {
            self.selection = selection
            self.onMoveToSidebar = onMoveToSidebar
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let tabs = ServerSettingsTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            let newSelection = tabs[sender.selectedSegment].rawValue
            if selection.wrappedValue != newSelection { selection.wrappedValue = newSelection }
        }
    }
}

private final class KeyboardNavigableSegmentedControl: NSSegmentedControl {
    var onMoveToSidebar: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Native NSSegmentedControl does not necessarily become key-focused after
        // mouse selection. Explicitly focus this control so the next arrow key works.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Never intercept modified shortcuts. Text field arrows are unaffected
        // because this handler runs only while the tab strip is first responder.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            super.keyDown(with: event)
            return
        }
        let offset: Int
        switch event.keyCode {
        case 123: offset = -1  // left arrow
        case 124: offset = 1   // right arrow
        default:
            super.keyDown(with: event)
            return
        }
        // Left at Connection crosses the pane boundary to the selected server;
        // left/right within the three tabs continue to behave normally.
        if offset < 0 && SettingsPaneNavigation.leftFromTab(
            currentIndex: selectedSegment, tabCount: segmentCount
        ) == .sidebarServer {
            onMoveToSidebar?()
            return
        }
        let next = SettingsTabNavigation.nextIndex(
            current: selectedSegment, offset: offset, count: segmentCount
        )
        guard next != selectedSegment else { return }
        selectedSegment = next
        sendAction(action, to: target)
    }
}

private enum KeyManagementAction: String, Identifiable {
    case removeFromAgent, removeFromServer, moveLocalPairToTrash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .removeFromAgent: "Remove Key from SSH Agent?"
        case .removeFromServer: "Remove Public Key from Server?"
        case .moveLocalPairToTrash: "Move Local Key Pair to Trash?"
        }
    }
    var buttonTitle: String {
        switch self {
        case .removeFromAgent: "Remove from Agent"
        case .removeFromServer: "Remove from Server"
        case .moveLocalPairToTrash: "Move to Trash"
        }
    }
}

private enum PassphraseSheetAction: Identifiable {
    // The destination is immutable for the lifetime of the generate sheet.
    // Keeping it in a separate @State on SettingsView allowed it to be cleared
    // during the destination-sheet -> passphrase-sheet transition.
    case generate(profileID: UUID, destinationPath: String)
    case set(UUID), change(UUID), remove(UUID)
    var profileID: UUID {
        switch self {
        case .generate(let id, _): id
        case .set(let id), .change(let id), .remove(let id): id
        }
    }
    var generationDestination: String? {
        if case .generate(_, let path) = self { return path }
        return nil
    }
    var id: String {
        switch self {
        case .generate: "generate-\(profileID)"
        case .set: "set-\(profileID)"
        case .change: "change-\(profileID)"
        case .remove: "remove-\(profileID)"
        }
    }
    var title: String {
        switch self {
        case .generate: "Generate Ed25519 Key"
        case .set: "Set SSH Key Passphrase"
        case .change: "Change SSH Key Passphrase"
        case .remove: "Remove SSH Key Passphrase"
        }
    }
}

private struct GenerateKeyDestinationRequest: Identifiable {
    let profileID: UUID
    let initialFolder: String
    let initialFileName: String
    var id: UUID { profileID }
}

// The destination sheet owns the folder and filename being edited. Keeping
// them in SettingsView (@State on the presenting view) meant the sheet could
// retain a stale snapshot until a separate application activation triggered
// a redraw. The folder importer and its state now live in the same View.
private struct GenerateKeyDestinationEditor: View {
    @ObservedObject var controller: ConnectionController
    let request: GenerateKeyDestinationRequest
    let onCancel: () -> Void
    let onContinue: (_ folder: String, _ fileName: String) -> Void

    @State private var folder: String
    @State private var fileName: String
    @State private var isChoosingFolder = false
    @State private var folderPickerError: String?
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case filename
    }

    init(
        controller: ConnectionController,
        request: GenerateKeyDestinationRequest,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (String, String) -> Void
    ) {
        self.controller = controller
        self.request = request
        self.onCancel = onCancel
        self.onContinue = onContinue
        _folder = State(initialValue: request.initialFolder)
        _fileName = State(initialValue: request.initialFileName)
    }

    private var existingKeyPaths: [String] {
        controller.profiles.map { controller.keyPath(for: $0) }
    }

    private var validation: SSHNewKeyDestinationPolicy.Validation {
        SSHNewKeyDestinationPolicy.validate(
            directory: folder, fileName: fileName, existing: existingKeyPaths
        )
    }

    private var destination: String {
        (folder as NSString).appendingPathComponent(fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate New SSH Key Pair").font(.headline)
            Text("Choose a folder and a new filename. Existing private or public keys are never replaced.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Folder").font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Text(folder.isEmpty ? "No folder selected" : folder)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(folder.isEmpty ? Color.orange : Color.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(folder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose Folder…") { isChoosingFolder = true }
            }
            Text("New Key Filename").font(.subheadline.weight(.medium))
            TextField("id_ed25519_my-server", text: $fileName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedControl, equals: .filename)
                .accessibilityLabel("New SSH key filename")
            if validation == .available {
                Label("Available — no existing key will be replaced", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label(validation.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if validation == .destinationOccupied {
                    Button("Suggest Another Name") {
                        fileName = SSHNewKeyDestinationPolicy.availableName(
                            directory: folder,
                            desiredName: fileName,
                            existing: existingKeyPaths
                        )
                    }
                    .accessibilityLabel("Suggest a new unused SSH key filename")
                }
            }
            if let folderPickerError {
                Label("Folder selection failed: \(folderPickerError)", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if validation == .available {
                Text("Will create: \(destination) and \(destination).pub")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue…") {
                    // Re-check at the action boundary, after any external file
                    // system changes, rather than trusting a stale UI status.
                    guard SSHNewKeyDestinationPolicy.validate(
                        directory: folder, fileName: fileName, existing: existingKeyPaths
                    ) == .available,
                    controller.profiles.contains(where: { $0.id == request.profileID }),
                    !controller.isBusy, !controller.isGeneratingKey else { return }
                    onContinue(folder, fileName)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validation != .available || controller.isBusy || controller.isGeneratingKey)
            }
        }
        .padding(20)
        .frame(width: 520)
        // SwiftUI owns the folder-picker presentation. In contrast to an
        // NSOpenPanel manually started from a different View's sheet, this
        // completion changes @State *owned by the visible sheet itself*.
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.directory],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // This application is not sandboxed: the selected directory
                // path can be used directly by the existing key generator.
                folder = url.standardizedFileURL.path
                folderPickerError = nil
            case .failure(let error):
                folderPickerError = error.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: folder.isEmpty ? NSHomeDirectory() : folder))
        .fileDialogConfirmationLabel("Use Folder")
        .onAppear {
            DispatchQueue.main.async { focusedControl = .filename }
        }
    }
}

private struct RenameKeyRequest: Identifiable {
    let profileID: UUID
    var id: UUID { profileID }
}

// Both sheets use explicit, independent keyboard focus targets. The first
// editable field is focused on presentation, not the destructive/submit button.
private enum SSHKeyDialogFocus: Hashable {
    case currentPassphrase, newPassphrase, confirmPassphrase
}

private struct SettingsState {
    enum Level { case ready, notConfigured, warning, error }
    let level: Level
    let text: String

    var icon: String {
        switch level {
        case .ready: "checkmark.circle.fill"
        case .notConfigured: "circle.dotted"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch level {
        case .ready: .green
        case .notConfigured: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: ConnectionController
    // When entered via Add VNC Server in the menu, open the new profile directly.
    let initialEditingProfileID: UUID?
    // Sidebar selection is a per-presentation UI state, NOT the active VNC server.
    // Reopening Settings starts at General without changing selectedProfileID.
    @State private var sidebarSelectionRaw = SettingsSidebarNavigation.generalTag
    @AppStorage("SettingsServerTab") private var selectedTabRaw = ServerSettingsTab.connection.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var keyPassphrase = ""
    @State private var keyPassphraseConfirmation = ""
    @State private var oldKeyPassphrase = ""
    @State private var passphraseSheet: PassphraseSheetAction?
    @State private var passphraseOperationBusy = false
    @State private var passphraseSheetError: String?
    @State private var generateKeyDestinationRequest: GenerateKeyDestinationRequest?
    @State private var pendingGenerateNextStep: (profileID: UUID, path: String)?
    @State private var renameKeyRequest: RenameKeyRequest?
    @State private var newKeyName = ""
    // This is keyed by the effective private-key PATH: two profiles that share
    // a key cannot disagree about its passphrase protection state.
    @State private var keyProtectionByPath: [String: SSHPrivateKeyProtectionState] = [:]
    @State private var keyAgentStateByPath: [String: SSHAgentKeyState] = [:]
    // Newer checks supersede older checks for the same key. For example, a
    // reconnect can load the agent while an earlier status probe is in flight.
    @State private var keyStatusRefreshRequests = SSHKeyStatusRefreshRequests()
    @State private var sshLoginPassword = ""
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteProfileID: UUID?
    @State private var pendingKeyAction: KeyManagementAction?
    @State private var pendingKeyActionProfileID: UUID?
    @FocusState private var isSSHLoginPasswordFocused: Bool
    @FocusState private var isServerSidebarFocused: Bool
    @FocusState private var keyDialogFocus: SSHKeyDialogFocus?
    @State private var tabFocusRequest = 0

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 190)
                // Preserve the native sidebar/list appearance in both color schemes.
                .background(Color(nsColor: .windowBackgroundColor))
            detailPane
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                // textBackgroundColor is white in Light Mode and adapts in Dark Mode.
                // Do not hard-code .white: that would produce a bright panel in Dark Mode.
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(
            minWidth: 0,
            idealWidth: SettingsWindowLayout.preferredContentSize.width,
            minHeight: 0,
            idealHeight: SettingsWindowLayout.preferredContentSize.height
        )
        .background(SettingsWindowAccessor())
        .navigationTitle("Astroberry VNC Settings")
        .onAppear {
            NSApp.activate()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            resetNavigationForPresentation(editingProfileID: initialEditingProfileID)
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowCoordinator.willPresentNotification)) { note in
            // An existing NSWindow may be shown again without SwiftUI onAppear.
            let id = (note.userInfo?["editingProfileID"] as? String).flatMap(UUID.init(uuidString:))
            resetNavigationForPresentation(editingProfileID: id)
        }
        .onChange(of: sidebarSelectionRaw) { _, _ in
            // Sidebar selection is editingProfileID only, never selectedProfileID.
            clearTransientKeyInput()
        }
        .sheet(item: $passphraseSheet, onDismiss: clearTransientKeyInput) { action in
            passphraseEditor(action)
        }
        .sheet(item: $generateKeyDestinationRequest, onDismiss: completeGenerateKeyDestinationStep) { request in
            GenerateKeyDestinationEditor(controller: controller, request: request) {
                generateKeyDestinationRequest = nil
            } onContinue: { folder, fileName in
                guard controller.profiles.contains(where: { $0.id == request.profileID }),
                      !controller.isBusy, !controller.isGeneratingKey,
                      SSHNewKeyDestinationPolicy.validate(
                          directory: folder,
                          fileName: fileName,
                          existing: controller.profiles.map { controller.keyPath(for: $0) }
                      ) == .available else { return }
                let destination = (folder as NSString).appendingPathComponent(fileName)
                pendingGenerateNextStep = (profileID: request.profileID, path: destination)
                generateKeyDestinationRequest = nil
            }
        }
        .sheet(item: $renameKeyRequest) { request in
            renameKeyEditor(profileID: request.profileID)
        }
        .confirmationDialog("Remove this VNC server setting?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                if let id = pendingDeleteProfileID { removeServer(profileID: id) }
                pendingDeleteProfileID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteProfileID = nil }
        } message: {
            Text("This removes only the saved server setting. SSH keys and authorized_keys are not deleted.")
        }
        .alert(pendingKeyAction?.title ?? "Manage SSH Key", isPresented: keyActionAlertBinding) {
            if let action = pendingKeyAction {
                Button(action.buttonTitle, role: .destructive) { performKeyAction(action) }
            }
            Button("Cancel", role: .cancel) {
                pendingKeyAction = nil
                pendingKeyActionProfileID = nil
            }
        } message: {
            Text(keyActionMessage)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelectionBinding) {
                Section("Application") {
                    Label("General", systemImage: "gearshape")
                        .tag("general")
                        .accessibilityLabel("General application settings")
                }
                Section("Servers") {
                    if controller.profiles.isEmpty {
                        Label("No Servers", systemImage: "server.rack")
                            .foregroundStyle(.secondary)
                            .tag(SettingsSidebarNavigation.noServersTag)
                            .accessibilityLabel("No VNC servers configured")
                    }
                    ForEach(controller.profiles) { profile in
                        Label(profile.displayName.isEmpty ? profile.server : profile.displayName, systemImage: "server.rack")
                            .tag(serverTag(profile.id))
                            .accessibilityLabel("Server \(profile.displayName.isEmpty ? profile.server : profile.displayName)")
                    }
                }
            }
            // Use the system sidebar's selection/highlight (accent color in
            // active windows, inactive selection styling otherwise).
            .listStyle(.sidebar)
            // Make the entire server list match the grey sidebar rather than
            // introducing a separate white list surface. Keep native selection.
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(Color(nsColor: .controlAccentColor))
            .focused($isServerSidebarFocused)
            .onKeyPress(.downArrow) {
                moveSidebarSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSidebarSelection(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                // Only a server row is allowed to hand focus to Connection.
                // General and the text fields in the detail pane are unaffected.
                guard SettingsPaneNavigation.rightFromSidebar(
                        hasSelectedServer: selectedSidebarProfile != nil
                      ) == .connectionTab else { return .ignored }
                selectedTabRaw = ServerSettingsTab.connection.rawValue
                tabFocusRequest &+= 1
                return .handled
            }
            Divider()
            HStack(spacing: 8) {
                sidebarActionButton("plus", label: "Add VNC server", enabled: true) {
                    addServer()
                }
                sidebarActionButton(
                    "minus", label: "Remove selected VNC server",
                    enabled: canDeleteSelectedServer
                ) {
                    // Capture which row was selected when the action was
                    // invoked, not whichever row might be selected later.
                    pendingDeleteProfileID = selectedSidebarProfile?.id
                    showDeleteConfirmation = pendingDeleteProfileID != nil
                }
                .help(controller.profiles.isEmpty
                    ? "No servers to remove"
                    : canDeleteSelectedServer
                        ? "Remove selected server setting"
                        : "Select a server that is not currently connected")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarActionButton(
        _ systemName: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                // The whole 32×32pt rectangle is hit-testable, not just the glyph.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder private var detailPane: some View {
        if controller.profiles.isEmpty && sidebarSelectionRaw != SettingsSidebarNavigation.generalTag {
            emptyServersPane
        } else if sidebarSelectionRaw == SettingsSidebarNavigation.generalTag {
            generalPane
        } else if let profile = selectedSidebarProfile {
            serverPane(profile)
        } else {
            ContentUnavailableView("Select a Setting", systemImage: "sidebar.left")
        }
    }

    private var emptyServersPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No VNC Servers Configured")
                .font(.title2.bold())
            Text("Click + to add your first VNC server.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.bold())
                connectionErrorDetails
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Launch at login")
                        Toggle("Launch Astroberry VNC when I log in", isOn: Binding(
                            get: { launchAtLogin }, set: { updateLoginItem(enabled: $0) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Launch Astroberry VNC when I log in")
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("SSH key folder")
                        TextField("~/.ssh", text: $controller.keyDirectory)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 355)
                            .accessibilityLabel("Default SSH key folder")
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("TigerVNC Viewer")
                        TextField("/Applications/TigerVNC.app", text: $controller.viewerPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 355)
                            .accessibilityLabel("TigerVNC Viewer application path")
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Default timeout")
                        HStack {
                            TextField("10", value: $controller.connectTimeout, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .accessibilityLabel("Default connection timeout in seconds")
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Application") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Remove used SSH keys from ssh-agent when quitting",
                            isOn: $controller.removeUsedKeysFromAgentOnQuit
                        )
                        .accessibilityLabel("Remove SSH keys used by Astroberry VNC from ssh-agent on menu Quit")
                        Text("Off by default. Only keys used for SSH connections during this launch are removed when you select Quit Astroberry VNC. Disconnect and Command-Q do not remove keys. Key files remain on disk. Keys shared with other apps may also become unavailable to them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("SSH Agent") }
                Text("These settings apply to every server. Existing per-server Viewer and timeout values are retained for backward compatibility but are no longer used.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let loginItemError {
                    Label(loginItemError, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func serverPane(_ profile: VNCServerProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(profile.displayName.isEmpty ? profile.server : profile.displayName).font(.title2.bold())
            if controller.connectionFieldsLocked(profileID: profile.id) {
                Label("Connected session: only Display Name can be changed until disconnected.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else if controller.connectedProfileID != nil {
                Label("Another server is in use. This server's settings can be edited.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            statusSummary(profile)
            // An AppKit-backed segmented control explicitly becomes first responder on click.
            // SwiftUI Picker.focused + onKeyPress did not reliably receive arrow keys in Release.
            SettingsSegmentedTabControl(
                selection: selectedTabBinding,
                focusRequest: tabFocusRequest,
                onMoveToSidebar: {
                    guard selectedSidebarProfile != nil else { return }
                    // The List retains its selected row. Focus moves back to
                    // that row rather than changing the selected server.
                    isServerSidebarFocused = true
                }
            )
                .frame(height: 26)
                .accessibilityLabel("Server settings tabs")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if profile.id == controller.selectedProfileID || controller.connectedProfileID == profile.id {
                        connectionErrorDetails
                    }
                    selectedTabContent(profile)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(profile.id.uuidString)|\(profile.server)|\(profile.sshPort)") {
            await controller.refreshHostTrust(profileID: profile.id)
        }
    }

    @ViewBuilder private var connectionErrorDetails: some View {
        if let error = SettingsConnectionError.fullMessage(
            status: controller.status, lastError: controller.lastError
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Connection Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("Copy Error") { copyToPasteboard(error) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy full connection error message")
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Connection Error: \(error)")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.45)))
        }
    }

    private func statusSummary(_ profile: VNCServerProfile) -> some View {
        HStack(spacing: 12) {
            ForEach(ServerSettingsTab.allCases) { tab in
                let state = state(for: tab, profile: profile)
                Button { selectedTabRaw = tab.rawValue } label: {
                    Label("\(tab.title): \(state.text)", systemImage: state.icon)
                        .font(.caption)
                        .foregroundStyle(state.color)
                }
                .buttonStyle(.plain)
                .help("Open the \(tab.title) tab")
                .accessibilityLabel("\(tab.title), \(state.text)")
            }
            Spacer()
        }
    }

    @ViewBuilder private func selectedTabContent(_ profile: VNCServerProfile) -> some View {
        switch selectedTab {
        case .connection: connectionTab(profile)
        case .sshKey: sshKeyTab(profile)
        case .vnc: vncTab(profile)
        }
    }

    private func connectionTab(_ profile: VNCServerProfile) -> some View {
        let feedback = controller.settingsFeedback(for: profile.id)
        let fieldsLocked = controller.connectionFieldsLocked(profileID: profile.id)
        return VStack(alignment: .leading, spacing: 14) {
            statusBanner(state(for: .connection, profile: profile))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                fieldRow("Display Name") {
                    TextField("Astroberry", text: profileBinding(profile, \.displayName)).accessibilityLabel("Display name")
                }
                fieldRow("SSH Host") {
                    TextField("astroberry.local", text: Binding(
                        get: { controller.profiles.first(where: { $0.id == profile.id })?.server ?? "" },
                        set: { controller.updateServer(profileID: profile.id, value: $0) }
                    )).disabled(fieldsLocked).accessibilityLabel("SSH host name or IP address")
                }
                fieldRow("SSH User") {
                    TextField("astroberry", text: Binding(
                        get: { controller.profiles.first(where: { $0.id == profile.id })?.username ?? "" },
                        set: { controller.updateUsername(profileID: profile.id, value: $0) }
                    )).disabled(fieldsLocked).accessibilityLabel("SSH user")
                }
                fieldRow("SSH Port") {
                    TextField("22", value: profileBinding(profile, \.sshPort), format: .number)
                        .disabled(fieldsLocked)
                        .frame(width: 100).accessibilityLabel("SSH port")
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Destination").foregroundStyle(.secondary).frame(width: 132, alignment: .leading)
                    Text("\(profile.username)@\(profile.server)").textSelection(.enabled)
                        .accessibilityLabel("SSH destination \(profile.username)@\(profile.server)")
                }
            }
            .textFieldStyle(.roundedBorder)
            Divider()
            HStack {
                Button("Check SSH Host Key") { Task { await controller.inspectSelectedHostKey(profileID: profile.id) } }
                    .accessibilityHint("Scans the selected server and displays its host key fingerprint")
                Button("Approve Host Key") { controller.approvePendingHostKey(profileID: profile.id) }
                    .disabled(!feedback.canApproveHostKey || controller.hostTrustWriteLocked(profileID: profile.id))
                    .help(feedback.canApproveHostKey ? "Trust the displayed fingerprint" : "Check the host key first")
            }
            settingsOperationFeedback(
                message: feedback.hostKeyMessage,
                error: feedback.hostKeyError,
                errorTitle: "SSH Host Key Error"
            )
            if hostVerificationState(profile: profile, feedback: feedback) == .notVerified {
                Label("SSH host not verified. Choose Check SSH Host Key to retrieve its fingerprint.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Verify a new fingerprint through a separate trusted channel before approving it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sshKeyTab(_ profile: VNCServerProfile) -> some View {
        let feedback = controller.settingsFeedback(for: profile.id)
        let privatePath = controller.keyPath(for: profile)
        let publicPath = privatePath + ".pub"
        let privateExists = FileManager.default.fileExists(atPath: NSString(string: privatePath).expandingTildeInPath)
        let publicExists = FileManager.default.fileExists(atPath: NSString(string: publicPath).expandingTildeInPath)
        let keyLocked = controller.keyResourceLocked(profileID: profile.id)
        let remoteLocked = controller.remoteKeyResourceLocked(profileID: profile.id)
        let protection = keyProtectionByPath[privatePath]
        let agentState = keyAgentStateByPath[privatePath]
        return VStack(alignment: .leading, spacing: 12) {
            statusBanner(state(for: .sshKey, profile: profile))
            Label(
                "Configured private key (independent of SSH Host)",
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                pathRow("Effective private key", path: privatePath)
                pathRow("Public key", path: publicPath)
                if let fingerprint = feedback.keyFingerprint { wrappedValueRow("SHA-256 fingerprint", value: fingerprint) }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Generate New Key…") { chooseNewKeyDestination(profileID: profile.id) }
                    .disabled(controller.isGeneratingKey || controller.isBusy)
                    .help("Generate a new key pair without replacing the active key. Select it after disconnecting if this server is in use.")
                Button("Select Existing Key…") { selectExistingPrivateKey(profileID: profile.id) }
                    .disabled(controller.connectionFieldsLocked(profileID: profile.id) || controller.isGeneratingKey)
                    .help("Change only this server's key reference; no files will be modified")
                Button("Rename Key…") {
                    newKeyName = URL(fileURLWithPath: NSString(string: privatePath).expandingTildeInPath).lastPathComponent
                    renameKeyRequest = RenameKeyRequest(profileID: profile.id)
                }
                .disabled(keyLocked || controller.isBusy || controller.isGeneratingKey || !privateExists || !publicExists)
                .help("Rename the key and its .pub file; update other profiles sharing it")
                Menu("More…") {
                    Button("Copy Public Key") { controller.copyPublicKey(profileID: profile.id) }
                        .disabled(!publicExists || controller.isGeneratingKey)
                    Divider()
                    Button("Inspect Key") { Task { await controller.inspectSelectedKey(profileID: profile.id) } }
                    Button("Rebuild .pub") { Task { await controller.regeneratePublicKey(profileID: profile.id) } }
                        .disabled(keyLocked)
                    Divider()
                    Button("Copy Private Key Path") { copyToPasteboard(privatePath) }
                    Button("Copy Public Key Path") { copyToPasteboard(publicPath) }
                    Divider()
                    Button("Remove from SSH Agent…", role: .destructive) {
                        pendingKeyActionProfileID = profile.id
                        pendingKeyAction = .removeFromAgent
                    }
                    .disabled(!privateExists || keyLocked)
                    Button("Remove Public Key from Server…", role: .destructive) {
                        pendingKeyActionProfileID = profile.id
                        pendingKeyAction = .removeFromServer
                    }
                    .disabled(!privateExists || !publicExists || remoteLocked)
                    Button("Move Local Key Pair to Trash…", role: .destructive) {
                        pendingKeyActionProfileID = profile.id
                        pendingKeyAction = .moveLocalPairToTrash
                    }
                    .disabled((!privateExists && !publicExists) || keyLocked)
                }
                .accessibilityLabel("More SSH key management actions")
            }
            HStack {
                if protection == .unprotected {
                    Button("Set Passphrase…") { preparePassphraseSheet(.set(profile.id)) }
                        .disabled(!privateExists || keyLocked || controller.isGeneratingKey)
                } else {
                    Button("Change Passphrase…") { preparePassphraseSheet(.change(profile.id)) }
                        .disabled(protection != .protected || keyLocked || controller.isGeneratingKey)
                }
                Button("Remove Passphrase…") { preparePassphraseSheet(.remove(profile.id)) }
                    .disabled(protection != .protected || keyLocked || controller.isGeneratingKey)
            }
            // Read-only status: protection of the file on disk and availability
            // of its public identity in ssh-agent are intentionally separate.
            // No manual Refresh button is needed; the tab refreshes on entry,
            // application activation, connection changes and key operations.
            VStack(alignment: .leading, spacing: 7) {
                Text("Key Status")
                    .font(.caption.weight(.semibold))
                if !privateExists {
                    Label("Private key not found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    switch protection {
                    case .unprotected:
                        Label("No passphrase", systemImage: "lock.open")
                            .foregroundStyle(.secondary)
                    case .protected:
                        Label("Passphrase protected", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    case nil:
                        Label("Checking key protection…", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    switch agentState {
                    case .loaded:
                        Label("Loaded in SSH Agent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notLoaded:
                        Label(protection == .unprotected
                              ? "Agent: not loaded (not required)"
                              : "Not loaded in SSH Agent", systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                    case .unavailable(let reason):
                        Label("SSH Agent unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(reason)
                    case nil:
                        Label("Checking SSH Agent…", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Updated automatically when opening this tab, returning to the app, or changing the key.")
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            Button("Test Public-Key Authentication") { Task { await controller.testSelectedKeyAuthentication(profileID: profile.id) } }
                .disabled(!privateExists)
                .help(privateExists ? "Test using only the selected key" : "Create or select a private key first")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                fieldRow("One-time SSH password") {
                    SecureField("SSH login password", text: $sshLoginPassword)
                        .disabled(remoteLocked)
                        .focused($isSSHLoginPasswordFocused)
                        .accessibilityLabel("One-time SSH login password")
                }
            }
            .textFieldStyle(.roundedBorder)
            Button("Register Public Key on Server") {
                let password = sshLoginPassword
                sshLoginPassword = ""
                Task { await controller.registerSelectedPublicKey(profileID: profile.id, password: password) }
            }
            .disabled(remoteLocked || sshLoginPassword.isEmpty || !privateExists || !publicExists)
            .help(registrationHelp(privateExists: privateExists, publicExists: publicExists))
            settingsOperationFeedback(
                message: feedback.keyMessage,
                error: feedback.keyError,
                errorTitle: "SSH Key Error"
            )
            Text("SSH login password is used once and never saved. Encrypted keys are unlocked on demand through ssh-agent; passphrases are not stored by Astroberry VNC.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: privatePath) {
            await refreshKeyProtection(profileID: profile.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Handles changes performed by Terminal (ssh-add, ssh-keygen -p)
            // while Settings is open, without a polling timer.
            Task { await refreshKeyProtection(profileID: profile.id) }
        }
        .onChange(of: controller.status) { _, _ in
            // Connect may unlock a passphrase-protected key into ssh-agent.
            Task { await refreshKeyProtection(profileID: profile.id) }
        }
        .onChange(of: controller.isGeneratingKey) { _, isGenerating in
            if !isGenerating { Task { await refreshKeyProtection(profileID: profile.id) } }
        }
        .onChange(of: feedback.keyMessage) { _, _ in
            Task { await refreshKeyProtection(profileID: profile.id) }
        }
        .onChange(of: feedback.keyError) { _, _ in
            Task { await refreshKeyProtection(profileID: profile.id) }
        }
    }

    private func refreshKeyProtection(profileID: UUID) async {
        guard let profile = controller.profiles.first(where: { $0.id == profileID }) else { return }
        let path = controller.keyPath(for: profile)
        let requestToken = keyStatusRefreshRequests.begin(for: path)
        let runner = SystemCommandRunner()
        async let protection = runner.privateKeyProtectionState(path: path)
        async let agent = runner.agentKeyState(path: path)
        let (state, agentState) = await (protection, agent)
        // Ignore stale asynchronous results, even if the key path did not change.
        guard keyStatusRefreshRequests.isCurrent(requestToken, for: path),
              let current = controller.profiles.first(where: { $0.id == profileID }),
              controller.keyPath(for: current) == path else { return }
        keyProtectionByPath[path] = state
        keyAgentStateByPath[path] = agentState
    }

    private func preparePassphraseSheet(_ action: PassphraseSheetAction) {
        guard !controller.isGeneratingKey,
              let profile = controller.profiles.first(where: { $0.id == action.profileID }) else { return }
        let protection = keyProtectionByPath[controller.keyPath(for: profile)]
        switch action {
        case .generate:
            // Creating an independent key is always safe while idle. If this
            // profile is active, generating does NOT select the new key.
            break
        case .set:
            guard !controller.keyResourceLocked(profileID: action.profileID), protection == .unprotected else { return }
        case .change, .remove:
            guard !controller.keyResourceLocked(profileID: action.profileID), protection == .protected else { return }
        }
        clearTransientKeyInput()
        passphraseSheetError = nil
        passphraseSheet = action
    }

    private func passphraseEditor(_ action: PassphraseSheetAction) -> some View {
        let isGenerate: Bool = {
            if case .generate = action { return true }
            return false
        }()
        let isSet: Bool = {
            if case .set = action { return true }
            return false
        }()
        let isRemove: Bool = {
            if case .remove = action { return true }
            return false
        }()
        let isChange = !isGenerate && !isSet && !isRemove
        let match = keyPassphrase == keyPassphraseConfirmation
        let newPassphraseValid = !keyPassphrase.contains("\n") && !keyPassphrase.contains("\r")
        let currentPassphraseValid = !oldKeyPassphrase.isEmpty &&
            !oldKeyPassphrase.contains("\n") && !oldKeyPassphrase.contains("\r")
        let canSubmit = !passphraseOperationBusy && !controller.isGeneratingKey &&
            (isGenerate ? SSHKeyGenerationSubmission.canSubmit(
                destinationPath: action.generationDestination,
                passphrase: keyPassphrase,
                confirmation: keyPassphraseConfirmation
            ) :
             isSet ? (match && newPassphraseValid && !keyPassphrase.isEmpty) :
             isRemove ? currentPassphraseValid :
             (isChange && currentPassphraseValid && match && newPassphraseValid && !keyPassphrase.isEmpty))
        return VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.headline)
            Text(isGenerate
                 ? "A passphrase is optional. Leave both fields empty to create an unencrypted key."
                 : isSet
                    ? "Set a passphrase on this unencrypted private key. No current passphrase is required."
                    : isRemove
                        ? "Enter the current passphrase to remove encryption. The public key will stay unchanged."
                        : "Enter the current passphrase and a new passphrase. The public key will stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isChange || isRemove {
                SecureField("Current passphrase", text: $oldKeyPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyDialogFocus, equals: .currentPassphrase)
                    .accessibilityLabel("Current SSH key passphrase")
            }
            if !isRemove {
                SecureField(isGenerate ? "New passphrase (optional)" : "New passphrase", text: $keyPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyDialogFocus, equals: .newPassphrase)
                    .accessibilityLabel("New SSH key passphrase")
                SecureField("Confirm new passphrase", text: $keyPassphraseConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyDialogFocus, equals: .confirmPassphrase)
                    .accessibilityLabel("Confirm SSH key passphrase")
                if !match {
                    Text("The passphrases do not match.").font(.caption).foregroundStyle(.orange)
                }
            }
            if let error = passphraseSheetError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { passphraseSheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(passphraseOperationBusy)
                Button(isGenerate ? "Generate" : isSet ? "Set Passphrase" : isRemove ? "Remove Passphrase" : "Change Passphrase") {
                    let id = action.profileID
                    let old = (isGenerate || isSet) ? "" : oldKeyPassphrase
                    let new = isRemove ? "" : keyPassphrase
                    passphraseOperationBusy = true
                    Task {
                        if isGenerate, let destination = action.generationDestination {
                            // Validate again at the action boundary: another process
                            // may have created either half of the key pair since
                            // the destination sheet was dismissed. Never overwrite.
                            let directory = URL(fileURLWithPath: destination).deletingLastPathComponent().path
                            let fileName = URL(fileURLWithPath: destination).lastPathComponent
                            let availability = SSHNewKeyDestinationPolicy.validate(
                                directory: directory, fileName: fileName,
                                existing: controller.profiles.map { controller.keyPath(for: $0) }
                            )
                            if availability == .available {
                                await controller.generateSSHKey(profileID: id, destinationPath: destination, passphrase: new)
                            } else {
                                passphraseOperationBusy = false
                                passphraseSheetError = "The selected key destination is no longer available. Cancel and choose another filename. No files were replaced."
                                return
                            }
                        } else if !isGenerate {
                            await controller.changeSelectedKeyPassphrase(profileID: id, current: old, replacement: new)
                        }
                        // Only refresh after the key mutation has completed.
                        await refreshKeyProtection(profileID: id)
                        passphraseOperationBusy = false
                        if let error = controller.settingsFeedback(for: id).keyError {
                            passphraseSheetError = error
                        } else {
                            passphraseSheet = nil
                            clearTransientKeyInput()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            // The sheet must be attached before SwiftUI/AppKit can focus its field.
            DispatchQueue.main.async {
                guard passphraseSheet?.id == action.id else { return }
                keyDialogFocus = (isChange || isRemove) ? .currentPassphrase : .newPassphrase
            }
        }
        .onDisappear { keyDialogFocus = nil }
        .interactiveDismissDisabled(passphraseOperationBusy)
    }

    private func vncTab(_ profile: VNCServerProfile) -> some View {
        let advisory = controller.securityAdvisory(for: profile.id)
        let fieldsLocked = controller.connectionFieldsLocked(profileID: profile.id)
        return VStack(alignment: .leading, spacing: 14) {
            statusBanner(state(for: .vnc, profile: profile))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                fieldRow("VNC Host") {
                    TextField("127.0.0.1", text: profileBinding(profile, \.vncHost)).disabled(fieldsLocked).accessibilityLabel("VNC host as seen from SSH server")
                }
                fieldRow("Port") {
                    TextField("5970", value: profileBinding(profile, \.vncPort), format: .number)
                        .disabled(fieldsLocked)
                        .frame(width: 100).accessibilityLabel("VNC TCP port")
                }
                fieldRow("Display") {
                    TextField("70", value: profileBinding(profile, \.displayNumber), format: .number)
                        .disabled(fieldsLocked)
                        .frame(width: 100).accessibilityLabel("VNC display number")
                }
            }
            .textFieldStyle(.roundedBorder)
            Divider()
            Label("VNC must listen only on the server loopback interface and use no VNC password.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(advisory == nil ? Color.secondary : Color.orange)
            if let advisory {
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func settingsOperationFeedback(
        message: String?, error: String?, errorTitle: String
    ) -> some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error, !error.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(errorTitle, systemImage: "xmark.octagon.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("Copy Error") { copyToPasteboard(error) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy full \(errorTitle.lowercased())")
                }
                Text(error)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusBanner(_ state: SettingsState) -> some View {
        Label(state.text, systemImage: state.icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(state.color)
            .accessibilityLabel("Status: \(state.text)")
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).frame(width: 132, alignment: .leading)
            content().frame(maxWidth: 355, alignment: .leading)
        }
    }

    private func pathRow(_ label: String, path: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 132, alignment: .leading)
            HStack(spacing: 6) {
                Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                Button { copyToPasteboard(path) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy full value").accessibilityLabel("Copy \(label)")
            }
            .frame(maxWidth: 355, alignment: .leading)
        }
    }

    private func wrappedValueRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 132, alignment: .leading)
            HStack(alignment: .top, spacing: 6) {
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { copyToPasteboard(value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy full value").accessibilityLabel("Copy \(label)")
            }
            .frame(maxWidth: 355, alignment: .leading)
        }
    }

    private func hostVerificationState(
        profile: VNCServerProfile, feedback: ProfileSettingsFeedback
    ) -> SSHHostVerificationPresentation {
        SSHHostVerificationPresentation.evaluate(
            configured: !profile.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (1...65535).contains(profile.sshPort),
            hasError: feedback.hostKeyError != nil,
            hasPendingApproval: feedback.canApproveHostKey,
            hostIsKnown: feedback.hostIsKnown
        )
    }

    private func state(for tab: ServerSettingsTab, profile: VNCServerProfile) -> SettingsState {
        let feedback = controller.settingsFeedback(for: profile.id)
        switch tab {
        case .connection:
            let verification = hostVerificationState(profile: profile, feedback: feedback)
            let level: SettingsState.Level
            switch verification {
            case .verified: level = .ready
            case .notVerified, .approvalRequired: level = .warning
            case .checking, .notConfigured: level = .notConfigured
            case .error: level = .error
            }
            return SettingsState(level: level, text: verification.title)
        case .sshKey:
            if feedback.keyError != nil { return SettingsState(level: .error, text: "Error") }
            let keyPath = NSString(string: controller.keyPath(for: profile)).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: keyPath), FileManager.default.fileExists(atPath: keyPath + ".pub") else {
                return SettingsState(level: .notConfigured, text: "Key not configured")
            }
            if feedback.keyMessage?.localizedCaseInsensitiveContains("succeeded") == true {
                return SettingsState(level: .ready, text: "Authentication ready")
            }
            return SettingsState(level: .ready, text: "Key available")
        case .vnc:
            if controller.securityAdvisory(for: profile.id) != nil { return SettingsState(level: .warning, text: "Warning") }
            let loopback = ["127.0.0.1", "localhost", "::1"].contains(profile.vncHost.lowercased())
            guard loopback, (1...65535).contains(profile.vncPort), (0...99).contains(profile.displayNumber) else {
                return SettingsState(level: .notConfigured, text: "Not configured")
            }
            return SettingsState(level: .ready, text: "Ready")
        }
    }

    private var selectedTab: ServerSettingsTab { ServerSettingsTab(rawValue: selectedTabRaw) ?? .connection }
    private var selectedTabBinding: Binding<String> {
        Binding(get: { selectedTab.rawValue }, set: { selectedTabRaw = $0 })
    }
    private var sidebarSelectionBinding: Binding<String?> {
        Binding(get: { sidebarSelectionRaw }, set: { if let value = $0 { sidebarSelectionRaw = value } })
    }
    // editingProfileID is local to Settings. selectedProfileID is exclusively
    // the main menu's next connection target, and connectedProfileID is the
    // SSH/TigerVNC session snapshot. These must not follow each other.
    private var editingProfileID: UUID? { serverID(from: sidebarSelectionRaw) }
    private var selectedSidebarProfile: VNCServerProfile? {
        guard let id = editingProfileID else { return nil }
        return controller.profiles.first { $0.id == id }
    }
    private var canDeleteSelectedServer: Bool {
        selectedSidebarProfile.map { controller.canRemoveProfile(profileID: $0.id) } ?? false
    }
    private var keyActionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingKeyAction != nil },
            set: { if !$0 { pendingKeyAction = nil; pendingKeyActionProfileID = nil } }
        )
    }
    private var keyActionMessage: String {
        guard let action = pendingKeyAction, let id = pendingKeyActionProfileID,
              let profile = controller.profiles.first(where: { $0.id == id }) else { return "" }
        let path = controller.keyPath(for: profile)
        switch action {
        case .removeFromAgent:
            return "This unloads only this identity from the current SSH agent. The local files at \(path) and \(path).pub are not changed."
        case .removeFromServer:
            return "This removes only the matching public key from \(profile.username)@\(profile.server). Other authorized keys and the local key files are preserved."
        case .moveLocalPairToTrash:
            return "This moves \(path) and \(path).pub to Trash. The server's authorized_keys file is not changed."
        }
    }

    private func profileBinding<T>(
        _ profile: VNCServerProfile, _ keyPath: WritableKeyPath<VNCServerProfile, T>
    ) -> Binding<T> {
        Binding(
            // SwiftUI can evaluate a disappearing server row for one more
            // transaction after deletion. Never force-unwrap a removed profile.
            get: { controller.profiles.first(where: { $0.id == profile.id })?[keyPath: keyPath]
                ?? profile[keyPath: keyPath] },
            set: { value in
                controller.updateProfile(profileID: profile.id) { $0[keyPath: keyPath] = value }
            }
        )
    }
    private func serverTag(_ id: UUID) -> String { "server:\(id.uuidString)" }
    private func serverID(from tag: String) -> UUID? {
        guard tag.hasPrefix("server:") else { return nil }
        return UUID(uuidString: String(tag.dropFirst("server:".count)))
    }
    private func moveSidebarSelection(by offset: Int) {
        sidebarSelectionRaw = SettingsSidebarNavigation.selection(
            from: sidebarSelectionRaw,
            offset: offset,
            serverIDs: controller.profiles.map(\.id)
        )
        // Never request tab focus when merely selecting a server with Up/Down.
    }

    private func resetNavigationForPresentation(editingProfileID: UUID? = nil) {
        // Keep the app's active VNC profile; only reset the Settings UI focus.
        if let editingProfileID, controller.profiles.contains(where: { $0.id == editingProfileID }) {
            sidebarSelectionRaw = serverTag(editingProfileID)
        } else {
            sidebarSelectionRaw = controller.profiles.isEmpty
                ? SettingsSidebarNavigation.noServersTag
                : SettingsSidebarNavigation.generalTag
        }
        selectedTabRaw = ServerSettingsTab.connection.rawValue
        clearTransientKeyInput()
        isServerSidebarFocused = false
        // Once the Settings window is key, make its native sidebar the first
        // keyboard destination. This also works when reusing a hidden window.
        DispatchQueue.main.async { isServerSidebarFocused = true }
    }
    private func addServer() {
        let id = controller.addProfile(selectForConnection: false)
        sidebarSelectionRaw = serverTag(id)
        selectedTabRaw = ServerSettingsTab.connection.rawValue
    }
    private func removeServer(profileID: UUID) {
        guard controller.canRemoveProfile(profileID: profileID),
              let formerIndex = controller.profiles.firstIndex(where: { $0.id == profileID }),
              controller.removeProfile(profileID: profileID) else { return }
        if controller.profiles.isEmpty {
            sidebarSelectionRaw = SettingsSidebarNavigation.noServersTag
        } else {
            // Stay near the removed row; never change the menu's connection target.
            let nextIndex = min(formerIndex, controller.profiles.count - 1)
            sidebarSelectionRaw = serverTag(controller.profiles[nextIndex].id)
        }
        selectedTabRaw = ServerSettingsTab.connection.rawValue
    }
    private func clearTransientKeyInput() {
        keyPassphrase = ""
        keyPassphraseConfirmation = ""
        oldKeyPassphrase = ""
        passphraseSheetError = nil
        sshLoginPassword = ""
    }
    private func performKeyAction(_ action: KeyManagementAction) {
        pendingKeyAction = nil
        guard let id = pendingKeyActionProfileID,
              let profile = controller.profiles.first(where: { $0.id == id }) else { return }
        pendingKeyActionProfileID = nil
        switch action {
        case .removeFromAgent:
            Task { await controller.removeSelectedKeyFromAgent(profileID: profile.id) }
        case .removeFromServer:
            Task { await controller.removeSelectedRemotePublicKey(profileID: profile.id) }
        case .moveLocalPairToTrash:
            controller.trashSelectedLocalKeyPair(profileID: profile.id)
        }
    }
    private func selectExistingPrivateKey(profileID: UUID) {
        guard !controller.connectionFieldsLocked(profileID: profileID),
              !controller.isGeneratingKey else { return }
        let panel = NSOpenPanel()
        panel.title = "Select Existing SSH Private Key"
        panel.message = "Choose an existing private key. This changes only the selected server's configuration."
        panel.prompt = "Select Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let profile = controller.profiles.first(where: { $0.id == profileID }) {
            let currentPath = NSString(string: controller.keyPath(for: profile)).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url,
              !controller.connectionFieldsLocked(profileID: profileID) else { return }
        controller.selectKeyFile(profileID: profileID, path: url.path)
        Task { await controller.inspectSelectedKey(profileID: profileID) }
    }

    private func chooseNewKeyDestination(profileID: UUID) {
        guard !controller.isBusy, !controller.isGeneratingKey,
              let profile = controller.profiles.first(where: { $0.id == profileID }) else { return }
        // No NSSavePanel: the system Save panel offers "Replace", which is
        // intentionally NOT supported for SSH keys. Use a dedicated filename
        // editor whose Continue button is disabled for any collision.
        let suggested = SSHKeyPathPolicy.distinctPath(
            host: profile.server, directory: controller.keyDirectory,
            existing: controller.profiles.map { controller.keyPath(for: $0) }
        )
        let suggestedFolder = URL(fileURLWithPath: suggested).deletingLastPathComponent().path
        let initialFolder = suggestedFolder.isEmpty
            ? SSHKeyPathPolicy.directoryPath(controller.keyDirectory) : suggestedFolder
        let initialFileName = URL(fileURLWithPath: suggested).lastPathComponent
        pendingGenerateNextStep = nil
        generateKeyDestinationRequest = GenerateKeyDestinationRequest(
            profileID: profileID,
            initialFolder: initialFolder,
            initialFileName: initialFileName
        )
    }

    private func completeGenerateKeyDestinationStep() {
        guard let next = pendingGenerateNextStep else { return }
        pendingGenerateNextStep = nil
        // Present the passphrase sheet only after the destination sheet has
        // been dismissed. The existing passphrase editor handles empty values.
        guard !controller.isBusy, !controller.isGeneratingKey,
              controller.profiles.contains(where: { $0.id == next.profileID }),
              SSHNewKeyDestinationPolicy.validate(
                directory: URL(fileURLWithPath: next.path).deletingLastPathComponent().path,
                fileName: URL(fileURLWithPath: next.path).lastPathComponent,
                existing: controller.profiles.map { controller.keyPath(for: $0) }
              ) == .available else { return }
        preparePassphraseSheet(.generate(profileID: next.profileID, destinationPath: next.path))
    }

    private func renameKeyEditor(profileID: UUID) -> some View {
        let currentName = controller.profiles.first(where: { $0.id == profileID }).map {
            URL(fileURLWithPath: NSString(string: controller.keyPath(for: $0)).expandingTildeInPath).lastPathComponent
        } ?? ""
        let valid = SSHKeyPathPolicy.validFileName(newKeyName) && newKeyName != currentName
        return VStack(alignment: .leading, spacing: 14) {
            Text("Rename SSH Key").font(.headline)
            Text("Rename the private key and matching .pub file. Other Astroberry VNC servers sharing this key will be updated. External applications may need their key path updated manually.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("New key filename", text: $newKeyName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renameKeyRequest = nil }
                Button("Rename Key") {
                    controller.renameSelectedKey(profileID: profileID, newFileName: newKeyName)
                    renameKeyRequest = nil
                    if let current = controller.profiles.first(where: { $0.id == profileID }) {
                        Task { await refreshKeyProtection(profileID: current.id) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid || controller.keyResourceLocked(profileID: profileID))
            }
        }
        .padding(20)
        .frame(width: 430)
    }
    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    private func registrationHelp(privateExists: Bool, publicExists: Bool) -> String {
        if !privateExists || !publicExists { return "Create or select a complete key pair first" }
        if sshLoginPassword.isEmpty { return "Enter the one-time SSH login password" }
        return "Register only the public key, then verify public-key authentication"
    }
    private func updateLoginItem(enabled: Bool) {
        loginItemError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "The login item could not be changed: \(error.localizedDescription)"
        }
    }
}

enum SettingsWindowCoordinator {
    static let willPresentNotification = Notification.Name("AstroberryVNC.SettingsWillPresent")
    private static let identifier = NSUserInterfaceItemIdentifier("AstroberryVNC.Settings")
    private static var ownedWindowController: NSWindowController?
    static func configure(_ window: NSWindow, initialPresentation: Bool = false) {
        window.identifier = identifier
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.remove(.fullScreenNone)

        // Restore all three standard macOS title-bar controls: close (red),
        // minimize (yellow) and zoom / Move & Resize (green).
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.isMovable = true
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: SettingsWindowLayout.preferredContentSize)
        let preferred = SettingsWindowLayout.contentSize(visibleScreenSize: visibleFrame.size)
        let minimum = SettingsWindowLayout.minimumResizableContentSize(visibleScreenSize: visibleFrame.size)
        window.contentMinSize = minimum
        // Build 24 fixed min and max to the same size. Clear that old maximum
        // so edge-dragging and the green window button can actually resize.
        window.contentMaxSize = NSSize(width: 10_000, height: 10_000)

        if initialPresentation {
            // Initial default: 800×650pt, reduced only for a small display.
            window.setContentSize(preferred)
        }
        // Do not reset during ordinary SwiftUI view refresh: only restore
        // the default when Settings is explicitly reopened by the user.
        // Keep a dragged window where the user left it. On a new display or
        // first presentation, recover a window that is entirely off-screen.
        if initialPresentation || !window.frame.intersects(visibleFrame) {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            ))
        }
    }
    // Only the foreground Settings window (or one of its document-modal
    // sheets) is eligible for Command-Q -> close Settings. A hidden/minimized
    // window must not capture normal app termination.
    @MainActor private static var activeSettingsWindow: NSWindow? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        let parent = keyWindow.sheetParent ?? keyWindow
        guard parent.identifier == identifier,
              parent.isVisible,
              !parent.isMiniaturized else { return nil }
        return parent
    }

    @MainActor static var isSettingsActive: Bool {
        activeSettingsWindow != nil
    }

    @MainActor static func closeSettingsForCommandQ() {
        guard let window = activeSettingsWindow else { return }
        // Do not dismiss an SSH-key sheet that may be in the middle of a
        // protected operation. Command-Q is still swallowed, not a Quit.
        guard window.attachedSheet == nil else { return }
        window.performClose(nil)
    }

    @discardableResult static func showOnActiveSpace(editingProfileID: UUID? = nil) -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == identifier || $0.title == "Astroberry VNC Settings"
        }) else { return false }
        configure(window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.styleMask.contains(.fullScreen) {
            let screen = window.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setContentSize(SettingsWindowLayout.contentSize(visibleScreenSize: visible.size))
                // Keep the previous location where practical, but never lose
                // the title bar outside the usable screen.
                var frame = window.frame
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                window.setFrameOrigin(frame.origin)
            } else {
                window.setContentSize(SettingsWindowLayout.preferredContentSize)
            }
        }
        window.orderOut(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NotificationCenter.default.post(
            name: willPresentNotification,
            object: window,
            userInfo: editingProfileID.map { ["editingProfileID": $0.uuidString] }
        )
        return true
    }

    @MainActor static func presentOnActiveSpace(
        controller: ConnectionController, editingProfileID: UUID? = nil
    ) {
        NSApp.activate()
        if showOnActiveSpace(editingProfileID: editingProfileID) { return }
        let hostingController = NSHostingController(
            rootView: SettingsView(controller: controller, initialEditingProfileID: editingProfileID)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Astroberry VNC Settings"
        // Native title-bar buttons and user resizing are enabled again.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        configure(window, initialPresentation: true)
        let windowController = NSWindowController(window: window)
        ownedWindowController = windowController
        window.center()
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configureWindow(for: view, coordinator: context.coordinator) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.configuredWindow !== nsView.window else { return }
        DispatchQueue.main.async { configureWindow(for: nsView, coordinator: context.coordinator) }
    }
    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        SettingsWindowCoordinator.configure(window)
        coordinator.configuredWindow = window
    }
}
