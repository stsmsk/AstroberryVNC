// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import AstroberryCore

final class Build25EditingPolicyTests: XCTestCase {
    private let astroberry = VNCServerProfile(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        displayName: "astroberry", server: "astroberry.local", username: "astroberry"
    )
    private let other = VNCServerProfile(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
        displayName: "Observatory", server: "observatory.local", username: "observer"
    )

    func testActiveProfileMayRenameWithoutChangingUUIDOrConnection() {
        var edited = astroberry
        edited.displayName = "Renamed Astroberry"
        XCTAssertTrue(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: astroberry, proposed: edited, sessionProfileID: astroberry.id
        ))
        XCTAssertEqual(edited.id, astroberry.id)
    }

    func testActiveProfileConnectionFieldsCannotChange() {
        let changes: [(inout VNCServerProfile) -> Void] = [
            { $0.server = "new-host.local" },
            { $0.username = "other" },
            { $0.sshPort = 2222 },
            { $0.privateKeyPath = "/tmp/another-key" },
            { $0.vncHost = "localhost" },
            { $0.vncPort = 5901 },
            { $0.displayNumber = 1 },
            { $0.viewerPath = "/tmp/viewer" },
            { $0.connectTimeout = 15 }
        ]
        for modify in changes {
            var edited = astroberry
            modify(&edited)
            XCTAssertFalse(SessionProfileEditingPolicy.allowsProfileUpdate(
                previous: astroberry, proposed: edited, sessionProfileID: astroberry.id
            ), "Protected field was accepted: \(edited)")
        }
    }

    func testOtherProfileMayBeEditedDuringSession() {
        var edited = other
        edited.server = "new-observatory.local"
        edited.vncPort = 5971
        edited.privateKeyPath = "/tmp/another-key"
        XCTAssertTrue(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: other, proposed: edited, sessionProfileID: astroberry.id
        ))
    }

    func testDisconnectedProfileCanBeEdited() {
        var edited = astroberry
        edited.sshPort = 2222
        XCTAssertTrue(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: astroberry, proposed: edited, sessionProfileID: nil
        ))
    }

    func testProfileIdentityMustNeverBeReplacedByMutation() {
        var edited = astroberry
        edited.id = other.id
        XCTAssertFalse(SessionProfileEditingPolicy.allowsProfileUpdate(
            previous: astroberry, proposed: edited, sessionProfileID: nil
        ))
    }

    func testSharedSSHPrivateKeyIsRecognizedThroughDotPath() {
        XCTAssertTrue(SessionProfileEditingPolicy.sameKeyFile(
            "/tmp/astroberry-keys/./id_ed25519", "/tmp/astroberry-keys/id_ed25519"
        ))
        XCTAssertFalse(SessionProfileEditingPolicy.sameKeyFile(
            "/tmp/astroberry-keys/id_ed25519", "/tmp/astroberry-keys/other"
        ))
    }

    func testMatchingRemoteAccountProtectsAuthorizedKeys() {
        var alias = astroberry
        alias.id = other.id
        alias.server = "ASTROBERRY.LOCAL"
        XCTAssertTrue(SessionProfileEditingPolicy.sameSSHAccount(alias, astroberry))
        alias.username = "other"
        XCTAssertTrue(SessionProfileEditingPolicy.sameSSHHost(alias, astroberry))
        XCTAssertFalse(SessionProfileEditingPolicy.sameSSHAccount(alias, astroberry))
        alias.username = astroberry.username
        alias.sshPort = 2222
        XCTAssertFalse(SessionProfileEditingPolicy.sameSSHHost(alias, astroberry))
        XCTAssertFalse(SessionProfileEditingPolicy.sameSSHAccount(alias, astroberry))
    }

    func testSessionIDDoesNotFollowSettingsSidebar() {
        XCTAssertTrue(SessionProfileEditingPolicy.connectionFieldsLocked(
            profileID: astroberry.id, sessionProfileID: astroberry.id
        ))
        XCTAssertFalse(SessionProfileEditingPolicy.connectionFieldsLocked(
            profileID: other.id, sessionProfileID: astroberry.id
        ))
    }
}
