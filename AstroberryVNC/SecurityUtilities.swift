// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Build 29.1: a profile holds an explicit key reference. SSH Host is used to
// *suggest* a filename, never as a live lookup for a configured profile.
enum SSHKeyPathPolicy {
    static func proposedName(host: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
        return "id_ed25519_\(normalized.isEmpty ? "new-server.local" : normalized)"
    }

    static func directoryPath(_ directory: String) -> String {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSString(string: value.isEmpty ? "~/.ssh" : value).expandingTildeInPath
    }

    static func proposedPath(host: String, directory: String) -> String {
        (directoryPath(directory) as NSString).appendingPathComponent(proposedName(host: host))
    }

    // Preserve exactly the identity used by Build 29 before its migration.
    // The migration is idempotent, including after the SSH Host is changed.
    static func pinLegacyPaths(_ profiles: [VNCServerProfile], directory: String) -> [VNCServerProfile] {
        profiles.map { profile in
            var pinned = profile
            if pinned.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pinned.privateKeyPath = proposedPath(host: pinned.server, directory: directory)
            }
            return pinned
        }
    }

    static func validFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.hasSuffix(".pub"),
              !name.hasPrefix("."), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func fileOrSymlinkExists(_ path: String, manager: FileManager = .default) -> Bool {
        manager.fileExists(atPath: path) || (try? manager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    static func distinctPath(host: String, directory: String, existing: [String], manager: FileManager = .default) -> String {
        let base = proposedPath(host: host, directory: directory)
        var candidate = base
        var suffix = 2
        func collision(_ path: String) -> Bool {
            existing.contains { sameFilePath($0, path) } ||
            fileOrSymlinkExists(path, manager: manager) ||
            fileOrSymlinkExists(path + ".pub", manager: manager)
        }
        while collision(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func sameFilePath(_ a: String, _ b: String) -> Bool {
        let first = URL(fileURLWithPath: NSString(string: a).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let second = URL(fileURLWithPath: NSString(string: b).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return first == second
    }

    static func replacingReferences(
        in profiles: [VNCServerProfile], profileIDs: Set<UUID>, to destination: String
    ) -> [VNCServerProfile] {
        profiles.map { old in
            var profile = old
            if profileIDs.contains(old.id) { profile.privateKeyPath = destination }
            return profile
        }
    }
}

// Keep the passphrase sheet's Generate enablement independent of mutable
// presenter state. Both empty fields explicitly mean an unencrypted SSH key.
// The destination is carried by PassphraseSheetAction.generate, not a separate
// @State that might be cleared as one SwiftUI sheet dismisses another.
enum SSHKeyGenerationSubmission {
    static func canSubmit(destinationPath: String?, passphrase: String, confirmation: String) -> Bool {
        guard let destinationPath, !destinationPath.isEmpty else { return false }
        return passphrase == confirmation &&
            !passphrase.contains("\n") && !passphrase.contains("\r")
    }
}

// The Generate Key workflow never exposes the Save panel's unsafe Replace
// action. Both private and .pub paths must be unused, and a profile's reserved
// key reference is treated as occupied even when the file has not been made.
enum SSHNewKeyDestinationPolicy {
    enum Validation: Equatable {
        case available, folderUnavailable, emptyName, invalidName, destinationOccupied

        var message: String {
            switch self {
            case .available: "This filename is available."
            case .folderUnavailable: "Choose an existing folder for the new key pair."
            case .emptyName: "Enter a filename for the new SSH key pair."
            case .invalidName: "Invalid filename. Use letters, numbers, dots, dashes or underscores; no .pub suffix or leading dot."
            case .destinationOccupied: "That filename is already used or reserved. Choose another name. No files were changed."
            }
        }
    }

    static func validate(
        directory: String, fileName: String, existing: [String], manager: FileManager = .default
    ) -> Validation {
        // A missing folder must never masquerade as a bad filename. The order
        // is intentional: the old dialog showed the filename help even when no
        // destination folder had been selected.
        let expandedDirectory = NSString(string: directory).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manager.fileExists(atPath: expandedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .folderUnavailable }
        guard !fileName.isEmpty else { return .emptyName }
        guard SSHKeyPathPolicy.validFileName(fileName) else { return .invalidName }
        let path = (expandedDirectory as NSString).appendingPathComponent(fileName)
        guard !SSHKeyPathPolicy.fileOrSymlinkExists(path, manager: manager),
              !SSHKeyPathPolicy.fileOrSymlinkExists(path + ".pub", manager: manager),
              !existing.contains(where: { SSHKeyPathPolicy.sameFilePath($0, path) }) else {
            return .destinationOccupied
        }
        return .available
    }

    static func availableName(
        directory: String, desiredName: String, existing: [String], manager: FileManager = .default
    ) -> String {
        // A manually typed name is preserved as the base for -2, -3, etc.
        let base = SSHKeyPathPolicy.validFileName(desiredName) ? desiredName : "id_ed25519_new"
        var result = base
        var suffix = 2
        while validate(directory: directory, fileName: result, existing: existing, manager: manager) == .destinationOccupied {
            result = "\(base)-\(suffix)"
            suffix += 1
        }
        return result
    }
}

// Only a local filename rename, never a key rotation. Move both halves and
// roll back the first if moving the .pub fails. No contents are rewritten.
enum SSHKeyPairRenamer {
    enum RenameError: LocalizedError {
        case invalidName, missingPair, unsafeSource, destinationExists, sameName, renameFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidName: "Use a filename containing letters, digits, dots, dashes or underscores (no .pub suffix)."
            case .missingPair: "Both the private key and its .pub file must exist before renaming."
            case .unsafeSource: "The key files must be regular files, not symbolic links."
            case .destinationExists: "The new key filename already exists. No files were changed."
            case .sameName: "The new filename is the same as the existing filename."
            case .renameFailed(let detail): detail
            }
        }
    }

    static func rename(path: String, toFileName name: String, manager: FileManager = .default) -> Result<String, Error> {
        guard SSHKeyPathPolicy.validFileName(name) else { return .failure(RenameError.invalidName) }
        let source = NSString(string: path).expandingTildeInPath
        let target = (URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(name)).path
        guard source != target else { return .failure(RenameError.sameName) }
        let oldPublic = source + ".pub"
        let newPublic = target + ".pub"
        for file in [source, oldPublic] {
            guard SSHKeyPathPolicy.fileOrSymlinkExists(file, manager: manager) else { return .failure(RenameError.missingPair) }
            guard let attributes = try? manager.attributesOfItem(atPath: file),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (try? manager.destinationOfSymbolicLink(atPath: file)) == nil else {
                return .failure(RenameError.unsafeSource)
            }
        }
        guard !SSHKeyPathPolicy.fileOrSymlinkExists(target, manager: manager),
              !SSHKeyPathPolicy.fileOrSymlinkExists(newPublic, manager: manager) else {
            return .failure(RenameError.destinationExists)
        }
        do {
            try manager.moveItem(atPath: source, toPath: target)
            do {
                try manager.moveItem(atPath: oldPublic, toPath: newPublic)
            } catch {
                do {
                    try manager.moveItem(atPath: target, toPath: source)
                    return .failure(RenameError.renameFailed("Public key rename failed; private key was restored: \(error.localizedDescription)"))
                } catch let rollbackError {
                    return .failure(RenameError.renameFailed("REPAIR REQUIRED: private key is now at \(target), but its .pub remains at \(oldPublic). Rollback failed: \(rollbackError.localizedDescription)"))
                }
            }
            return .success(target)
        } catch {
            return .failure(RenameError.renameFailed("Key rename failed without changing the public key: \(error.localizedDescription)"))
        }
    }
}

struct AuthorizedKeyIdentity: Equatable, Hashable {
    let type: String
    let body: String

    static func parse(_ line: String) -> AuthorizedKeyIdentity? {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let supportedPrefixes = ["ssh-", "ecdsa-", "sk-"]
        guard let index = fields.firstIndex(where: { field in
            supportedPrefixes.contains(where: field.hasPrefix)
        }), fields.indices.contains(index + 1) else { return nil }
        let type = fields[index]
        let body = fields[index + 1]
        guard Data(base64Encoded: body) != nil else { return nil }
        return AuthorizedKeyIdentity(type: type, body: body)
    }
}

// Build 31.9.5: The optional quit operation removes only identities actually
// used by a successful SSH tunnel during this application process. Keep an
// immutable snapshot of public key identity: a changed or replaced .pub file
// must never cause a different key to be removed from the user's agent.
struct SSHAgentUsedKey: Equatable {
    let path: String
    let identity: AuthorizedKeyIdentity
}

enum SSHAgentQuitKeyPolicy {
    static let preferenceKey = "RemoveUsedSSHKeysFromAgentOnQuit"

    static func isEnabledForQuit(preferenceEnabled: Bool, explicitMenuQuit: Bool) -> Bool {
        preferenceEnabled && explicitMenuQuit
    }

    static func record(path: String, publicKey: String, previous: [SSHAgentUsedKey]) -> [SSHAgentUsedKey] {
        guard let normalizedKey = AuthorizedPublicKeyLine.normalized(publicKey),
              let identity = AuthorizedKeyIdentity.parse(normalizedKey) else { return previous }
        // A public key shared by multiple saved servers is removed only once.
        guard !previous.contains(where: { $0.identity == identity }) else { return previous }
        let expanded = NSString(string: path).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        return previous + [SSHAgentUsedKey(path: normalized, identity: identity)]
    }

    static func matchesRecordedIdentity(_ record: SSHAgentUsedKey, currentPublicKey: String?) -> Bool {
        guard let currentPublicKey,
              let normalizedKey = AuthorizedPublicKeyLine.normalized(currentPublicKey),
              let currentIdentity = AuthorizedKeyIdentity.parse(normalizedKey) else {
            return false
        }
        return currentIdentity == record.identity
    }

    // Build 31.9.5.2: decide membership from ssh-agent itself, NOT from a
    // .pub file on disk. An unencrypted SSH key may be absent from the agent;
    // a moved/replaced/missing .pub must never block an already-absent key or
    // cause us to remove a different agent identity.
    static func agentIdentityState(
        recorded: SSHAgentUsedKey, exitCode: Int32, output: String, error: String
    ) -> SSHAgentKeyState {
        if exitCode == 1,
           (output + "\n" + error).lowercased().contains("no identities") {
            return .notLoaded
        }
        guard exitCode == 0 else {
            return .unavailable("ssh-add -L failed (exit \(exitCode)): " +
                ([error, output].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    ?? "Unknown error."))
        }
        let lines = output.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            return .unavailable("ssh-add -L returned no identities with a successful exit code.")
        }
        var identities = Set<AuthorizedKeyIdentity>()
        for line in lines {
            // The agent command must return only canonical public-key lines.
            // Never interpret a truncated or malformed listing as 'not loaded'.
            guard let normalized = AuthorizedPublicKeyLine.normalized(String(line)),
                  let identity = AuthorizedKeyIdentity.parse(normalized) else {
                return .unavailable("ssh-add -L returned a malformed or incomplete identity listing.")
            }
            identities.insert(identity)
        }
        return identities.contains(recorded.identity) ? .loaded : .notLoaded
    }

    static func removalInput(for record: SSHAgentUsedKey) -> String {
        // Feed exactly one immutable identity to `ssh-add -d -`. Never pass a
        // path or a multi-line .pub file that could change between commands.
        "\(record.identity.type) \(record.identity.body)\n"
    }
}

// Canonical authorized_keys entry: keep the user-provided comment when
// installing a new key, but never accept a second line or a key option prefix.
// An existing matching key is not rewritten (important for key restrictions).
enum AuthorizedPublicKeyLine {
    static func normalized(_ source: String) -> String? {
        guard !source.contains("\n"), !source.contains("\r"),
              !source.contains("\0") else { return nil }
        let tokens = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2, let identity = AuthorizedKeyIdentity.parse(source),
              tokens[0] == identity.type, tokens[1] == identity.body else { return nil }
        let comment = tokens.dropFirst(2).joined(separator: " ")
        return "\(identity.type) \(identity.body)" + (comment.isEmpty ? "" : " \(comment)")
    }
}

// Ordering token for read-only key/agent status checks. If a later check
// starts for the same key while an older async process is still running,
// only the later result may update the Settings UI.
struct SSHKeyStatusRefreshRequests {
    private var latestByPath: [String: UUID] = [:]

    mutating func begin(for path: String) -> UUID {
        let token = UUID()
        latestByPath[path] = token
        return token
    }

    func isCurrent(_ token: UUID, for path: String) -> Bool {
        latestByPath[path] == token
    }
}

enum SSHConnectionErrorFormatter {
    static func description(for rawError: String) -> String {
        let raw = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let guidance: String
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            guidance = "SSH host-key verification failed. Check the server fingerprint in Settings before approving any change."
        } else if lower.contains("agent refused operation") || lower.contains("sign_and_send_pubkey: signing failed") {
            guidance = "The SSH agent could not sign with the selected key. Recheck the key in SSH Key settings and reload it into ssh-agent."
        } else if lower.contains("unprotected private key file") || lower.contains("bad permissions") {
            guidance = "SSH rejected the private-key file permissions. Restrict the selected private key to its owner (chmod 600)."
        } else if lower.contains("permission denied") || lower.contains("no more authentication methods") {
            guidance = "SSH public-key authentication was rejected. Check the selected key, ssh-agent and the server's authorized_keys."
        } else if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            guidance = "The SSH host name could not be resolved. Check the SSH Host setting or local network."
        } else if lower.contains("connection refused") {
            guidance = "The SSH server refused the connection. Check its SSH service and port."
        } else if lower.contains("no route to host") || lower.contains("network is unreachable") {
            guidance = "The SSH server is unreachable. Check that the Mac and SSH server are on a reachable network."
        } else if lower.contains("connection reset by peer") || lower.contains("connection closed by") {
            guidance = "The SSH connection was closed by the remote host. Check the SSH service and server logs."
        } else if lower.contains("connection timed out") || lower.contains("operation timed out") {
            guidance = "The SSH server did not respond before the timeout. Check network reachability and SSH Port."
        } else if (lower.contains("identity file") && lower.contains("not accessible")) || lower.contains("no such identity") {
            guidance = "The selected SSH private key is missing or inaccessible. Check SSH Key settings."
        } else {
            guidance = "SSH tunnel or connection failed."
        }
        return raw.isEmpty ? guidance : "\(guidance) Details: \(raw)"
    }
}

enum AuthorizedKeysEditor {
    static func contains(_ publicKey: String, in contents: String) -> Bool {
        guard let target = AuthorizedKeyIdentity.parse(publicKey) else { return false }
        return contents.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { AuthorizedKeyIdentity.parse(String($0)) }
            .contains(target)
    }

    static func appendingIfMissing(_ publicKey: String, to contents: String) -> (contents: String, changed: Bool) {
        guard let target = AuthorizedKeyIdentity.parse(publicKey) else { return (contents, false) }
        if contents.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap({ AuthorizedKeyIdentity.parse(String($0)) }).contains(target) {
            return (contents, false)
        }
        guard let normalizedKey = AuthorizedPublicKeyLine.normalized(publicKey) else {
            return (contents, false)
        }
        if contents.isEmpty { return (normalizedKey + "\n", true) }
        return (contents + (contents.hasSuffix("\n") ? "" : "\n") + normalizedKey + "\n", true)
    }
}

enum ServerSettingsValidator {
    static func validate(
        _ profile: VNCServerProfile,
        viewerPath: String = "/Applications/TigerVNC.app",
        connectTimeout: Int = 10
    ) -> [String] {
        var errors: [String] = []
        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Display name is required.") }
        if profile.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("SSH host is required.") }
        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("SSH user is required.") }
        if !(1...65535).contains(profile.sshPort) { errors.append("SSH port must be between 1 and 65535.") }
        if !(1...65535).contains(profile.vncPort) { errors.append("VNC port must be between 1 and 65535.") }
        if !(0...99).contains(profile.displayNumber) { errors.append("VNC display must be between 0 and 99.") }
        if profile.vncHost != "127.0.0.1" && profile.vncHost != "localhost" { errors.append("VNC host must be loopback-only.") }
        if viewerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("TigerVNC Viewer path is required.") }
        if !(1...120).contains(connectTimeout) { errors.append("Timeout must be between 1 and 120 seconds.") }
        return errors
    }
}

// Build 31.9.5.1: An incomplete cleanup is still part of the original
// AppKit .terminateLater request. Retry must not create another terminate()
// request and must not resolve the pending reply prematurely.
enum QuitCleanupAlertChoice {
    case keepRunning, retryCleanup, quitAnyway
}

enum QuitCleanupNextStep: Equatable {
    case retryWhilePending
    case replyToPendingTermination(Bool)
}

enum QuitCleanupRetryPolicy {
    static func nextStep(for choice: QuitCleanupAlertChoice) -> QuitCleanupNextStep {
        switch choice {
        case .keepRunning: return .replyToPendingTermination(false)
        case .retryCleanup: return .retryWhilePending
        case .quitAnyway: return .replyToPendingTermination(true)
        }
    }
}
