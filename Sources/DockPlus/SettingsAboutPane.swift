import AppKit
import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "About") {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .padding(.bottom, 4)
                Text("DockPlus").font(.system(size: 24, weight: .bold))
                Text("A Dock replacement for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // Markdown, so the name alone is the link and the sentence still reads as one line.
                Text("Created by [Kenny B](https://github.com/kdbaustert)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
                    .help("github.com/kdbaustert")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                    .fill(SettingsChrome.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                    .strokeBorder(SettingsChrome.cardBorder, lineWidth: SettingsChrome.hairline))

            SettingsSection(title: "DockPlus", anchor: SettingsAnchor.build) {
                SettingsRow(title: "Version") {
                    Text(version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(title: "Source code", subtitle: "github.com/kdbaustert/DockPlus") {
                    Link("View on GitHub", destination: URL(string: "https://github.com/kdbaustert/DockPlus")!)
                }
                SettingsRow(title: "Quit DockPlus", subtitle: "Asks whether to bring the macOS Dock back first.") {
                    Button("Quit…") { NSApp.terminate(nil) }
                }
            }
        }
    }
}
