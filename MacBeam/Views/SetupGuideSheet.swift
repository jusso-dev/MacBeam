import SwiftUI

struct SetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 28

    var body: some View {
        NavigationStack {
            List {
                Section {
                    guideRow(
                        step: "1",
                        title: "Enable Screen Sharing on Your Mac",
                        detail: "Open System Settings → General → Sharing and turn on Screen Sharing (or Remote Management)."
                    )
                    guideRow(
                        step: "2",
                        title: "Sign In with macOS or VNC Password",
                        detail: "MacBeam supports both macOS account login (Apple Diffie-Hellman) and legacy VNC passwords enabled under the Screen Sharing ⓘ button. You can pin an explicit authentication method per saved Mac."
                    )
                    guideRow(
                        step: "3",
                        title: "Connect Safely on Wi-Fi or VPN",
                        detail: "Macs on the same Wi-Fi automatically appear under Nearby Macs via Bonjour. For remote access outside your home network, connect over Tailscale, WireGuard, or an SSH tunnel since standard VNC traffic is unencrypted."
                    )
                } header: {
                    Text("Getting Started")
                }

                Section("Gestures & iPad Controls") {
                    Label("Trackpad Mode: Drag anywhere to move the cursor, tap to click, double-tap to double-click, and two-finger tap to right-click.", systemImage: "rectangle.and.hand.point.up.left")
                    Label("Drag & Drop: Touch and hold (long-press), then drag to move windows or select text.", systemImage: "hand.draw")
                    Label("Scrolling & Zoom: Two-finger drag scrolls macOS; pinch zooms the display.", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("iPad Magic Keyboard & Mouse: Full hardware keyboard shortcuts, pointer hover, click-drag, right-click, and smooth scrolling.", systemImage: "keyboard")
                }
            }
            .navigationTitle("Mac Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(step: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(step)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: badgeSize, minHeight: badgeSize)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step): \(title). \(detail)")
    }
}
