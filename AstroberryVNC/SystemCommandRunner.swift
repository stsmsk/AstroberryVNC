// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Darwin
import Foundation

// Bounded collection prevents a verbose child from growing app memory without limit.
// Continue draining even after the storage limit is reached to avoid pipe deadlock.
private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false
    private let limit = 1_048_576

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, limit - bytes.count)
        if chunk.count > available { truncated = true }
        if available > 0 { bytes.append(chunk.prefix(available)) }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = String(decoding: bytes, as: UTF8.self)
        return truncated ? value + "\n[Output truncated after 1 MiB]" : value
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
    let error: String
    var readableError: String {
        let errorText = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty { return errorText }
        let outputText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return outputText.isEmpty ? "Exit code \(exitCode)." : outputText
    }
}

struct KeyInspection {
    let publicKey: String
    let fingerprint: String
}

struct HostKeyScan {
    let lines: [String]
    let fingerprints: [String]
    let state: HostKeyState
}

enum HostKeyState: Equatable { case trusted, approvalRequired, changed }
// Only application Quit uses the bounded probe below. Unknown means the
// local control command failed or timed out: never assume SSH has stopped.
enum QuitResourceState: Equatable {
    case stopped
    case running
    case unknown(String)
}

enum VNCBindingState: Equatable { case loopbackOnly, unsafe(String), unconfirmed(String) }

// Viewer ownership is the NSRunningApplication returned by NSWorkspace,
// retained only for the lifetime of this application. Never recover a Viewer
// from a persisted PID or a process-list/command-line guess after a crash.
enum ViewerLaunchPolicy {
    static func arguments(localPort: Int) -> [String]? {
        guard (1...65535).contains(localPort) else { return nil }
        return ["-SecurityTypes=None", "-ReconnectOnError=0", "127.0.0.1::\(localPort)"]
    }

    static func resourceState(isTerminated: Bool?) -> QuitResourceState {
        guard let isTerminated else { return .stopped }
        return isTerminated ? .stopped : .running
    }
}


// Only the explicit application Quit workflow may escalate to a force quit.
// Normal Disconnect and connection rollback stay graceful.
enum ViewerTerminationPolicy {
    static func shouldForceTerminate(forceIfNeeded: Bool, isTerminated: Bool) -> Bool {
        forceIfNeeded && !isTerminated
    }
}

// Interpret every TCP LISTEN entry from Linux `ss -ltnH sport = :PORT`.
// A single non-loopback listener makes the port unsafe even if other entries
// are loopback. Unknown or truncated output must NEVER be treated as safe.
enum RemoteVNCBindingInspector {
    static func inspect(output: String, port: Int) -> VNCBindingState {
        guard (1...65535).contains(port) else { return .unconfirmed("Invalid TCP port: \(port).") }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .unconfirmed("No listener was found on TCP \(port).") }

        var uncertain: [String] = []
        var verified = 0
        var unsafeAddress: String?
        for line in lines {
            guard let endpoint = localEndpoint(in: line, port: port) else {
                // Includes command banners, headers, malformed rows, wrong
                // ports and the command runner's output-truncation marker.
                uncertain.append("Unrecognized listener entry: \(String(line.prefix(160)))")
                continue
            }
            switch classify(endpoint.host) {
            case .loopback:
                verified += 1
            case .nonLoopback:
                if unsafeAddress == nil { unsafeAddress = endpoint.display }
            case .unknown:
                uncertain.append("Could not classify listener address: \(endpoint.display)")
            }
        }
        // Prefer a definite unsafe finding over a separate malformed entry.
        if let unsafeAddress { return .unsafe(unsafeAddress) }
        if !uncertain.isEmpty {
            let suffix = uncertain.count > 1 ? " (and \(uncertain.count - 1) additional unverified entries)" : ""
            return .unconfirmed(uncertain[0] + suffix)
        }
        return verified > 0 ? .loopbackOnly : .unconfirmed("No verifiable TCP \(port) listener.")
    }

    private struct Endpoint {
        let host: String
        let display: String
    }
    private enum AddressClass { case loopback, nonLoopback, unknown }

    private static func localEndpoint(in line: String, port: Int) -> Endpoint? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // `ss -ltnH`: LISTEN Recv-Q Send-Q Local Peer
        // Accept the optional `tcp` / `tcp6` Netid prefix, if present.
        let stateIndex: Int
        if parts.first == "LISTEN" { stateIndex = 0 }
        else if parts.count > 1 && ["tcp", "tcp6"].contains(parts[0]) && parts[1] == "LISTEN" {
            stateIndex = 1
        } else { return nil }
        guard parts.count >= stateIndex + 5,
              UInt64(parts[stateIndex + 1]) != nil,
              UInt64(parts[stateIndex + 2]) != nil else { return nil }
        let display = parts[stateIndex + 3]
        guard let colon = display.lastIndex(of: ":"),
              let foundPort = Int(display[display.index(after: colon)...]),
              foundPort == port else { return nil }
        var host = String(display[..<colon])
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return nil }
            host.removeFirst(); host.removeLast()
        } else if host.contains("[") || host.contains("]") { return nil }
        guard !host.isEmpty else { return nil }
        return Endpoint(host: host, display: display)
    }

    private static func classify(_ host: String) -> AddressClass {
        if host == "*" { return .nonLoopback }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            // Every 127/8 IPv4 address is loopback, not just 127.0.0.1.
            return withUnsafeBytes(of: &v4) { $0[0] == 127 } ? .loopback : .nonLoopback
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: &v6) { bytes in
                bytes.count == 16 && bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            } ? .loopback : .nonLoopback
        }
        // Never infer safety from an unknown hostname or address format.
        return .unknown
    }
}


// An encrypted identity may already be unlocked in the user's login ssh-agent.
// No passphrase or authentication secret is persisted in the app preferences.
enum SSHKeyUnlockState: Equatable {
    case ready
    case needsPassphrase
    case unusable(String)
}

// Protection is a property of the private-key FILE, not the current ssh-agent
// state. An encrypted key remains protected even while unlocked in ssh-agent.
enum SSHPrivateKeyProtectionState: Equatable {
    case unprotected
    case protected
    case unavailable(String)
}

// Agent registration is different from on-disk passphrase protection.
// For example, a protected key can still be ready to connect without a prompt.
enum SSHAgentKeyState: Equatable {
    case loaded
    case notLoaded
    case unavailable(String)
}


final class SystemCommandRunner: @unchecked Sendable {
    // Tests can supply an isolated agent socket without touching the user's
    // login agent. Production uses the user's existing launchd SSH agent.
    private let agentEnvironmentOverrides: [String: String]

    init(agentEnvironmentOverrides: [String: String] = [:]) {
        self.agentEnvironmentOverrides = agentEnvironmentOverrides
    }

    private func agentEnvironment() -> [String: String] {
        if !agentEnvironmentOverrides.isEmpty { return agentEnvironmentOverrides }
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !sock.isEmpty, FileManager.default.fileExists(atPath: sock) { return [:] }
        // Finder-launched menu-bar apps may not inherit the same SSH_AUTH_SOCK
        // environment as Terminal. Read launchd's user-level agent socket.
        let result = runSync("/bin/launchctl", ["getenv", "SSH_AUTH_SOCK"], input: nil)
        let socket = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && socket.hasPrefix("/") ? ["SSH_AUTH_SOCK": socket] : [:]
    }
    static func localForwardListenerArguments(port: Int) -> [String] {
        ["-nP", "-a", "-c", "ssh", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-Fp"]
    }

    func scanHostKeys(host: String, port: Int, timeout: Int) async -> Result<HostKeyScan, Error> {
        let scanTimeout = min(timeout, 4)
        async let ed25519 = run("/usr/bin/ssh-keyscan", ["-T", String(scanTimeout), "-t", "ed25519", "-p", String(port), host])
        async let ecdsa = run("/usr/bin/ssh-keyscan", ["-T", String(scanTimeout), "-t", "ecdsa", "-p", String(port), host])
        async let rsa = run("/usr/bin/ssh-keyscan", ["-T", String(scanTimeout), "-t", "rsa", "-p", String(port), host])
        let scans = await [ed25519, ecdsa, rsa]
        let lines = scans.flatMap { result in
            result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        }
        guard !lines.isEmpty else {
            let detail = scans.map(\.readableError).joined(separator: " ")
            return .failure(HostKeyError.scanFailed(detail))
        }
        var fingerprints: [String] = []
        for line in lines {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 3 else { continue }
            let key = fields[1] + " " + fields[2] + "\n"
            let fp = await runWithInput("/usr/bin/ssh-keygen", ["-lf", "-", "-E", "sha256"], input: key)
            if fp.exitCode == 0 { fingerprints.append(fp.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let knownHosts = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
        let token = port == 22 ? host : "[\(host)]:\(port)"
        let existing = await run("/usr/bin/ssh-keygen", ["-F", token, "-f", knownHosts])
        let existingIDs = Set(existing.output.split(separator: "\n").compactMap { AuthorizedKeyIdentity.parse(String($0)) })
        let scannedIDs = Set(lines.compactMap(AuthorizedKeyIdentity.parse))
        let state: HostKeyState = existingIDs.isEmpty ? .approvalRequired : (existingIDs.isDisjoint(with: scannedIDs) ? .changed : .trusted)
        return .success(HostKeyScan(lines: lines, fingerprints: fingerprints, state: state))
    }

    func knownHostEntryExists(host: String, port: Int) async -> Bool {
        let knownHosts = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
        let token = port == 22 ? host : "[\(host)]:\(port)"
        let result = await run("/usr/bin/ssh-keygen", ["-F", token, "-f", knownHosts])
        return result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isHostKeyMismatch(_ result: CommandResult) -> Bool {
        let detail = (result.error + "\n" + result.output).uppercased()
        return detail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || detail.contains("HOST KEY VERIFICATION FAILED")
    }

    func trustHostKeys(_ lines: [String]) -> CommandResult {
        let directory = NSString(string: "~/.ssh").expandingTildeInPath
        let path = directory + "/known_hosts"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            var updated = existing
            for line in lines where !updated.split(separator: "\n").contains(Substring(line)) {
                updated += (updated.isEmpty || updated.hasSuffix("\n") ? "" : "\n") + line + "\n"
            }
            let temporary = path + ".astroberry-\(UUID().uuidString).tmp"
            try updated.write(toFile: temporary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            } else { try FileManager.default.moveItem(atPath: temporary, toPath: path) }
            return CommandResult(exitCode: 0, output: "", error: "")
        } catch { return CommandResult(exitCode: 1, output: "", error: error.localizedDescription) }
    }
    func socketPath(profileID: UUID) -> String {
        NSString(string: "~/.ssh/astroberry-vnc-\(profileID.uuidString).sock").expandingTildeInPath
    }

    func tunnelIsActive(destination: String, socket: String, sshPort: Int) async -> Bool {
        await run("/usr/bin/ssh", ["-4", "-p", String(sshPort), "-S", socket, "-O", "check", destination]).exitCode == 0
    }

    func localForwardListenerExists(_ port: Int) async -> Bool {
        let result = await run(
            "/usr/sbin/lsof",
            Self.localForwardListenerArguments(port: port)
        )
        return result.exitCode == 0 && result.output.split(separator: "\n").contains { $0.hasPrefix("p") }
    }

    func allocateLoopbackPort() -> Int? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        return readResult == 0 ? Int(UInt16(bigEndian: bound.sin_port)) : nil
    }

    func inspectKey(path: String) async -> Result<KeyInspection, Error> {
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: expanded)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw KeyError.notRegularFile }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard permissions & 0o077 == 0 else { throw KeyError.insecurePermissions(permissions) }
        } catch let error as KeyError { return .failure(error) }
        catch { return .failure(KeyError.missing(error.localizedDescription)) }

        // -P "" makes this check strictly noninteractive. For an encrypted
        // private key, use its public half; do not accidentally trigger a TTY
        // password prompt in the background. Its match is verified by ssh-add
        // when an encrypted key is unlocked for actual authentication.
        let derived = await run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", expanded])
        let publicKey: String
        if derived.exitCode == 0 {
            let derivedKey = derived.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let savedKey = readPublicKey(path: expanded) {
                guard AuthorizedKeyIdentity.parse(savedKey) == AuthorizedKeyIdentity.parse(derivedKey),
                      AuthorizedPublicKeyLine.normalized(savedKey) != nil else {
                    return .failure(KeyError.invalid("The public key does not match the selected private key."))
                }
                // ssh-keygen -y may omit the .pub comment. Prefer the
                // verified .pub line when registering the key remotely.
                publicKey = savedKey
            } else {
                publicKey = derivedKey
            }
        } else if let savedKey = readPublicKey(path: expanded) {
            publicKey = savedKey
        } else {
            return .failure(KeyError.invalid("The private key needs a passphrase, but the .pub file is missing. Restore or rebuild its public key first."))
        }
        guard AuthorizedKeyIdentity.parse(publicKey)?.type == "ssh-ed25519",
              AuthorizedPublicKeyLine.normalized(publicKey) != nil else { return .failure(KeyError.notED25519) }
        let fingerprintResult = await runWithInput("/usr/bin/ssh-keygen", ["-lf", "-", "-E", "sha256"], input: publicKey + "\n")
        guard fingerprintResult.exitCode == 0 else { return .failure(KeyError.invalid(fingerprintResult.readableError)) }
        return .success(KeyInspection(publicKey: publicKey, fingerprint: fingerprintResult.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func privateKeyProtectionState(path: String) async -> SSHPrivateKeyProtectionState {
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: expanded)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .unavailable("The private key is not a regular file.")
            }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard permissions & 0o077 == 0 else {
                return .unavailable("Private key permissions must be 600.")
            }
        } catch { return .unavailable("Private key not found or unreadable.") }
        let unencrypted = await run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", expanded])
        if unencrypted.exitCode == 0 { return .unprotected }
        // A failed decryption alone is not enough to establish that a key is
        // encrypted: reject non-OpenSSH files instead of offering destructive
        // passphrase operations on corrupt input.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let header = String(data: data.prefix(80), encoding: .utf8),
              header.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            return .unavailable("The file is not a valid OpenSSH private-key container.")
        }
        return .protected
    }

    func agentKeyState(path: String) async -> SSHAgentKeyState {
        await agentKeyState(path: path, environment: agentEnvironment())
    }

    private func agentKeyState(path: String, environment: [String: String]) async -> SSHAgentKeyState {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let publicKey = readPublicKey(path: expanded),
              let identity = AuthorizedKeyIdentity.parse(publicKey) else {
            return .unavailable("The corresponding .pub file is missing or invalid.")
        }
        let result = await run("/usr/bin/ssh-add", ["-L"], environment: environment)
        if result.exitCode == 0 {
            let loaded = result.output.split(separator: "\n").contains {
                AuthorizedKeyIdentity.parse(String($0)) == identity
            }
            return loaded ? .loaded : .notLoaded
        }
        // OpenSSH returns 1 when the agent is reachable but has no identities.
        if result.exitCode == 1, result.readableError.lowercased().contains("no identities") {
            return .notLoaded
        }
        return .unavailable("Could not query ssh-agent: \(result.readableError)")
    }

    private func agentHasPublicKey(path: String, environment: [String: String]) async -> Bool {
        await agentKeyState(path: path, environment: environment) == .loaded
    }

    func keyUnlockState(path: String) async -> SSHKeyUnlockState {
        let expanded = NSString(string: path).expandingTildeInPath
        switch await privateKeyProtectionState(path: expanded) {
        case .unprotected: return .ready
        case .unavailable(let reason): return .unusable(reason)
        case .protected: break
        }
        guard readPublicKey(path: expanded) != nil else {
            return .unusable("The encrypted private key has no matching .pub file.")
        }
        return await agentHasPublicKey(path: expanded, environment: agentEnvironment())
            ? .ready : .needsPassphrase
    }

    func unlockKeyInAgent(path: String, passphrase: String) async -> CommandResult {
        guard !passphrase.isEmpty, !passphrase.contains("\n"), !passphrase.contains("\r") else {
            return CommandResult(exitCode: 1, output: "", error: "A nonempty passphrase without line breaks is required.")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        // Use the same glob-style prompt recognition as the working
        // ssh-keygen passphrase-change flow. Do not put the secret in argv,
        // the Tcl script, environment, a file, or diagnostic output.
        let script = #"""
set timeout 15
log_user 0
set p $env(ASTROBERRY_KEY_PATH)
gets stdin secret
set attempts 0
spawn /usr/bin/ssh-add -q $p
expect {
    -nocase "*enter passphrase for*:*" {
        incr attempts
        if {$attempts > 1} { puts stderr "Incorrect SSH key passphrase."; exit 23 }
        send -- "$secret\r"
        exp_continue
    }
    -nocase "*bad passphrase*" { puts stderr "Incorrect SSH key passphrase."; exit 23 }
    -nocase "*incorrect passphrase*" { puts stderr "Incorrect SSH key passphrase."; exit 23 }
    eof { set result [wait]; exit [lindex $result 3] }
    timeout { puts stderr "Timed out waiting for the ssh-add passphrase prompt."; exit 24 }
}
"""#
        let environment = agentEnvironment().merging([
            "ASTROBERRY_KEY_PATH": expanded, "SSH_ASKPASS_REQUIRE": "never"
        ]) { _, new in new }
        let result = await runWithInput(
            "/usr/bin/expect", ["-c", script], input: passphrase + "\n", environment: environment
        )
        guard result.exitCode == 0 else { return result }
        guard await agentHasPublicKey(path: expanded, environment: environment) else {
            return CommandResult(
                exitCode: 27, output: "",
                error: "ssh-add exited successfully but the expected key was not found in ssh-agent."
            )
        }
        return result
    }

    func changeKeyPassphrase(path: String, current: String, replacement: String) async -> CommandResult {
        guard !current.contains("\n"), !current.contains("\r"),
              !replacement.contains("\n"), !replacement.contains("\r") else {
            return CommandResult(exitCode: 1, output: "", error: "Passphrases cannot contain line breaks.")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        // An unencrypted key has no old passphrase to authenticate. Reject a
        // nonempty value rather than silently accepting arbitrary input.
        // A protected key must have its current passphrase verified by ssh-keygen.
        switch await privateKeyProtectionState(path: expanded) {
        case .unprotected:
            guard current.isEmpty, !replacement.isEmpty else {
                return CommandResult(exitCode: 1, output: "", error: "Use Set Passphrase with an empty current passphrase for an unprotected key.")
            }
        case .protected:
            guard !current.isEmpty else {
                return CommandResult(exitCode: 1, output: "", error: "The current key passphrase is required.")
            }
        case .unavailable(let reason):
            return CommandResult(exitCode: 1, output: "", error: reason)
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: expanded)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                return CommandResult(exitCode: 1, output: "", error: "Only a regular private key file can be changed.")
            }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard perms & 0o077 == 0 else {
                return CommandResult(exitCode: 1, output: "", error: "Private key permissions must be 600.")
            }
        } catch { return CommandResult(exitCode: 1, output: "", error: error.localizedDescription) }
        // Use the same glob-style prompt matching as successful key creation.
        // ssh-keygen prompts may differ when changing a protected vs. an
        // unprotected key; the old-passphrase prompt is optional.  Keep the
        // secret on the private stdin pipe, never in argv or the Tcl source.
        let script = #"""
set timeout 15
log_user 0
set p $env(ASTROBERRY_KEY_PATH)
gets stdin oldSecret
gets stdin newSecret
set stage "initial passphrase prompt"
set sawOld 0
set sawNew 0
set sawConfirm 0
spawn /usr/bin/ssh-keygen -p -a 100 -f $p
expect {
    "*old passphrase*:*" {
        if {$sawOld} { puts stderr "Repeated old-passphrase prompt; original passphrase rejected."; exit 25 }
        set sawOld 1
        set stage "new-passphrase prompt"
        send -- "$oldSecret\r"
        exp_continue
    }
    "*new passphrase*:*" {
        if {$sawNew} { puts stderr "Repeated new-passphrase prompt."; exit 25 }
        set sawNew 1
        set stage "confirmation prompt"
        send -- "$newSecret\r"
        exp_continue
    }
    "*same passphrase again*:*" {
        if {$sawConfirm} { puts stderr "Repeated confirmation prompt."; exit 25 }
        set sawConfirm 1
        set stage "ssh-keygen completion"
        send -- "$newSecret\r"
        exp_continue
    }
    eof {
        set result [wait]
        set code [lindex $result 3]
        if {$code == 0 && !$sawConfirm} {
            puts stderr "ssh-keygen exited without confirming the new passphrase."
            exit 26
        }
        exit $code
    }
    timeout { puts stderr "Timed out waiting for $stage."; exit 24 }
}
"""#
        let result = await runWithInput(
            "/usr/bin/expect", ["-c", script], input: current + "\n" + replacement + "\n",
            environment: ["ASTROBERRY_KEY_PATH": expanded]
        )
        if result.exitCode == 0 {
            // Forget a previously decrypted copy. The next connection must
            // unlock using the new passphrase (or proceed without one).
            _ = await removeKeyFromAgent(path: expanded)
        }
        return result
    }

    func startTunnel(
        destination: String, sshPort: Int, keyPath: String, socket: String,
        localPort: Int, remoteHost: String, remotePort: Int, timeout: Int
    ) async -> CommandResult {
        let key = NSString(string: keyPath).expandingTildeInPath
        return await run("/usr/bin/ssh", [
            "-4", "-M", "-S", socket, "-fnNT", "-p", String(sshPort),
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)", "-i", key,
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)",
            "-o", "ExitOnForwardFailure=yes", "-o", "ControlPersist=no",
            "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "StrictHostKeyChecking=yes", destination
        ])
    }

    func testPublicKey(destination: String, sshPort: Int, keyPath: String, timeout: Int) async -> CommandResult {
        await run("/usr/bin/ssh", [
            "-4", "-p", String(sshPort), "-i", NSString(string: keyPath).expandingTildeInPath,
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            destination, "printf", "ASTROBERRY_KEY_OK"
        ])
    }

    func inspectRemoteVNCBinding(
        destination: String, sshPort: Int, socket: String, remotePort: Int, timeout: Int
    ) async -> VNCBindingState {
        let result = await run("/usr/bin/ssh", [
            "-4", "-p", String(sshPort), "-S", socket, "-o", "ControlMaster=no",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            destination, "ss", "-ltnH", "sport", "=", ":\(remotePort)"
        ])
        guard result.exitCode == 0 else { return .unconfirmed(result.readableError) }
        return RemoteVNCBindingInspector.inspect(output: result.output, port: remotePort)
    }

    func registerPublicKey(
        destination: String, sshPort: Int, password: String, publicKey: String, timeout: Int
    ) async -> CommandResult {
        guard AuthorizedKeyIdentity.parse(publicKey) != nil else {
            return CommandResult(exitCode: 1, output: "", error: "The local public key is invalid.")
        }
        // Preserve the .pub comment when a new authorized_keys line is added.
        // Identity comparisons on the Pi still ignore comments, so existing
        // lines (including restrictive options) are never rewritten.
        guard let normalized = AuthorizedPublicKeyLine.normalized(publicKey) else {
            return CommandResult(exitCode: 1, output: "", error: "The public key contains an invalid line or comment.")
        }
        let encoded = Data(normalized.utf8).base64EncodedString()
        let remoteScript = #"""
set -eu
umask 077
d="$HOME/.ssh"
f="$d/authorized_keys"
lock="$d/.astroberry-authorized-keys.lock"
fail() { printf 'ASTROBERRY_REG_ERROR: %s\n' "$1" >&2; exit "$2"; }
me=$(id -u)
if [ -e "$d" ]; then
  [ -d "$d" ] && [ ! -L "$d" ] || fail '.ssh is not a real directory' 41
  [ "$(stat -c %u "$d")" = "$me" ] || fail '.ssh has a different owner' 41
else
  mkdir "$d" || fail 'could not create .ssh' 41
fi
chmod 700 "$d"
if [ -e "$f" ]; then
  [ -f "$f" ] && [ ! -L "$f" ] || fail 'authorized_keys is not a regular file' 42
  [ "$(stat -c %u "$f")" = "$me" ] || fail 'authorized_keys has a different owner' 42
  perm=$(stat -c %a "$f") || fail 'could not inspect authorized_keys permissions' 43
  case "$perm" in *[1-7][0-7]|*[0-7][1-7]) fail 'authorized_keys has unsafe permissions' 43;; esac
else touch "$f"; fi
chmod 600 "$f"
if ! mkdir "$lock" 2>/dev/null; then
  lock_time=$(stat -c %Y "$lock" 2>/dev/null || printf '0')
  now=$(date +%s)
  if [ "$lock_time" -gt 0 ] && [ $((now - lock_time)) -gt 60 ] && rmdir "$lock" 2>/dev/null; then
    mkdir "$lock" 2>/dev/null || fail 'another key registration started concurrently' 44
  else
    fail 'another key registration is already running; retry after one minute' 44
  fi
fi
tmp=$(mktemp "$d/.authorized_keys.XXXXXX")
trap 'rm -f "$tmp"; rmdir "$lock"' EXIT HUP INT TERM
cp "$f" "$tmp"
key=$(printf '%s' 'KEY_BASE64' | base64 -d)
# Only the key type and base64 identity matter. Parse them without shell
# word expansion so free-form comments cannot expand wildcards on the server.
kt=${key%% *}
rest=${key#* }
kb=${rest%% *}
[ "$kt" != "$key" ] && [ -n "$kb" ] || fail 'the transferred public key could not be decoded' 45
if awk -v t="$kt" -v b="$kb" '{for(i=1;i<NF;i++) if($i==t && $(i+1)==b) found=1} END{exit found?0:1}' "$f"; then
  printf 'ALREADY_REGISTERED\n'
else
  printf '%s\n' "$key" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
  tmp="$d/.authorized_keys.finished"
  awk -v t="$kt" -v b="$kb" '{for(i=1;i<NF;i++) if($i==t && $(i+1)==b) found=1} END{exit found?0:1}' "$f"
  printf 'REGISTERED\n'
fi
"""#.replacingOccurrences(of: "KEY_BASE64", with: encoded)
        let expectScript = #"""
set timeout $env(ASTROBERRY_EXPECT_TIMEOUT)
set port $env(ASTROBERRY_EXPECT_PORT)
set dest $env(ASTROBERRY_EXPECT_DESTINATION)
set encodedScript $env(ASTROBERRY_REMOTE_SCRIPT_BASE64)
set remoteCommand "printf '%s' '$encodedScript' | base64 -d | sh"
gets stdin secret
log_user 0
spawn /usr/bin/ssh -4 -T -p $port -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o NumberOfPasswordPrompts=1 $dest $remoteCommand
set sentPassword 0
set registrationMessage ""
expect {
  -re "(?i)password:" {
    if {$sentPassword} {
      puts stderr "SSH login password was rejected."
      exit 72
    }
    set sentPassword 1
    send -- "$secret\r"
    exp_continue
  }
  -re "(?i)permission denied" {
    puts stderr "SSH login password was rejected."
    exit 72
  }
  -re {ASTROBERRY_REG_ERROR: [^\r\n]*} {
    set registrationMessage $expect_out(0,string)
    exp_continue
  }
  -re {ALREADY_REGISTERED|REGISTERED} {
    set registrationMessage $expect_out(0,string)
    exp_continue
  }
  timeout {
    if {$sentPassword} {
      puts stderr "Timed out while updating authorized_keys."
      exit 73
    } else {
      puts stderr "Timed out while authenticating to the SSH server."
      exit 70
    }
  }
  eof {}
}
set r [wait]
set code [lindex $r 3]
if {$registrationMessage ne ""} {
  if {$code == 0} { puts stdout $registrationMessage } else { puts stderr $registrationMessage }
}
if {$code != 0 && $registrationMessage eq ""} {
  puts stderr "The SSH server could not update authorized_keys (exit code $code)."
}
exit $code
"""#
        return await runWithInput(
            "/usr/bin/expect", ["-c", expectScript],
            input: password + "\n",
            environment: [
                "ASTROBERRY_EXPECT_TIMEOUT": String(timeout),
                "ASTROBERRY_EXPECT_PORT": String(sshPort),
                "ASTROBERRY_EXPECT_DESTINATION": destination,
                "ASTROBERRY_REMOTE_SCRIPT_BASE64": Data(remoteScript.utf8).base64EncodedString()
            ]
        )
    }

    func removeKeyFromAgent(path: String) async -> CommandResult {
        let expanded = NSString(string: path).expandingTildeInPath
        return await run("/usr/bin/ssh-add", ["-d", expanded], environment: agentEnvironment())
    }

    // Explicit menu Quit only, after app-owned SSH/VNC resources have stopped.
    // Never use ssh-add -D or depend on a mutable .pub file during cleanup.
    // Query the agent by immutable identity recorded at successful Connect,
    // then remove that single identity via stdin (-d -) when present.
    func removeRecordedKeyFromAgentForQuit(_ recorded: SSHAgentUsedKey) async -> String? {
        let environment = agentEnvironment()
        func currentState() async -> SSHAgentKeyState {
            let listing = await run(
                "/usr/bin/ssh-add", ["-L"], environment: environment, timeout: 5
            )
            return SSHAgentQuitKeyPolicy.agentIdentityState(
                recorded: recorded, exitCode: listing.exitCode,
                output: listing.output, error: listing.error
            )
        }

        switch await currentState() {
        case .notLoaded:
            return nil // Nothing to remove, even if the .pub file is absent.
        case .unavailable(let reason):
            return "Could not verify SSH agent identity for \(recorded.path): \(reason)"
        case .loaded:
            break
        }

        let result = await runWithInput(
            "/usr/bin/ssh-add", ["-d", "-"],
            input: SSHAgentQuitKeyPolicy.removalInput(for: recorded),
            environment: environment, timeout: 5
        )
        // A nonzero result can mean another actor already removed the key.
        // Success is decided by a fresh exact-identity check, not exit code.
        switch await currentState() {
        case .notLoaded:
            return nil
        case .loaded:
            return "The SSH identity for \(recorded.path) is still loaded: \(result.readableError)"
        case .unavailable(let reason):
            return "Could not verify SSH agent removal for \(recorded.path): \(reason)"
        }
    }

    func removeRemotePublicKey(
        destination: String, sshPort: Int, keyPath: String, publicKey: String, timeout: Int
    ) async -> CommandResult {
        guard let identity = AuthorizedKeyIdentity.parse(publicKey) else {
            return CommandResult(exitCode: 1, output: "", error: "The local public key is invalid.")
        }
        let normalized = "\(identity.type) \(identity.body)"
        let encodedKey = Data(normalized.utf8).base64EncodedString()
        let remoteScript = #"""
set -eu
umask 077
d="$HOME/.ssh"
f="$d/authorized_keys"
lock="$d/.astroberry-authorized-keys.lock"
fail() { printf 'ASTROBERRY_REMOVE_ERROR: %s\n' "$1" >&2; exit "$2"; }
me=$(id -u)
[ -d "$d" ] && [ ! -L "$d" ] || fail '.ssh is not a real directory' 41
[ "$(stat -c %u "$d")" = "$me" ] || fail '.ssh has a different owner' 41
[ -f "$f" ] && [ ! -L "$f" ] || fail 'authorized_keys is not a regular file' 42
[ "$(stat -c %u "$f")" = "$me" ] || fail 'authorized_keys has a different owner' 42
perm=$(stat -c %a "$f") || fail 'could not inspect authorized_keys permissions' 43
case "$perm" in *[1-7][0-7]|*[0-7][1-7]) fail 'authorized_keys has unsafe permissions' 43;; esac
if ! mkdir "$lock" 2>/dev/null; then
  lock_time=$(stat -c %Y "$lock" 2>/dev/null || printf '0')
  now=$(date +%s)
  if [ "$lock_time" -gt 0 ] && [ $((now - lock_time)) -gt 60 ] && rmdir "$lock" 2>/dev/null; then
    mkdir "$lock" 2>/dev/null || fail 'another key update started concurrently' 44
  else
    fail 'another key update is already running; retry after one minute' 44
  fi
fi
tmp=$(mktemp "$d/.authorized_keys.XXXXXX")
trap 'rm -f "$tmp"; rmdir "$lock"' EXIT HUP INT TERM
key=$(printf '%s' 'KEY_BASE64' | base64 -d)
set -- $key
[ "$#" -ge 2 ] || fail 'the public key could not be decoded' 45
kt=$1; kb=$2
if awk -v t="$kt" -v b="$kb" '{for(i=1;i<NF;i++) if($i==t && $(i+1)==b) found=1} END{exit found?0:1}' "$f"; then
  awk -v t="$kt" -v b="$kb" '{remove=0; for(i=1;i<NF;i++) if($i==t && $(i+1)==b) remove=1; if(!remove) print $0}' "$f" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
  tmp="$d/.authorized_keys.finished"
  if awk -v t="$kt" -v b="$kb" '{for(i=1;i<NF;i++) if($i==t && $(i+1)==b) found=1} END{exit found?0:1}' "$f"; then
    fail 'the target key remained after updating authorized_keys' 46
  fi
  printf 'REMOTE_KEY_REMOVED\n'
else
  printf 'REMOTE_KEY_NOT_PRESENT\n'
fi
"""#.replacingOccurrences(of: "KEY_BASE64", with: encodedKey)
        let encodedScript = Data(remoteScript.utf8).base64EncodedString()
        let remoteCommand = "printf '%s' '\(encodedScript)' | base64 -d | sh"
        return await run("/usr/bin/ssh", [
            "-4", "-p", String(sshPort), "-i", NSString(string: keyPath).expandingTildeInPath,
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            destination, remoteCommand
        ])
    }

    func trashLocalKeyPair(path: String) -> CommandResult {
        let privatePath = NSString(string: path).expandingTildeInPath
        let paths = [privatePath, privatePath + ".pub"]
        let fileManager = FileManager.default
        let existing = paths.filter { fileManager.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            return CommandResult(exitCode: 1, output: "", error: "The local key pair no longer exists.")
        }
        do {
            for item in existing {
                let attributes = try fileManager.attributesOfItem(atPath: item)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    return CommandResult(exitCode: 1, output: "", error: "Refused to remove a non-regular key path: \(item)")
                }
            }
            for item in existing {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: URL(fileURLWithPath: item), resultingItemURL: &resultingURL)
            }
            return CommandResult(exitCode: 0, output: "LOCAL_KEY_MOVED_TO_TRASH", error: "")
        } catch {
            return CommandResult(exitCode: 1, output: "", error: "Could not move the key pair to Trash: \(error.localizedDescription)")
        }
    }

    // Application Quit must not rely on a two-second blind exit. Use bounded
    // local SSH ControlMaster commands; check the result after requesting exit.
    func requestTunnelExitForQuit(destination: String, socket: String, sshPort: Int) async -> CommandResult {
        await run("/usr/bin/ssh", ["-4", "-p", String(sshPort), "-S", socket,
                                   "-O", "exit", destination], timeout: 8)
    }

    func tunnelStateForQuit(destination: String, socket: String, sshPort: Int) async -> QuitResourceState {
        let result = await run("/usr/bin/ssh", ["-4", "-p", String(sshPort), "-S", socket,
                                             "-O", "check", destination], timeout: 4)
        if result.exitCode == 124 || result.exitCode == -1 {
            return .unknown("SSH control socket check: \(result.readableError)")
        }
        return result.exitCode == 0 ? .running : .stopped
    }

    func forwardingStateForQuit(localPort: Int) async -> QuitResourceState {
        let result = await run("/usr/sbin/lsof", Self.localForwardListenerArguments(port: localPort), timeout: 4)
        if result.exitCode == 124 || result.exitCode == -1 {
            return .unknown("Local VNC forwarding check: \(result.readableError)")
        }
        if result.exitCode == 1 { return .stopped } // lsof: no matching listener
        if result.exitCode == 0 {
            return result.output.split(separator: "\n").contains { $0.hasPrefix("p") } ? .running : .stopped
        }
        return .unknown("Local VNC forwarding check: \(result.readableError)")
    }

    func stopTunnel(destination: String, socket: String, sshPort: Int) async -> CommandResult {
        guard await tunnelIsActive(destination: destination, socket: socket, sshPort: sshPort) else {
            return CommandResult(exitCode: 0, output: "", error: "")
        }
        return await run("/usr/bin/ssh", ["-4", "-p", String(sshPort), "-S", socket, "-O", "exit", destination])
    }

    func generateSSHKey(path: String, passphrase: String, comment: String) async -> CommandResult {
        guard !passphrase.contains("\n"), !passphrase.contains("\r") else {
            return CommandResult(exitCode: 1, output: "", error: "Passphrases cannot contain line breaks.")
        }
        let expandedPath = NSString(string: path).expandingTildeInPath
        let publicPath = expandedPath + ".pub"
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: expandedPath), !fileManager.fileExists(atPath: publicPath) else {
            return CommandResult(exitCode: 1, output: "", error: "A private or public key already exists at this path. Nothing was overwritten.")
        }
        do {
            try fileManager.createDirectory(
                atPath: URL(fileURLWithPath: expandedPath).deletingLastPathComponent().path,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch { return CommandResult(exitCode: 1, output: "", error: "Could not create the key directory: \(error.localizedDescription)") }

        let script = #"set timeout 30; log_user 0; set p $env(ASTROBERRY_KEY_PATH); set c $env(ASTROBERRY_KEY_COMMENT); gets stdin secret; spawn /usr/bin/ssh-keygen -q -t ed25519 -a 100 -f $p -C $c; expect "Enter passphrase*"; send -- "$secret\r"; expect "Enter same passphrase*"; send -- "$secret\r"; expect eof; set r [wait]; exit [lindex $r 3]"#
        let result = await runWithInput(
            "/usr/bin/expect", ["-c", script], input: passphrase + "\n",
            environment: ["ASTROBERRY_KEY_PATH": expandedPath, "ASTROBERRY_KEY_COMMENT": comment]
        )
        guard result.exitCode == 0 else { return result }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expandedPath)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicPath)
        return result
    }

    func regeneratePublicKey(path: String) async -> CommandResult {
        let expanded = NSString(string: path).expandingTildeInPath
        let result = await run("/usr/bin/ssh-keygen", ["-y", "-f", expanded])
        guard result.exitCode == 0 else { return result }
        do {
            try (result.output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
                .write(toFile: expanded + ".pub", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: expanded + ".pub")
            return CommandResult(exitCode: 0, output: result.output, error: "")
        } catch { return CommandResult(exitCode: 1, output: "", error: error.localizedDescription) }
    }

    func readPublicKey(path: String) -> String? {
        try? String(contentsOfFile: NSString(string: path + ".pub").expandingTildeInPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Launch an independent GUI instance and retain the exact app returned by
    // Launch Services. No /usr/bin/open, pgrep, ps, PID kill, or Viewer patching.
    @MainActor
    func launchViewer(viewerPath: String, localPort: Int) async throws -> NSRunningApplication {
        let url = URL(fileURLWithPath: NSString(string: viewerPath).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConnectionFailure.viewerMissing
        }
        guard let arguments = ViewerLaunchPolicy.arguments(localPort: localPort) else {
            throw ConnectionFailure.viewerLaunchFailed("Invalid local VNC port: \(localPort).")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = arguments
        do {
            return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            throw ConnectionFailure.viewerLaunchFailed(error.localizedDescription)
        }
    }

    @MainActor
    func viewerStateForQuit(application: NSRunningApplication) -> QuitResourceState {
        ViewerLaunchPolicy.resourceState(isTerminated: application.isTerminated)
    }

    @MainActor
    func isExpectedViewer(application: NSRunningApplication) -> Bool {
        !application.isTerminated
    }

    // Gracefully shut down only the exact NSRunningApplication returned by
    // this session's NSWorkspace launch. Explicit menu Quit may escalate when
    // TigerVNC ignores an ordinary termination request. Never discover/kill
    // a Viewer by PID, command line, executable path, or process listing.
    @MainActor
    func terminateViewer(
        application: NSRunningApplication,
        timeout: TimeInterval = 5,
        forceIfNeeded: Bool = false,
        forceTimeout: TimeInterval = 3
    ) async -> QuitResourceState {
        if application.isTerminated { return .stopped }
        _ = application.terminate()
        if await waitForViewerTermination(application: application, timeout: timeout) {
            return .stopped
        }
        guard ViewerTerminationPolicy.shouldForceTerminate(
            forceIfNeeded: forceIfNeeded, isTerminated: application.isTerminated
        ) else { return .running }

        // forceTerminate() still only *requests* termination. The returned
        // Boolean is not proof the process has exited: verify isTerminated.
        _ = application.forceTerminate()
        return await waitForViewerTermination(application: application, timeout: forceTimeout)
            ? .stopped : .running
    }

    @MainActor
    private func waitForViewerTermination(
        application: NSRunningApplication, timeout: TimeInterval
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while !application.isTerminated && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return application.isTerminated
    }

    private func run(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:],
        timeout: TimeInterval = 120
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            Self.executeCommand(executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
    }
    private func runWithInput(
        _ executable: String, _ arguments: [String], input: String,
        environment: [String: String] = [:], timeout: TimeInterval = 120
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            self.runSync(executable, arguments, input: input,
                         environment: environment, timeout: timeout)
        }.value
    }
    private func runSync(
        _ executable: String, _ arguments: [String], input: String?,
        environment: [String: String] = [:], timeout: TimeInterval = 120
    ) -> CommandResult {
        Self.executeCommand(executable, arguments: arguments, input: input,
                            environment: environment, timeout: timeout)
    }

    // SwiftPM tests exercise this common execution path without SSH or VNC.
    // Drain stdout/stderr while the child is running: waiting for the process
    // before reading the pipes can deadlock when either pipe fills up.
    static func executeCommand(
        _ executable: String, arguments: [String], input: String? = nil,
        environment: [String: String] = [:], timeout: TimeInterval = 120
    ) -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = stdout
        process.standardError = stderr
        if input != nil { process.standardInput = stdin }

        let out = CommandOutputBuffer()
        let err = CommandOutputBuffer()
        let reads = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, output: "", error: error.localizedDescription)
        }

        for (handle, buffer) in [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)] {
            reads.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { reads.leave() }
                while true {
                    let data = handle.readData(ofLength: 16_384)
                    if data.isEmpty { break }
                    buffer.append(data)
                }
            }
        }

        if let input {
            // Only fixed, short command input is used here (e.g. one public key).
            // Never include it in diagnostics: it may contain sensitive material.
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = DispatchTime.now() + max(timeout, 0.1)
        let timedOut = terminated.wait(timeout: deadline) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = terminated.wait(timeout: .now() + 2)
            }
        }

        // Usually both drains reach EOF as soon as the child exits. If a
        // descendant inherited a pipe, avoid blocking the caller indefinitely.
        if reads.wait(timeout: .now() + 2) == .timedOut {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            _ = reads.wait(timeout: .now() + 1)
        }

        let resultOut = out.text()
        let resultErr = err.text()
        if timedOut {
            let notice = "Command timed out after \(String(format: "%.1f", timeout)) seconds."
            return CommandResult(exitCode: 124, output: resultOut,
                                 error: resultErr.isEmpty ? notice : resultErr + "\n" + notice)
        }
        return CommandResult(exitCode: process.terminationStatus,
                             output: resultOut, error: resultErr)
    }

}

enum KeyError: LocalizedError {
    case missing(String), notRegularFile, insecurePermissions(UInt16), invalid(String), notED25519
    var errorDescription: String? {
        switch self {
        case .missing(let detail): "Private key is missing or unreadable: \(detail)"
        case .notRegularFile: "The private key path is not a regular file."
        case .insecurePermissions(let mode): "Private key permissions are unsafe (\(String(mode, radix: 8))). Set them to 600."
        case .invalid(let detail): "The private key is invalid or requires an unavailable passphrase: \(detail)"
        case .notED25519: "The selected private key is not an ED25519 key."
        }
    }
}

enum HostKeyError: LocalizedError {
    case scanFailed(String)
    var errorDescription: String? {
        switch self { case .scanFailed(let detail): "Could not obtain the SSH host key: \(detail)" }
    }
}
