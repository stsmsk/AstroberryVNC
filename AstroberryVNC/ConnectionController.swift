// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Network
import UserNotifications

struct VNCServerProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var displayName: String
    var server: String
    var sshPort: Int
    var username: String
    var privateKeyPath: String
    var vncHost: String
    var displayNumber: Int
    var vncPort: Int
    var viewerPath: String
    var connectTimeout: Int

    init(
        id: UUID = UUID(), displayName: String = "Astroberry", server: String,
        sshPort: Int = 22, username: String, privateKeyPath: String = "",
        vncHost: String = "127.0.0.1", displayNumber: Int = 70, vncPort: Int = 5970,
        viewerPath: String = "/Applications/TigerVNC.app", connectTimeout: Int = 10
    ) {
        self.id = id; self.displayName = displayName; self.server = server; self.sshPort = sshPort
        self.username = username; self.privateKeyPath = privateKeyPath; self.vncHost = vncHost
        self.displayNumber = displayNumber; self.vncPort = vncPort; self.viewerPath = viewerPath
        self.connectTimeout = connectTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, server, sshPort, username, privateKeyPath, vncHost, displayNumber, vncPort, viewerPath, connectTimeout
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Astroberry"
        server = try c.decode(String.self, forKey: .server)
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        username = try c.decode(String.self, forKey: .username)
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        vncHost = try c.decodeIfPresent(String.self, forKey: .vncHost) ?? "127.0.0.1"
        displayNumber = try c.decodeIfPresent(Int.self, forKey: .displayNumber) ?? 70
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort) ?? 5970
        viewerPath = try c.decodeIfPresent(String.self, forKey: .viewerPath) ?? "/Applications/TigerVNC.app"
        connectTimeout = try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? 10
    }
}

// Editing a profile and connecting to one are independent operations.
// This policy is pure so it is also verified without starting SSH or TigerVNC.
enum SessionProfileEditingPolicy {
    static func connectionFieldsLocked(profileID: UUID, sessionProfileID: UUID?) -> Bool {
        sessionProfileID == profileID
    }

    static func allowsProfileUpdate(
        previous: VNCServerProfile, proposed: VNCServerProfile, sessionProfileID: UUID?
    ) -> Bool {
        guard previous.id == proposed.id else { return false }
        guard connectionFieldsLocked(profileID: previous.id, sessionProfileID: sessionProfileID) else { return true }
        // While connecting/connected/disconnecting, only the friendly label
        // may change. Keep the tunnel's UUID and every connection setting.
        var unchangedConnection = proposed
        unchangedConnection.displayName = previous.displayName
        return unchangedConnection == previous
    }

    static func sameKeyFile(_ lhs: String, _ rhs: String) -> Bool {
        func standardized(_ path: String) -> String {
            NSString(string: path).expandingTildeInPath
        }
        let first = URL(fileURLWithPath: standardized(lhs)).standardizedFileURL.resolvingSymlinksInPath().path
        let second = URL(fileURLWithPath: standardized(rhs)).standardizedFileURL.resolvingSymlinksInPath().path
        return first == second
    }

    static func sameSSHHost(_ lhs: VNCServerProfile, _ rhs: VNCServerProfile) -> Bool {
        lhs.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && lhs.sshPort == rhs.sshPort
    }

    static func sameSSHAccount(_ lhs: VNCServerProfile, _ rhs: VNCServerProfile) -> Bool {
        sameSSHHost(lhs, rhs)
            && lhs.username.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// An empty profile collection is a valid, persistent state. The only implicit
// migration profile is created on a true first launch without saved profile data.
// Keep these rules independently testable and separate from SSH/VNC transport.
enum ServerProfileCollectionPolicy {
    static func restoredProfiles(
        savedProfiles: [VNCServerProfile]?, firstLaunchProfile: VNCServerProfile
    ) -> [VNCServerProfile] {
        savedProfiles ?? [firstLaunchProfile]
    }

    static func canRemove(
        profiles: [VNCServerProfile], profileID: UUID, activeProfileID: UUID?
    ) -> Bool {
        profiles.contains { $0.id == profileID } && activeProfileID != profileID
    }

    static func preferredSelection(
        profiles: [VNCServerProfile], savedID: UUID?
    ) -> UUID? {
        profiles.first(where: { $0.id == savedID })?.id ?? profiles.first?.id
    }

    static func replacementSelection(
        remainingProfiles: [VNCServerProfile], removedIndex: Int
    ) -> UUID? {
        guard !remainingProfiles.isEmpty else { return nil }
        return remainingProfiles[min(removedIndex, remainingProfiles.count - 1)].id
    }
}

// A Quit is allowed only when all app-owned resources have been verified
// stopped. Missing information is a failure, never implicit success.
enum ApplicationQuitCleanupResult: Equatable {
    case complete
    case incomplete(String)
}

enum ApplicationQuitCleanupPolicy {
    static func assess(
        connectionTaskFinished: Bool,
        viewer: QuitResourceState,
        tunnel: QuitResourceState,
        forwarding: QuitResourceState
    ) -> ApplicationQuitCleanupResult {
        var problems: [String] = []
        if !connectionTaskFinished { problems.append("An SSH connection operation is still running.") }
        for (name, state) in [("TigerVNC Viewer", viewer), ("SSH tunnel", tunnel), ("Local VNC forwarding", forwarding)] {
            switch state {
            case .stopped: break
            case .running: problems.append("\(name) is still running.")
            case .unknown(let reason): problems.append("Could not verify \(name): \(reason)")
            }
        }
        return problems.isEmpty ? .complete : .incomplete(problems.joined(separator: "\n"))
    }
}

// Build 31.8: Keep the two cancellation checks and the critical ownership
// handoff in one shared path. Tests supply an in-memory, suspendable launch
// operation; production supplies NSWorkspace without any artificial delay.
@MainActor
enum ConnectionViewerLaunchBoundary {
    static func run<Viewer>(
        checkCancellation: @MainActor () throws -> Void,
        launchViewer: @MainActor () async throws -> Viewer,
        rememberViewer: @MainActor (Viewer) -> Void
    ) async throws {
        try checkCancellation()
        let viewer = try await launchViewer()
        // IMPORTANT: remember the Viewer before checking for cancellation.
        // If Cancel arrives during launch, the caller's catch/rollback must
        // still have the exact handle needed for safe cleanup.
        rememberViewer(viewer)
        try checkCancellation()
    }
}

// This helper is also exercised with fake operations in unit tests: a failed
// Viewer shutdown is returned intact to the caller, while the SSH tunnel
// rollback is always attempted once it has been started.
@MainActor
enum ConnectionAttemptRollback {
    static func run(
        tunnelWasStarted: Bool,
        stopViewer: @MainActor () async -> QuitResourceState,
        stopTunnel: @MainActor () async -> Void
    ) async -> QuitResourceState {
        let viewerResult = await stopViewer()
        if tunnelWasStarted { await stopTunnel() }
        return viewerResult
    }
}

enum ConnectionStatus: Equatable {
    case disconnected, connecting, connected, disconnecting, error
    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .error: "Connection Error"
        }
    }
    var detail: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Opening the secure tunnel"
        case .disconnecting: "Closing Viewer and tunnel"
        case .error: "See the message below"
        case .disconnected: "Not connected"
        }
    }
}

// Production uses static status icons; only outline styling changes here.
// A separate launch-argument gate allows a nonpersistent symbol-effect test
// without touching working SSH/VNC code or changing saved preferences.
enum MenuBarIconStyle {
    static let monitorStrokeWidth: CGFloat = 1.20 // Build 31.9.3: 17% slimmer than 31.9.2
    static let standStrokeWidth: CGFloat = 1.20
}

// The animated AppKit status item is the Build 31.9.4 production host.
// Use --legacy-static-menu to run the previous Build 31.9.3 native SwiftUI
// MenuBarExtra unchanged if AppKit menu behavior needs investigation.
enum AnimatedStatusItemPolicy {
    static let legacyLaunchArgument = "--legacy-static-menu"
    static let rotationSeconds = 1.0

    static func useAnimatedHost(arguments: [String]) -> Bool {
        !arguments.contains(legacyLaunchArgument)
    }

    static func rotationDuration(for status: ConnectionStatus, reduceMotion: Bool) -> Double? {
        guard !reduceMotion else { return nil }
        switch status {
        case .connecting, .disconnecting: return rotationSeconds
        case .disconnected, .connected, .error: return nil
        }
    }
}

enum MenuBarSymbolEffectExperiment {
    static let launchArgument = "--experimental-symbol-effect"

    static func symbolName(for status: ConnectionStatus) -> String? {
        switch status {
        case .connecting: return "circle.dotted"
        case .disconnecting: return "arrow.triangle.2.circlepath"
        default: return nil
        }
    }

    static func isActive(
        arguments: [String], status: ConnectionStatus, reduceMotion: Bool
    ) -> Bool {
        arguments.contains(launchArgument)
            && !reduceMotion
            && symbolName(for: status) != nil
    }
}

// Build 31.9 menu-bar status presentation rules are kept outside SwiftUI
// so they can be tested by SwiftPM without a running menu-bar application.
enum MenuBarStatusGlyph: Equatable {
    case none, spinner, check, progressArc, exclamation
}

enum MenuBarStatusIconPresentation {
    // Disabled for Build 31.9.1: a TimelineView in the native status-menu
    // label repeatedly invalidated the status bar image and layout.
    // Preserve the frame rules for a future isolated animation implementation,
    // but do not advance them in production while this flag is false.
    static let liveAnimationEnabled = false
    static let frameCount = 8
    static let framesPerSecond = 8.0

    static func glyph(for status: ConnectionStatus) -> MenuBarStatusGlyph {
        switch status {
        case .disconnected: return .none
        case .connecting: return .spinner
        case .connected: return .check
        case .disconnecting: return .progressArc
        case .error: return .exclamation
        }
    }

    static func shouldAnimate(status: ConnectionStatus, reduceMotion: Bool) -> Bool {
        guard liveAnimationEnabled && !reduceMotion else { return false }
        return status == .connecting || status == .disconnecting
    }

    static func frameIndex(
        at timeInterval: TimeInterval, status: ConnectionStatus,
        reduceMotion: Bool
    ) -> Int {
        guard shouldAnimate(status: status, reduceMotion: reduceMotion),
              timeInterval.isFinite else { return 0 }
        // The monotonically advancing frame index cycles without stored state;
        // it cannot create an independent timer or survive a state transition.
        let oneCycle = Double(frameCount) / framesPerSecond
        let elapsedWithinCycle = max(0, timeInterval).truncatingRemainder(
            dividingBy: oneCycle
        )
        let frame = Int(elapsedWithinCycle * framesPerSecond)
        return frame
    }
}

enum ConnectionMenuOperation: Equatable {
    case connect, retry, cancel, disconnect, disconnecting
}

struct ConnectionMenuAction: Equatable {
    let title: String
    let systemImage: String
    let operation: ConnectionMenuOperation
    let isEnabled: Bool
}

struct ConnectionAttemptSignature: Equatable {
    let profile: VNCServerProfile
    let keyDirectory: String
    let viewerPath: String
    let connectTimeout: Int
}

struct ProfileSettingsFeedback: Equatable {
    var keyMessage: String?
    var keyError: String?
    var keyFingerprint: String?
    var hostKeyMessage: String?
    var hostKeyError: String?
    var canApproveHostKey = false
    var hostIsKnown: Bool?
    var pendingHostKeyLines: [String] = []

    mutating func clearKey() {
        keyMessage = nil
        keyError = nil
        keyFingerprint = nil
    }

    mutating func clearHost() {
        hostKeyMessage = nil
        hostKeyError = nil
        canApproveHostKey = false
        hostIsKnown = nil
        pendingHostKeyLines = []
    }
}

enum ProfileFeedbackDomain: Hashable {
    case hostKey
    case sshKey
}

struct ProfileFeedbackOperationTracker {
    private struct Key: Hashable {
        let profileID: UUID
        let domain: ProfileFeedbackDomain
    }
    private var tokens: [Key: UUID] = [:]

    mutating func begin(profileID: UUID, domain: ProfileFeedbackDomain) -> UUID {
        let token = UUID()
        tokens[Key(profileID: profileID, domain: domain)] = token
        return token
    }

    func isCurrent(_ token: UUID, profileID: UUID, domain: ProfileFeedbackDomain) -> Bool {
        tokens[Key(profileID: profileID, domain: domain)] == token
    }

    mutating func invalidate(profileID: UUID, domain: ProfileFeedbackDomain) {
        tokens.removeValue(forKey: Key(profileID: profileID, domain: domain))
    }

    mutating func remove(profileID: UUID) {
        tokens = tokens.filter { $0.key.profileID != profileID }
    }
}

// Keep health checks scoped to a single, currently connected session. Both
// the periodic task and notifications share this gate, so a delayed probe can
// never publish a result for a later connection or run alongside another probe.
struct ConnectionHealthMonitoringState {
    private(set) var sessionID: UUID?
    private var inFlightProbeID: UUID?

    mutating func beginSession() -> UUID {
        let newID = UUID()
        sessionID = newID
        inFlightProbeID = nil
        return newID
    }

    mutating func invalidateSession() {
        sessionID = nil
        inFlightProbeID = nil
    }

    mutating func beginProbe(for session: UUID) -> UUID? {
        guard sessionID == session, inFlightProbeID == nil else { return nil }
        let probe = UUID()
        inFlightProbeID = probe
        return probe
    }

    func accepts(session: UUID, probe: UUID) -> Bool {
        sessionID == session && inFlightProbeID == probe
    }

    mutating func endProbe(for session: UUID, probe: UUID) {
        guard accepts(session: session, probe: probe) else { return }
        inFlightProbeID = nil
    }
}

enum ConnectionHealthEvaluation: Equatable {
    case healthy, viewerClosed, tunnelStopped, forwardingStopped

    static func evaluate(tunnelAlive: Bool, forwardingAlive: Bool, viewerAlive: Bool) -> Self {
        if !viewerAlive { return .viewerClosed }
        if !tunnelAlive { return .tunnelStopped }
        if !forwardingAlive { return .forwardingStopped }
        return .healthy
    }
}

enum ServerMenuDismissalPolicy {
    static let presentationDelayMilliseconds = 80
    static let delayMilliseconds = 160

    static func shouldDismiss(isTriggerHovered: Bool, isListHovered: Bool) -> Bool {
        !isTriggerHovered && !isListHovered
    }
}

struct ServerMenuEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isSelected: Bool
}

enum ServerMenuSnapshot {
    static func entries(
        profiles: [VNCServerProfile],
        selectedProfileID: UUID,
        profileName: (VNCServerProfile) -> String
    ) -> [ServerMenuEntry] {
        profiles.map {
            ServerMenuEntry(
                id: $0.id,
                title: profileName($0),
                isSelected: $0.id == selectedProfileID
            )
        }
    }
}

extension ConnectionStatus {
    func menuAction(serverName: String) -> ConnectionMenuAction {
        switch self {
        case .disconnected:
            ConnectionMenuAction(title: "Connect to \(serverName)", systemImage: "play.fill", operation: .connect, isEnabled: true)
        case .connecting:
            ConnectionMenuAction(title: "Cancel Connection", systemImage: "xmark", operation: .cancel, isEnabled: true)
        case .connected:
            ConnectionMenuAction(title: "Disconnect from \(serverName)", systemImage: "stop.fill", operation: .disconnect, isEnabled: true)
        case .disconnecting:
            ConnectionMenuAction(title: "Disconnecting…", systemImage: "hourglass", operation: .disconnecting, isEnabled: false)
        case .error:
            ConnectionMenuAction(title: "Retry \(serverName)", systemImage: "arrow.clockwise", operation: .retry, isEnabled: true)
        }
    }
}

#if VISUAL_CHECK
enum VisualCheckScenario: String, CaseIterable, Identifiable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case failureRetry = "Failure · Retry"
    case failureConnect = "Failure · Connect"

    var id: String { rawValue }
    var accessibilityIdentifier: String {
        switch self {
        case .disconnected: "scenario-disconnected"
        case .connecting: "scenario-connecting"
        case .connected: "scenario-connected"
        case .failureRetry: "scenario-failure-retry"
        case .failureConnect: "scenario-failure-connect"
        }
    }
}
#endif

@MainActor
final class ConnectionController: ObservableObject {
    static let shared = ConnectionController()
#if VISUAL_CHECK
    static let visualCheck = ConnectionController(visualCheck: true)
#endif

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var isGeneratingKey = false
    @Published private(set) var activeLocalPort: Int?
    @Published private(set) var settingsFeedbackByProfileID: [UUID: ProfileSettingsFeedback] = [:]
    @Published private(set) var securityAdvisory: String?
    @Published var removeUsedKeysFromAgentOnQuit: Bool {
        didSet {
            if persistenceEnabled {
                defaults.set(removeUsedKeysFromAgentOnQuit, forKey: SSHAgentQuitKeyPolicy.preferenceKey)
            }
        }
    }
    @Published var profiles: [VNCServerProfile] {
        didSet { persistProfiles(); clearStaleConnectionErrorIfNeeded() }
    }
    @Published var selectedProfileID: UUID {
        didSet {
            if persistenceEnabled {
                if profiles.isEmpty {
                    defaults.removeObject(forKey: selectedProfileKey)
                } else {
                    defaults.set(selectedProfileID.uuidString, forKey: selectedProfileKey)
                }
            }
            clearStaleConnectionErrorIfNeeded()
        }
    }
    @Published var keyDirectory: String {
        didSet {
            if persistenceEnabled { defaults.set(keyDirectory, forKey: keyDirectoryKey) }
            for profileID in profiles.map(\.id) {
                invalidateFeedback(profileID: profileID, domain: .sshKey)
            }
            clearStaleConnectionErrorIfNeeded()
        }
    }
    @Published var viewerPath: String {
        didSet {
            if persistenceEnabled { defaults.set(viewerPath, forKey: viewerPathKey) }
            clearStaleConnectionErrorIfNeeded()
        }
    }
    @Published var connectTimeout: Int {
        didSet {
            if persistenceEnabled { defaults.set(connectTimeout, forKey: connectTimeoutKey) }
            for profileID in profiles.map(\.id) {
                invalidateFeedback(profileID: profileID, domain: .hostKey)
                invalidateFeedback(profileID: profileID, domain: .sshKey)
            }
            clearStaleConnectionErrorIfNeeded()
        }
    }

    private let system = SystemCommandRunner()
    private let defaults = UserDefaults.standard
    private let profilesKey = "VNCServerProfiles"
    private let selectedProfileKey = "SelectedVNCServerProfile"
    private let keyDirectoryKey = "SSHKeyDirectory"
    private let viewerPathKey = "TigerVNCViewerPath"
    private let connectTimeoutKey = "DefaultConnectTimeout"
    // Only the current launch-result instance may be controlled. No persisted PID.
    private var sessionViewerApplication: NSRunningApplication?
    private var activeDestination: String?
    private var activeSocket: String?
    private var activeProfile: VNCServerProfile?
    // Capture the target before the first await; locks also apply while SSH is
    // starting or being cancelled. A completed failure releases the lock.
    private var connectingProfile: VNCServerProfile?
    private var sessionKeyPath: String?
    // Never persisted. Multiple server connections may use different keys.
    // This record survives normal Disconnect but not application restart.
    private var usedSSHKeysThisLaunch: [SSHAgentUsedKey] = []
    private var sessionViewerPath: String?
    private var feedbackOperationTracker = ProfileFeedbackOperationTracker()
    private var cancelRequested = false
    private var failedConnectionSignature: ConnectionAttemptSignature?
    private var monitorTask: Task<Void, Never>?
    private var healthMonitoring = ConnectionHealthMonitoringState()
    private let pathMonitor = NWPathMonitor()
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var persistenceEnabled = true
    private var visualCheckMode = false

    init() {
        let decoded = UserDefaults.standard.data(forKey: "VNCServerProfiles")
            .flatMap { try? JSONDecoder().decode([VNCServerProfile].self, from: $0) }
        let keyDirectoryAtLaunch = UserDefaults.standard.string(forKey: "SSHKeyDirectory") ?? "~/.ssh"
        let initialProfiles = SSHKeyPathPolicy.pinLegacyPaths(
            ServerProfileCollectionPolicy.restoredProfiles(
                savedProfiles: decoded,
                firstLaunchProfile: VNCServerProfile(
                    server: UserDefaults.standard.string(forKey: "AstroberryServer") ?? "astroberry.local",
                    username: UserDefaults.standard.string(forKey: "AstroberryUsername") ?? "astroberry"
                )
            ), directory: keyDirectoryAtLaunch
        )
        let savedID = UserDefaults.standard.string(forKey: "SelectedVNCServerProfile").flatMap(UUID.init)
        let selectedForMigration = initialProfiles.first(where: { $0.id == savedID }) ?? initialProfiles.first
        profiles = initialProfiles
        // The UUID is an inert placeholder when no profiles exist, never a
        // connection target. selectedProfile remains nil until a profile is added.
        selectedProfileID = ServerProfileCollectionPolicy.preferredSelection(
            profiles: initialProfiles, savedID: savedID
        ) ?? UUID()
        keyDirectory = keyDirectoryAtLaunch
        removeUsedKeysFromAgentOnQuit = UserDefaults.standard.bool(
            forKey: SSHAgentQuitKeyPolicy.preferenceKey
        ) // OFF if the setting has never been saved.
        viewerPath = UserDefaults.standard.string(forKey: "TigerVNCViewerPath")
            ?? selectedForMigration?.viewerPath ?? "/Applications/TigerVNC.app"
        if UserDefaults.standard.object(forKey: "DefaultConnectTimeout") != nil {
            connectTimeout = UserDefaults.standard.integer(forKey: "DefaultConnectTimeout")
        } else {
            connectTimeout = selectedForMigration?.connectTimeout ?? 10
        }
        defaults.set(viewerPath, forKey: viewerPathKey)
        defaults.set(connectTimeout, forKey: connectTimeoutKey)
        // Ignore stale 31.4/31.5 records. An orphan from a crash must be closed
        // manually rather than risking termination of an unrelated Viewer.
        defaults.removeObject(forKey: "AstroberryViewerPID")
        defaults.removeObject(forKey: "AstroberryViewerIdentity")
        // Persist once so a legacy server's key stays pinned after SSH Host edits.
        persistProfiles()
        installAutomaticStatusObservers()
    }

#if VISUAL_CHECK
    private init(visualCheck: Bool) {
        let sampleProfiles = [
            VNCServerProfile(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                displayName: "Astroberry",
                server: "astroberry.local",
                username: "visual-check"
            ),
            VNCServerProfile(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                displayName: "Observatory",
                server: "observatory.local",
                username: "visual-check"
            ),
            VNCServerProfile(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                displayName: "Backup Pi",
                server: "backup-pi.local",
                username: "visual-check"
            )
        ]
        profiles = sampleProfiles
        selectedProfileID = sampleProfiles[0].id
        keyDirectory = ""
        removeUsedKeysFromAgentOnQuit = false
        viewerPath = ""
        connectTimeout = 1
        persistenceEnabled = false
        visualCheckMode = visualCheck
        applyVisualCheckScenario(.disconnected)
    }

    func applyVisualCheckScenario(_ scenario: VisualCheckScenario) {
        guard visualCheckMode, let selectedProfile else { return }
        isBusy = false
        healthMonitoring.invalidateSession()
        monitorTask?.cancel(); monitorTask = nil
        activeProfile = nil
        connectingProfile = nil
        sessionKeyPath = nil
        sessionViewerPath = nil
        activeLocalPort = nil
        failedConnectionSignature = nil
        lastError = nil
        securityAdvisory = nil

        switch scenario {
        case .disconnected:
            status = .disconnected
        case .connecting:
            status = .connecting
            isBusy = true
        case .connected:
            status = .connected
            activeProfile = selectedProfile
            activeLocalPort = 5901
        case .failureRetry:
            status = .error
            lastError = "Visual check: simulated SSH timeout"
            failedConnectionSignature = connectionAttemptSignature(for: selectedProfile)
        case .failureConnect:
            status = .error
            lastError = "Visual check: simulated failure for another server"
            var otherProfile = selectedProfile
            otherProfile.id = UUID()
            failedConnectionSignature = connectionAttemptSignature(for: otherProfile)
        }
    }
#endif

    var selectedProfile: VNCServerProfile? { profiles.first { $0.id == selectedProfileID } }
    var selectedSettingsFeedback: ProfileSettingsFeedback { settingsFeedback(for: selectedProfileID) }
    var keyGenerationMessage: String? { selectedSettingsFeedback.keyMessage }
    var keyGenerationError: String? { selectedSettingsFeedback.keyError }
    var keyFingerprint: String? { selectedSettingsFeedback.keyFingerprint }
    var hostKeyMessage: String? { selectedSettingsFeedback.hostKeyMessage }
    var hostKeyError: String? { selectedSettingsFeedback.hostKeyError }
    var canApproveHostKey: Bool { selectedSettingsFeedback.canApproveHostKey }
    var selectedHostIsKnown: Bool? { selectedSettingsFeedback.hostIsKnown }
    // Real connection identity must never follow the Settings sidebar selection.
    var connectedProfileID: UUID? { sessionProfile?.id }
    var selectedProfileIsActive: Bool { connectedProfileID == selectedProfileID }
    private var sessionProfile: VNCServerProfile? {
        switch status {
        case .connecting, .disconnecting: return connectingProfile ?? activeProfile
        case .connected: return activeProfile
        case .error: return activeProfile // Failed disconnect may leave a live tunnel.
        case .disconnected: return nil
        }
    }
    func connectionFieldsLocked(profileID: UUID) -> Bool {
        SessionProfileEditingPolicy.connectionFieldsLocked(profileID: profileID, sessionProfileID: connectedProfileID)
    }
    func keyResourceLocked(profileID: UUID) -> Bool {
        if connectionFieldsLocked(profileID: profileID) { return true }
        guard let profile = profiles.first(where: { $0.id == profileID }), let sessionKeyPath else { return false }
        return SessionProfileEditingPolicy.sameKeyFile(keyPath(for: profile), sessionKeyPath)
    }
    func remoteKeyResourceLocked(profileID: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }), let sessionProfile else { return false }
        // Same remote account OR a key used by the live session. Host aliases
        // can refer to the same machine, so a shared identity must also lock.
        return keyResourceLocked(profileID: profileID)
            || SessionProfileEditingPolicy.sameSSHAccount(profile, sessionProfile)
    }
    func hostTrustWriteLocked(profileID: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }), let sessionProfile else { return false }
        return SessionProfileEditingPolicy.sameSSHHost(profile, sessionProfile)
    }
    func canRemoveProfile(profileID: UUID) -> Bool {
        ServerProfileCollectionPolicy.canRemove(
            profiles: profiles, profileID: profileID, activeProfileID: connectedProfileID
        )
    }
    func securityAdvisory(for profileID: UUID) -> String? {
        activeProfile?.id == profileID ? securityAdvisory : nil
    }
    var canRetrySelectedConnection: Bool {
        guard status == .error,
              let failedConnectionSignature,
              let selectedProfile else { return false }
        return failedConnectionSignature == connectionAttemptSignature(for: selectedProfile)
    }
    var selectedServer: String { normalizedServer(selectedProfile?.server ?? "") }
    var selectedDestination: String { selectedProfile.map { destination(for: $0) } ?? "" }

    @discardableResult func addProfile(selectForConnection: Bool = true) -> UUID {
        let suggestedPath = SSHKeyPathPolicy.distinctPath(
            host: "new-server.local", directory: keyDirectory,
            existing: profiles.map { keyPath(for: $0) }
        )
        let profile = VNCServerProfile(
            displayName: "New Server", server: "new-server.local", username: "astroberry",
            privateKeyPath: suggestedPath
        )
        let wasEmpty = profiles.isEmpty
        profiles.append(profile)
        // Adding the first profile creates the only valid connection target.
        // Otherwise Settings must not change the menu's selected target.
        if wasEmpty || (selectForConnection && sessionProfile == nil) {
            selectedProfileID = profile.id
        }
        clearKeyMessages(profileID: profile.id)
        return profile.id
    }

    @discardableResult func removeProfile(profileID: UUID) -> Bool {
        guard canRemoveProfile(profileID: profileID),
              let index = profiles.firstIndex(where: { $0.id == profileID }) else { return false }
        profiles.remove(at: index) // Never deletes SSH key files or remote authorized_keys.
        settingsFeedbackByProfileID.removeValue(forKey: profileID)
        feedbackOperationTracker.remove(profileID: profileID)
        if selectedProfileID == profileID {
            // No last-item prohibition and no automatic replacement profile.
            // With zero profiles the placeholder UUID is never used for SSH.
            selectedProfileID = ServerProfileCollectionPolicy.replacementSelection(
                remainingProfiles: profiles, removedIndex: index
            ) ?? UUID()
        }
        return true
    }

    func removeSelectedProfile() {
        _ = removeProfile(profileID: selectedProfileID)
    }

    func updateServer(profileID: UUID, value: String) {
        updateProfile(profileID: profileID) { $0.server = value }
    }

    func updateUsername(profileID: UUID, value: String) {
        updateProfile(profileID: profileID) { $0.username = value }
    }

    func updateProfile(profileID: UUID, _ update: (inout VNCServerProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let previousHost = profiles[index].server
        let previousPort = profiles[index].sshPort
        let previousUsername = profiles[index].username
        let previousKeyPath = profiles[index].privateKeyPath
        var proposed = profiles[index]
        update(&proposed)
        guard SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: profiles[index], proposed: proposed, sessionProfileID: connectedProfileID
        ) else { return }
        profiles[index] = proposed
        if profiles[index].server != previousHost || profiles[index].sshPort != previousPort {
            invalidateFeedback(profileID: profileID, domain: .hostKey)
        }
        if profiles[index].server != previousHost || profiles[index].sshPort != previousPort ||
            profiles[index].username != previousUsername || profiles[index].privateKeyPath != previousKeyPath {
            invalidateFeedback(profileID: profileID, domain: .sshKey)
        }
    }

    func refreshSelectedHostTrust() async {
        await refreshHostTrust(profileID: selectedProfileID)
    }

    func refreshHostTrust(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let known = await system.knownHostEntryExists(host: profile.server, port: profile.sshPort)
        guard profiles.first(where: { $0.id == profile.id }) == profile else { return }
        updateFeedback(profileID: profile.id) { $0.hostIsKnown = known }
    }

    func keyPath(for profile: VNCServerProfile) -> String {
        if !profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Defensive fallback only for manually constructed/visual-check profiles.
        // Persisted profiles were pinned on load, so a Host edit cannot move the key.
        return SSHKeyPathPolicy.proposedPath(host: profile.server, directory: keyDirectory)
    }

    // The menu-bar app has no always-visible window. A native secure prompt is
    // shown only when the selected encrypted key is not already in ssh-agent.
    // NSAlert retains no passphrase in UserDefaults or the settings model.
    private func requestSSHKeyPassphrase(path: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Unlock SSH Private Key"
        alert.informativeText = "Enter the passphrase for \(URL(fileURLWithPath: path).lastPathComponent). It will be used only to unlock the key in ssh-agent."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        field.placeholderString = "SSH private-key passphrase"
        alert.accessoryView = field
        alert.layout()
        let promptWindow = alert.window
        // The initial first responder is only a preference. In this LSUIElement
        // menu-bar app, a prompt opened after asynchronous connection checks can
        // appear behind another app's keyboard focus. Reassert focus AFTER the
        // modal window is actually displayed, while the modal event loop runs.
        promptWindow.initialFirstResponder = field
        DispatchQueue.main.async { [weak promptWindow, weak field] in
            guard let promptWindow, let field, promptWindow.isVisible else { return }
            NSApp.activate()
            promptWindow.makeKeyAndOrderFront(nil)
            _ = promptWindow.makeFirstResponder(field)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let secret = field.stringValue
        field.stringValue = ""
        return secret
    }

    private func unlockSSHKeyIfNeeded(path: String) async throws {
        switch await system.keyUnlockState(path: path) {
        case .ready: return
        case .unusable(let reason): throw ConnectionFailure.invalidSettings(reason)
        case .needsPassphrase:
            // Up to three attempts without accidentally falling back to an
            // unrelated identity. Cancel aborts the current connection.
            for _ in 0..<3 {
                try checkCancellation()
                guard let secret = requestSSHKeyPassphrase(path: path) else { throw CancellationError() }
                let result = await system.unlockKeyInAgent(path: path, passphrase: secret)
                try checkCancellation()
                if result.exitCode == 0,
                   await system.keyUnlockState(path: path) == .ready { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could Not Unlock SSH Key"
                // Show useful diagnostics (incorrect passphrase vs ssh-agent
                // failure) without ever printing or persisting the secret.
                alert.informativeText = result.exitCode == 23
                    ? "Incorrect passphrase. Please try again."
                    : "Could not load the selected key into ssh-agent: \(result.readableError)"
                alert.runModal()
            }
            throw ConnectionFailure.sshFailed("Could not unlock the selected private key after three attempts.")
        }
    }

    func connect() async {
        guard !visualCheckMode else { return }
        guard !isBusy, !isGeneratingKey, activeProfile == nil,
              [.disconnected, .error].contains(status), let profile = selectedProfile else { return }
        let attemptSignature = connectionAttemptSignature(for: profile)
        // Shared General values apply only to the NEXT connection. Do not
        // allow subsequent edits to change this in-progress SSH attempt.
        let attemptKeyPath = keyPath(for: profile)
        let attemptViewerPath = viewerPath
        let attemptTimeout = connectTimeout
        failedConnectionSignature = nil
        // Invalidate any delayed probe from a previous session before starting.
        healthMonitoring.invalidateSession()
        monitorTask?.cancel(); monitorTask = nil
        connectingProfile = profile
        sessionKeyPath = attemptKeyPath
        sessionViewerPath = attemptViewerPath
        isBusy = true; status = .connecting; lastError = nil; securityAdvisory = nil; cancelRequested = false
        defer {
            connectingProfile = nil
            if status != .connected && activeProfile == nil {
                sessionKeyPath = nil
                sessionViewerPath = nil
                sessionViewerApplication = nil
            }
            isBusy = false
        }
        let destination = destination(for: profile)
        let socket = system.socketPath(profileID: profile.id)
        var startedTunnel = false
        var connectingPublicKey: String?
        do {
            let validationErrors = ServerSettingsValidator.validate(
                profile, viewerPath: attemptViewerPath, connectTimeout: attemptTimeout
            )
            guard validationErrors.isEmpty else { throw ConnectionFailure.invalidSettings(validationErrors.joined(separator: " ")) }
            try checkCancellation()
            switch await system.inspectKey(path: attemptKeyPath) {
            case .success(let inspection):
                connectingPublicKey = inspection.publicKey
                updateFeedback(profileID: profile.id) { $0.keyFingerprint = inspection.fingerprint }
            case .failure(let error): throw error
            }
            try await unlockSSHKeyIfNeeded(path: attemptKeyPath)
            try checkCancellation()
            if !(await system.knownHostEntryExists(host: profile.server, port: profile.sshPort)) {
                switch await system.scanHostKeys(host: profile.server, port: profile.sshPort, timeout: attemptTimeout) {
                case .failure(let error): throw error
                case .success(let scan):
                    if scan.state == .approvalRequired { throw ConnectionFailure.hostKeyApprovalRequired }
                    if scan.state == .changed { throw ConnectionFailure.hostKeyChanged }
                }
            }
            try checkCancellation()
            guard let localPort = system.allocateLoopbackPort() else { throw ConnectionFailure.noLocalPort }
            if await system.tunnelIsActive(destination: destination, socket: socket, sshPort: profile.sshPort) {
                _ = await system.stopTunnel(destination: destination, socket: socket, sshPort: profile.sshPort)
            }
            let result = await system.startTunnel(
                destination: destination, sshPort: profile.sshPort, keyPath: attemptKeyPath,
                socket: socket, localPort: localPort, remoteHost: profile.vncHost,
                remotePort: profile.vncPort, timeout: attemptTimeout
            )
            if system.isHostKeyMismatch(result) { throw ConnectionFailure.hostKeyChanged }
            guard result.exitCode == 0 else {
                throw ConnectionFailure.sshFailed(SSHConnectionErrorFormatter.description(for: result.readableError))
            }
            startedTunnel = true
            // Mark the exact identity only after the tunnel's SSH command
            // succeeded. Authentication failures or cancelled preflight
            // attempts do not count as keys used for this launch.
            if let connectingPublicKey {
                usedSSHKeysThisLaunch = SSHAgentQuitKeyPolicy.record(
                    path: attemptKeyPath, publicKey: connectingPublicKey,
                    previous: usedSSHKeysThisLaunch
                )
            }
            try checkCancellation()
            guard await system.tunnelIsActive(destination: destination, socket: socket, sshPort: profile.sshPort),
                  await system.localForwardListenerExists(localPort) else {
                throw ConnectionFailure.tunnelVerificationFailed
            }
            let remoteBinding = await system.inspectRemoteVNCBinding(
                destination: destination, sshPort: profile.sshPort, socket: socket,
                remotePort: profile.vncPort, timeout: attemptTimeout
            )
            // Fail closed: malformed/missing `ss` data must not silently permit
            // a connection that may expose TigerVNC outside loopback.
            if let failure = VNCBindingSafetyGate.connectionFailure(for: remoteBinding, remotePort: profile.vncPort) {
                throw failure
            }
            try checkCancellation()
            // A previous Viewer that did not exit must not be forgotten.
            guard await stopManagedViewer() == .stopped else {
                throw ConnectionFailure.viewerLaunchFailed("A previously managed TigerVNC Viewer has not exited.")
            }
            try await ConnectionViewerLaunchBoundary.run(
                checkCancellation: { try self.checkCancellation() },
                launchViewer: {
                    try await self.system.launchViewer(viewerPath: attemptViewerPath, localPort: localPort)
                },
                rememberViewer: { self.sessionViewerApplication = $0 }
            )
            activeDestination = destination
            activeSocket = socket
            activeProfile = profile
            activeLocalPort = localPort
            failedConnectionSignature = nil
            status = .connected
            startMonitoring()
        } catch {
            let viewerCleanup = await ConnectionAttemptRollback.run(
                tunnelWasStarted: startedTunnel,
                stopViewer: { await self.stopManagedViewer() },
                stopTunnel: {
                    _ = await self.system.stopTunnel(
                        destination: destination, socket: socket, sshPort: profile.sshPort
                    )
                }
            )
            // Preserve the actual Viewer handle and session if a canceled or
            // failed Connect could not close it. Quit/Disconnect can retry.
            if viewerCleanup != .stopped {
                activeProfile = profile; activeDestination = destination
                activeSocket = socket; activeLocalPort = nil
                status = .error
                lastError = "TigerVNC Viewer did not exit after the failed connection. Disconnect or Quit to retry cleanup."
                return
            }
            if cancelRequested || error is CancellationError {
                failedConnectionSignature = nil
                status = .disconnected; lastError = nil
            } else {
                failedConnectionSignature = attemptSignature
                status = .error; lastError = error.localizedDescription
                Task { await notify(title: "Astroberry VNC connection failed", body: error.localizedDescription) }
            }
        }
    }

    // Called only for an explicit status-menu Quit. Unlike regular
    // Disconnect, termination must verify BOTH the Viewer and the tunnel
    // have stopped, and keep the app alive if cleanup cannot be confirmed.
    func prepareForApplicationQuit() async -> ApplicationQuitCleanupResult {
        guard !visualCheckMode else { return .complete }
        healthMonitoring.invalidateSession()
        monitorTask?.cancel(); monitorTask = nil

        // Capture the connecting profile before waiting: rollback may fail
        // before activeProfile is published, and a live ControlMaster must
        // still be checked before allowing termination.
        let startingProfile = connectingProfile
        // Disconnect during Connecting only requests cancellation. Wait for
        // the in-flight connect() to finish its own tunnel rollback first.
        if status == .connecting {
            cancelRequested = true
            status = .disconnecting
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while isBusy {
            if ContinuousClock.now >= deadline {
                return .incomplete("The current Connect/Disconnect operation did not finish within 15 seconds. No forced Quit was performed.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A failed/cancelled connection may leave an owned Viewer even when
        // no active profile remains. Never claim Quit cleanup is complete
        // without attempting to close that exact retained application.
        guard let profile = activeProfile ?? startingProfile else {
            guard let viewer = sessionViewerApplication else { return .complete }
            let viewerState = await system.terminateViewer(
                application: viewer, timeout: 3, forceIfNeeded: true, forceTimeout: 3
            )
            if viewerState == .stopped {
                clearViewerSession()
                status = .disconnected
                return .complete
            }
            status = .error
            lastError = "Quit cleanup was incomplete: TigerVNC Viewer is still running."
            return .incomplete("TigerVNC Viewer is still running.")
        }
        let destination = activeDestination ?? destination(for: profile)
        let socket = activeSocket ?? system.socketPath(profileID: profile.id)

        isBusy = true
        status = .disconnecting
        lastError = nil
        defer { isBusy = false }

        let port = activeLocalPort
        let viewerApplication = sessionViewerApplication
        // Only the explicit Quit path may force-terminate the app-owned
        // Viewer if it ignores the graceful termination request.
        if let viewerApplication {
            _ = await system.terminateViewer(
                application: viewerApplication, timeout: 3,
                forceIfNeeded: true, forceTimeout: 3
            )
        }

        // A ControlMaster exit command can report failure after the SSH
        // process already exited; final presence checks decide success.
        _ = await system.requestTunnelExitForQuit(destination: destination, socket: socket,
                                                  sshPort: profile.sshPort)

        var viewerState: QuitResourceState = .stopped
        var tunnelState: QuitResourceState = .unknown("Not yet checked")
        var forwardingState: QuitResourceState = .stopped
        // Give SIGTERM and SSH -O exit time to complete; do not use a TCP
        // connect probe against the passwordless TigerVNC server.
        for attempt in 0..<6 {
            viewerState = viewerApplication.map { system.viewerStateForQuit(application: $0) }
                ?? (port == nil ? .stopped : .unknown("The launched Viewer handle was not recorded."))
            tunnelState = await system.tunnelStateForQuit(destination: destination,
                                                          socket: socket, sshPort: profile.sshPort)
            if let port {
                forwardingState = await system.forwardingStateForQuit(localPort: port)
            } else {
                forwardingState = .stopped
            }
            let assessment = ApplicationQuitCleanupPolicy.assess(
                connectionTaskFinished: true, viewer: viewerState,
                tunnel: tunnelState, forwarding: forwardingState
            )
            if assessment == .complete { break }
            if attempt < 5 { try? await Task.sleep(for: .milliseconds(300)) }
        }

        let assessment = ApplicationQuitCleanupPolicy.assess(
            connectionTaskFinished: true, viewer: viewerState,
            tunnel: tunnelState, forwarding: forwardingState
        )
        switch assessment {
        case .complete:
            clearViewerSession()
            activeDestination = nil; activeSocket = nil; activeProfile = nil; activeLocalPort = nil
            sessionKeyPath = nil; sessionViewerPath = nil
            failedConnectionSignature = nil; securityAdvisory = nil
            status = .disconnected
        case .incomplete(let reason):
            // Keep the profile/socket identity for Retry Cleanup. Do not
            // claim Disconnected or release its editing lock on uncertainty.
            status = .error
            lastError = "Quit cleanup was incomplete: \(reason)"
        }
        return assessment
    }

    // Invoked only after prepareForApplicationQuit() has confirmed cleanup.
    // A failure keeps the app open and uses the existing Retry / Quit Anyway
    // dialog; the user is never told the SSH key was removed unless verified.
    func removeUsedSSHKeysFromAgentForMenuQuit() async -> ApplicationQuitCleanupResult {
        guard !visualCheckMode,
              SSHAgentQuitKeyPolicy.isEnabledForQuit(
                  preferenceEnabled: removeUsedKeysFromAgentOnQuit, explicitMenuQuit: true
              ) else { return .complete }
        var failures: [String] = []
        var retained: [SSHAgentUsedKey] = []
        for key in usedSSHKeysThisLaunch {
            if let reason = await system.removeRecordedKeyFromAgentForQuit(key) {
                failures.append(reason)
                retained.append(key)
            }
        }
        usedSSHKeysThisLaunch = retained
        return failures.isEmpty ? .complete : .incomplete(
            "Could not remove all used SSH identities from ssh-agent:\n" + failures.joined(separator: "\n")
        )
    }

    func disconnect() async {
        guard !visualCheckMode else { return }
        failedConnectionSignature = nil
        if status == .connecting {
            cancelRequested = true
            status = .disconnecting
            return
        }
        guard !isBusy else { return }
        // Invalidate outstanding health checks BEFORE the first suspension.
        // Their results must not alter this disconnect or a later connection.
        healthMonitoring.invalidateSession()
        monitorTask?.cancel(); monitorTask = nil
        isBusy = true; status = .disconnecting; lastError = nil
        defer { isBusy = false }
        guard let profile = activeProfile ?? selectedProfile else {
            // A zero-server state has no SSH/VNC tunnel to stop.
            status = .disconnected
            return
        }
        let viewerCleanup = await stopManagedViewer()
        let destination = activeDestination ?? destination(for: profile)
        let socket = activeSocket ?? system.socketPath(profileID: profile.id)
        let result = await system.stopTunnel(destination: destination, socket: socket, sshPort: profile.sshPort)
        var tunnelStillActive = false
        if result.exitCode != 0 {
            tunnelStillActive = await system.tunnelIsActive(
                destination: destination, socket: socket, sshPort: profile.sshPort
            )
        }
        if tunnelStillActive || viewerCleanup != .stopped {
            status = .error
            lastError = tunnelStillActive
                ? "The SSH tunnel could not be closed: \(result.readableError)"
                : "The TigerVNC Viewer has not exited. Retry Disconnect."
            Task { await notify(title: "Astroberry VNC disconnect failed", body: lastError!) }
        } else {
            activeDestination = nil; activeSocket = nil; activeProfile = nil; activeLocalPort = nil
            sessionKeyPath = nil; sessionViewerPath = nil
            status = .disconnected
        }
    }

    func refreshStatus() async {
        await refreshStatus(expectedSession: nil)
    }

    private func refreshStatus(expectedSession: UUID?) async {
        guard !visualCheckMode, !isBusy, status == .connected,
              let session = healthMonitoring.sessionID,
              expectedSession == nil || expectedSession == session,
              let profile = activeProfile,
              let destination = activeDestination,
              let socket = activeSocket,
              let localPort = activeLocalPort,
              let probe = healthMonitoring.beginProbe(for: session) else { return }
        defer { healthMonitoring.endProbe(for: session, probe: probe) }

        let viewerApplication = sessionViewerApplication
        let viewerAlive = viewerApplication.map { system.isExpectedViewer(application: $0) } ?? false

        let tunnelAlive = await system.tunnelIsActive(
            destination: destination, socket: socket, sshPort: profile.sshPort
        )
        guard isCurrentHealthProbe(session: session, probe: probe, profileID: profile.id) else { return }
        let forwardingAlive = await system.localForwardListenerExists(localPort)
        guard isCurrentHealthProbe(session: session, probe: probe, profileID: profile.id) else { return }

        let result = ConnectionHealthEvaluation.evaluate(
            tunnelAlive: tunnelAlive, forwardingAlive: forwardingAlive, viewerAlive: viewerAlive
        )
        guard result != .healthy else { return }

        // Own the entire cleanup before any await. A Connect/Disconnect or a
        // second monitor callback must not race with this stale-session teardown.
        isBusy = true
        status = .disconnecting
        healthMonitoring.invalidateSession()
        monitorTask?.cancel(); monitorTask = nil
        defer { isBusy = false }

        if tunnelAlive {
            _ = await system.stopTunnel(destination: destination, socket: socket, sshPort: profile.sshPort)
        }
        if viewerAlive, let viewerApplication {
            let cleanup = await system.terminateViewer(application: viewerApplication)
            if cleanup != .stopped {
                // Keep the handle/profile for Retry Disconnect. Never claim
                // the entire connection is gone while its Viewer still runs.
                status = .error
                lastError = "TigerVNC Viewer did not exit during recovery. Retry Disconnect."
                return
            }
        }
        clearViewerSession()
        activeDestination = nil; activeSocket = nil; activeProfile = nil; activeLocalPort = nil
        sessionKeyPath = nil; sessionViewerPath = nil
        failedConnectionSignature = nil
        securityAdvisory = nil

        switch result {
        case .healthy: break // Handled by the guard above.
        case .viewerClosed:
            status = .disconnected
            lastError = nil
        case .tunnelStopped:
            status = .error
            lastError = "The SSH tunnel ended unexpectedly. TigerVNC was closed safely."
        case .forwardingStopped:
            status = .error
            lastError = "The local forwarding port stopped responding. TigerVNC and the SSH tunnel were closed safely."
        }
    }

    private func isCurrentHealthProbe(session: UUID, probe: UUID, profileID: UUID) -> Bool {
        !isBusy && status == .connected && activeProfile?.id == profileID
            && healthMonitoring.accepts(session: session, probe: probe)
    }

    func generateSSHKey(profileID: UUID, destinationPath: String, passphrase: String) async {
        guard !isGeneratingKey, !isBusy,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let path = NSString(string: destinationPath).expandingTildeInPath
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        guard !path.isEmpty, path != "/",
              !SSHKeyPathPolicy.fileOrSymlinkExists(path),
              !SSHKeyPathPolicy.fileOrSymlinkExists(path + ".pub"),
              (sessionKeyPath.map { !SSHKeyPathPolicy.sameFilePath(path, $0) } ?? true) else {
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyError = "The requested destination is in use or already exists. Choose another filename."
            }
            return
        }
        isGeneratingKey = true
        defer { isGeneratingKey = false }
        let result = await system.generateSSHKey(
            path: path, passphrase: passphrase,
            comment: "\(destination(for: profile)) via Astroberry VNC"
        )
        if result.exitCode == 0 {
            // Do not bind a new key to a profile that changed while the
            // generator ran or one that is currently connected.
            guard profiles.first(where: { $0.id == profile.id }) == profile else {
                updateFeedback(profileID: profileID) {
                    $0.keyError = "Key created at \(path), but the server profile changed. Select it explicitly."
                }
                return
            }
            if connectionFieldsLocked(profileID: profileID) {
                updateFeedback(profileID: profileID) {
                    $0.keyMessage = "Key created at \(path). The active connection is unchanged. Disconnect, then use Select Existing Key to adopt it."
                }
            } else {
                updateProfile(profileID: profileID) { $0.privateKeyPath = path }
                // updateProfile invalidates the old feedback token.
                updateFeedback(profileID: profileID) {
                    $0.keyMessage = "New SSH key created and selected. Register its public key on the server."
                }
            }
        } else {
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyError = result.readableError
            }
        }
    }

    // Selecting a different file changes only this saved profile. The source
    // key can be shared with a live connection; it is never modified here.
    func selectKeyFile(profileID: UUID, path: String) {
        guard !isGeneratingKey, !connectionFieldsLocked(profileID: profileID),
              !path.isEmpty else { return }
        updateProfile(profileID: profileID) { $0.privateKeyPath = path }
    }

    func renameSelectedKey(profileID: UUID, newFileName: String) {
        guard !isGeneratingKey, !isBusy, !keyResourceLocked(profileID: profileID),
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let original = keyPath(for: profile)
        let referencedIDs = Set(profiles.filter {
            SessionProfileEditingPolicy.sameKeyFile(keyPath(for: $0), original)
        }.map(\.id))
        let result = SSHKeyPairRenamer.rename(path: original, toFileName: newFileName)
        switch result {
        case .failure(let error):
            updateFeedback(profileID: profileID) { $0.keyError = error.localizedDescription }
        case .success(let destination):
            // All saved profiles sharing the local file follow the rename,
            // but no running session ever uses this path (locked above).
            profiles = SSHKeyPathPolicy.replacingReferences(
                in: profiles, profileIDs: referencedIDs, to: destination
            )
            for id in profiles.map(\.id) {
                invalidateFeedback(profileID: id, domain: .sshKey)
            }
            updateFeedback(profileID: profileID) {
                $0.keyMessage = "Renamed the private key and .pub file. All Astroberry VNC profiles using this key were updated."
            }
        }
    }

    func changeSelectedKeyPassphrase(
        profileID: UUID, current: String, replacement: String
    ) async {
        guard !isGeneratingKey, !isBusy, !keyResourceLocked(profileID: profileID),
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        isGeneratingKey = true
        defer { isGeneratingKey = false }
        guard !keyResourceLocked(profileID: profileID) else { return }
        let path = keyPath(for: profile)
        let protection = await system.privateKeyProtectionState(path: path)
        let operationAllowed: Bool
        switch protection {
        case .unprotected: operationAllowed = current.isEmpty && !replacement.isEmpty
        case .protected: operationAllowed = !current.isEmpty
        case .unavailable: operationAllowed = false
        }
        guard operationAllowed else {
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyError = "The passphrase operation does not match the private key's protection state."
            }
            return
        }
        let result = await system.changeKeyPassphrase(
            path: path, current: current, replacement: replacement
        )
        commitFeedback(profile: profile, domain: .sshKey, token: token) {
            if result.exitCode == 0 {
                $0.keyMessage = replacement.isEmpty
                    ? "Passphrase removed. Public key and fingerprint are unchanged."
                    : "Passphrase updated. Public key and fingerprint are unchanged."
            } else {
                $0.keyError = "Could not change the key passphrase: \(result.readableError)"
            }
        }
    }

    func inspectSelectedKey(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        switch await system.inspectKey(path: keyPath(for: profile)) {
        case .success(let inspection):
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyFingerprint = inspection.fingerprint
                $0.keyMessage = "ED25519 key pair is valid."
            }
        case .failure(let error):
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyError = error.localizedDescription
            }
        }
    }

    func inspectSelectedHostKey(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .hostKey)
        switch await system.scanHostKeys(host: profile.server, port: profile.sshPort, timeout: connectTimeout) {
        case .failure(let error):
            commitFeedback(profile: profile, domain: .hostKey, token: token) {
                $0.hostKeyError = error.localizedDescription
            }
        case .success(let scan):
            let details = scan.fingerprints.joined(separator: "\n")
            commitFeedback(profile: profile, domain: .hostKey, token: token) {
                switch scan.state {
                case .trusted:
                    $0.hostIsKnown = true
                    $0.hostKeyMessage = "Host key matches known_hosts.\n\(details)"
                case .approvalRequired:
                    $0.hostIsKnown = false
                    $0.hostKeyMessage = "Untrusted host key. Verify these fingerprints through another channel before approving:\n\(details)"
                    $0.pendingHostKeyLines = scan.lines
                    $0.canApproveHostKey = true
                case .changed:
                    $0.hostIsKnown = true
                    $0.hostKeyError = "HOST KEY CHANGED. Connections are blocked. Verify the server through another channel; known_hosts was not modified.\n\(details)"
                }
            }
        }
    }

    func approvePendingHostKey(profileID: UUID? = nil) {
        guard let profile = profile(for: profileID),
              !hostTrustWriteLocked(profileID: profile.id) else { return }
        let feedback = settingsFeedback(for: profile.id)
        guard feedback.canApproveHostKey, !feedback.pendingHostKeyLines.isEmpty else { return }
        let result = system.trustHostKeys(feedback.pendingHostKeyLines)
        guard profiles.first(where: { $0.id == profile.id }) == profile else { return }
        if result.exitCode == 0 {
            updateFeedback(profileID: profile.id) {
                $0.hostKeyMessage = "Host key saved to known_hosts."
                $0.hostKeyError = nil
                $0.hostIsKnown = true
                $0.canApproveHostKey = false
                $0.pendingHostKeyLines = []
            }
        } else {
            updateFeedback(profileID: profile.id) { $0.hostKeyError = result.readableError }
        }
    }

    func regeneratePublicKey(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID), !keyResourceLocked(profileID: profile.id) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        let result = await system.regeneratePublicKey(path: keyPath(for: profile))
        commitFeedback(profile: profile, domain: .sshKey, token: token) {
            if result.exitCode == 0 { $0.keyMessage = "Public key regenerated from the private key." }
            else { $0.keyError = result.readableError }
        }
    }

    func removeSelectedKeyFromAgent(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID), !keyResourceLocked(profileID: profile.id) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        let result = await system.removeKeyFromAgent(path: keyPath(for: profile))
        commitFeedback(profile: profile, domain: .sshKey, token: token) {
            if result.exitCode == 0 {
                $0.keyMessage = "The selected key was removed from the SSH agent. Local key files were not changed."
            } else {
                $0.keyError = "Could not remove the selected key from the SSH agent: \(result.readableError)"
            }
        }
    }

    func removeSelectedRemotePublicKey(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID) else { return }
        guard !remoteKeyResourceLocked(profileID: profile.id) else {
            updateFeedback(profileID: profile.id) { $0.keyError = "Disconnect the active SSH session before modifying this account's authorized_keys." }
            return
        }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        switch await system.inspectKey(path: keyPath(for: profile)) {
        case .failure(let error):
            commitFeedback(profile: profile, domain: .sshKey, token: token) { $0.keyError = error.localizedDescription }
        case .success(let inspection):
            guard !remoteKeyResourceLocked(profileID: profile.id) else { return }
            let result = await system.removeRemotePublicKey(
                destination: destination(for: profile), sshPort: profile.sshPort,
                keyPath: keyPath(for: profile), publicKey: inspection.publicKey,
                timeout: connectTimeout
            )
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                if result.exitCode == 0 {
                    $0.keyMessage = result.output.contains("REMOTE_KEY_NOT_PRESENT")
                        ? "The selected public key was not present on the server."
                        : "The selected public key was removed from the server. Other authorized keys were preserved."
                } else {
                    $0.keyError = "Could not remove the selected public key from the server: \(result.readableError)"
                }
            }
        }
    }

    func trashSelectedLocalKeyPair(profileID: UUID? = nil) {
        guard let profile = profile(for: profileID) else { return }
        guard !keyResourceLocked(profileID: profile.id) else {
            updateFeedback(profileID: profile.id) { $0.keyError = "Disconnect the session using this SSH key before deleting it." }
            return
        }
        let result = system.trashLocalKeyPair(path: keyPath(for: profile))
        updateFeedback(profileID: profile.id) {
            $0.clearKey()
            if result.exitCode == 0 {
                $0.keyMessage = "The local private and public key files were moved to Trash. Remote authorized_keys was not changed."
            } else {
                $0.keyError = result.readableError
            }
        }
    }

    func testSelectedKeyAuthentication(profileID: UUID? = nil) async {
        guard let profile = profile(for: profileID) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        do { try await unlockSSHKeyIfNeeded(path: keyPath(for: profile)) }
        catch {
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                $0.keyError = error is CancellationError ? "SSH key unlock cancelled." : error.localizedDescription
            }
            return
        }
        let result = await system.testPublicKey(
            destination: destination(for: profile), sshPort: profile.sshPort,
            keyPath: keyPath(for: profile), timeout: connectTimeout
        )
        commitFeedback(profile: profile, domain: .sshKey, token: token) {
            if result.exitCode == 0, result.output == "ASTROBERRY_KEY_OK" {
                $0.keyMessage = "Public-key authentication succeeded with the selected key only."
            } else {
                $0.keyError = SSHConnectionErrorFormatter.description(for: result.readableError)
            }
        }
    }

    func registerSelectedPublicKey(profileID: UUID? = nil, password: String) async {
        guard let profile = profile(for: profileID), !remoteKeyResourceLocked(profileID: profile.id) else { return }
        let token = beginFeedbackOperation(profile: profile, domain: .sshKey)
        defer { /* password belongs only to the caller's transient state */ }
        switch await system.inspectKey(path: keyPath(for: profile)) {
        case .failure(let error):
            commitFeedback(profile: profile, domain: .sshKey, token: token) { $0.keyError = error.localizedDescription }
        case .success(let inspection):
            guard !remoteKeyResourceLocked(profileID: profile.id) else { return }
            let result = await system.registerPublicKey(
                destination: destination(for: profile), sshPort: profile.sshPort,
                password: password, publicKey: inspection.publicKey, timeout: connectTimeout
            )
            guard result.exitCode == 0 else {
                commitFeedback(profile: profile, domain: .sshKey, token: token) {
                    $0.keyError = "Public-key registration failed without changing unsafe files: \(result.readableError)"
                }
                return
            }
            let authentication = await system.testPublicKey(
                destination: destination(for: profile), sshPort: profile.sshPort,
                keyPath: keyPath(for: profile), timeout: connectTimeout
            )
            commitFeedback(profile: profile, domain: .sshKey, token: token) {
                if authentication.exitCode == 0, authentication.output == "ASTROBERRY_KEY_OK" {
                    $0.keyMessage = result.output.contains("ALREADY_REGISTERED")
                        ? "The same key was already registered; authentication succeeded."
                        : "Public key registered once; authentication succeeded."
                } else {
                    $0.keyError = "Public-key authentication failed after registration. " +
                        SSHConnectionErrorFormatter.description(for: authentication.readableError)
                }
            }
        }
    }

    func copyPublicKey(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let key = system.readPublicKey(path: keyPath(for: profile)) else {
            updateFeedback(profileID: profileID) { $0.keyError = "The public key file was not found." }
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
        updateFeedback(profileID: profileID) {
            $0.keyMessage = "Public key copied to the clipboard."
            $0.keyError = nil
        }
    }

    func clearKeyMessages(profileID: UUID? = nil) {
        let id = profileID ?? selectedProfileID
        invalidateFeedback(profileID: id, domain: .sshKey)
    }

    func settingsFeedback(for profileID: UUID) -> ProfileSettingsFeedback {
        settingsFeedbackByProfileID[profileID] ?? ProfileSettingsFeedback()
    }

    private func profile(for profileID: UUID?) -> VNCServerProfile? {
        let id = profileID ?? selectedProfileID
        return profiles.first(where: { $0.id == id })
    }

    private func beginFeedbackOperation(
        profile: VNCServerProfile,
        domain: ProfileFeedbackDomain
    ) -> UUID {
        let token = feedbackOperationTracker.begin(profileID: profile.id, domain: domain)
        updateFeedback(profileID: profile.id) {
            switch domain {
            case .hostKey: $0.clearHost()
            case .sshKey: $0.clearKey()
            }
        }
        return token
    }

    private func commitFeedback(
        profile: VNCServerProfile,
        domain: ProfileFeedbackDomain,
        token: UUID,
        update: (inout ProfileSettingsFeedback) -> Void
    ) {
        guard feedbackOperationTracker.isCurrent(token, profileID: profile.id, domain: domain),
              profiles.first(where: { $0.id == profile.id }) == profile else { return }
        updateFeedback(profileID: profile.id, update)
    }

    private func invalidateFeedback(profileID: UUID, domain: ProfileFeedbackDomain) {
        feedbackOperationTracker.invalidate(profileID: profileID, domain: domain)
        updateFeedback(profileID: profileID) {
            switch domain {
            case .hostKey: $0.clearHost()
            case .sshKey: $0.clearKey()
            }
        }
    }

    private func updateFeedback(
        profileID: UUID,
        _ update: (inout ProfileSettingsFeedback) -> Void
    ) {
        var next = settingsFeedback(for: profileID)
        let previous = next
        update(&next)
        guard next != previous else { return }
        var allFeedback = settingsFeedbackByProfileID
        allFeedback[profileID] = next
        settingsFeedbackByProfileID = allFeedback
    }

    private func connectionAttemptSignature(for profile: VNCServerProfile) -> ConnectionAttemptSignature {
        ConnectionAttemptSignature(
            profile: profile,
            keyDirectory: keyDirectory,
            viewerPath: viewerPath,
            connectTimeout: connectTimeout
        )
    }
    private func clearStaleConnectionErrorIfNeeded() {
        // A failed disconnect may still have a live SSH tunnel. Never release
        // its edit lock merely because a Settings preference was changed.
        guard activeProfile == nil, status == .error, !canRetrySelectedConnection else { return }
        failedConnectionSignature = nil
        status = .disconnected
        lastError = nil
        securityAdvisory = nil
    }
    private func normalizedServer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "new-server.local" : trimmed
    }
    private func checkCancellation() throws {
        if cancelRequested || Task.isCancelled { throw CancellationError() }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        let session = healthMonitoring.beginSession()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.healthMonitoring.sessionID == session else { return }
                // The timer and the application/network/wake observers share
                // one gate. Extra requests are skipped until the next tick.
                await self.refreshStatus(expectedSession: session)
            }
        }
    }
    private func normalizedUsername(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "astroberry" : trimmed
    }
    private func destination(for profile: VNCServerProfile) -> String {
        "\(normalizedUsername(profile.username))@\(normalizedServer(profile.server))"
    }
    private func persistProfiles() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) }
    }
    @discardableResult
    private func stopManagedViewer() async -> QuitResourceState {
        guard let application = sessionViewerApplication else { return .stopped }
        let result = await system.terminateViewer(application: application, timeout: 5)
        if result == .stopped { clearViewerSession() }
        return result
    }

    private func clearViewerSession() {
        sessionViewerApplication = nil
    }

    private func installAutomaticStatusObservers() {
        let appCenter = NotificationCenter.default
        let appObserver = appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
        notificationObservers.append((appCenter, appObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
        notificationObservers.append((workspaceCenter, wakeObserver))

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "jp.local.AstroberryVNC.network-monitor"))
    }
    private func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// Keep the enforcement decision centralized so unit tests exercise the same
// decision path used by Connect, rather than a separate copy of the policy.
enum VNCBindingSafetyGate {
    static func connectionFailure(for binding: VNCBindingState, remotePort: Int) -> ConnectionFailure? {
        switch binding {
        case .loopbackOnly: nil
        case .unsafe(let address): .unsafeVNCBinding(address)
        case .unconfirmed(let reason): .unconfirmedVNCBinding(reason, remotePort)
        }
    }
}

enum ConnectionFailure: LocalizedError {
    case portInUse, tunnelVerificationFailed, viewerMissing, noLocalPort, hostKeyApprovalRequired, hostKeyChanged
    case invalidSettings(String)
    case sshFailed(String), viewerLaunchFailed(String), unsafeVNCBinding(String), unconfirmedVNCBinding(String, Int)
    var errorDescription: String? {
        switch self {
        case .portInUse: "Mac port 5901 is already in use by another process. Nothing was changed."
        case .sshFailed(let message): "SSH could not connect to the selected VNC server. \(message)"
        case .tunnelVerificationFailed: "SSH started, but the local VNC tunnel did not become ready."
        case .viewerMissing: "TigerVNC was not found at /Applications/TigerVNC.app."
        case .viewerLaunchFailed(let message): "TigerVNC could not be opened. \(message)"
        case .invalidSettings(let detail): "The selected server configuration is invalid. \(detail)"
        case .noLocalPort: "No free loopback port could be allocated on this Mac."
        case .hostKeyApprovalRequired: "The SSH host key is not trusted yet. Open Settings, check its fingerprint, and explicitly approve it."
        case .hostKeyChanged: "The SSH host key changed. Connection is blocked; verify the server through another trusted channel."
        case .unsafeVNCBinding(let address): "VNC is listening on a non-loopback address (\(address)). Connection was blocked. Bind TigerVNC only to a loopback address."
        case .unconfirmedVNCBinding(let reason, let port): "Could not confirm that VNC listens only on loopback; connection was blocked. \(reason) Check the Pi with: ss -ltnH sport = :\(port)."
        }
    }
}
