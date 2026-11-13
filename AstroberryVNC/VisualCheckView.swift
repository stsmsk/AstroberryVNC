// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later

#if VISUAL_CHECK
import SwiftUI

struct VisualCheckView: View {
    @ObservedObject var controller: ConnectionController
    @State private var scenario = VisualCheckScenario.disconnected

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Visual Check Controls")
                    .font(.title2.bold())
                Text("Safe preview only. SSH, TigerVNC, notifications, and settings persistence are disabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Connection state")
                    .font(.headline)
                ForEach(VisualCheckScenario.allCases) { item in
                    Button(item.rawValue) {
                        scenario = item
                        controller.applyVisualCheckScenario(item)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(item.accessibilityIdentifier)
                }

                Divider()
                Text("Selected: \(controller.selectedProfile?.displayName ?? "None")")
                    .accessibilityIdentifier("selectedServerSummary")
                Text("Build mode: VISUAL_CHECK")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Product menu preview")
                    .font(.headline)
                MenuContentView(controller: controller, openSettingsAction: {})
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 8, y: 3)
            }
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            controller.applyVisualCheckScenario(scenario)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .focusAstroberryMainMenu, object: nil)
            }
        }
    }
}
#endif
