import SwiftUI
import UIKit

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/shantanugoel/atarang")!

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    VStack(spacing: 12) {
                        appIcon
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                            .accessibilityHidden(true)

                        Text("Atarang")
                            .font(.title2.bold())

                        Text("Separate songs into stems, customize the mix, and record yourself playing along.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Author", value: "Shantanu Goel")

                    Link(destination: repositoryURL) {
                        Label("View Project on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = AppIconLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Color.indigo
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
    }
}

private enum AppIconLoader {
    static var image: UIImage? {
        let bundle = Bundle.main
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String]

        guard let iconName = iconFiles?.last else {
            return UIImage(named: "AppIcon")
        }
        return UIImage(named: iconName)
    }
}
