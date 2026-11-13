// swift-tools-version: 6.0
// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

import PackageDescription

let package = Package(
    name: "AstroberryCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AstroberryCore", targets: ["AstroberryCore"])],
    targets: [
        .target(
            name: "AstroberryCore",
            path: "AstroberryVNC",
            // These belong to the Xcode app target, not the SwiftPM core.
            exclude: [
                "AstroberryVNCApp.swift", "SettingsView.swift", "MenuContentView.swift",
                "VisualCheckView.swift", "Info.plist", "Info-VisualCheck.plist",
                "AnimatedStatusMenuCoordinator.swift", "AnimatedStatusIconOverlay.swift",
                "Assets.xcassets"
            ],
            sources: [
                "ConnectionController.swift",
                "SystemCommandRunner.swift",
                "SecurityUtilities.swift",
                "ServerMenuInteractionState.swift"
            ]
        ),
        .testTarget(
            name: "AstroberryCoreTests",
            dependencies: ["AstroberryCore"],
            path: "Tests/AstroberryCoreTests"
        )
    ]
)
