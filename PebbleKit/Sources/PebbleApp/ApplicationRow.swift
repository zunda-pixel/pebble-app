import SwiftUI
import PebbleProtocol

/// A row that leads to the application rather than acting on it: what used to
/// be buttons crowded in beside the name is on the screen the row opens, where
/// each has room to say what it does.
struct ApplicationRow: View {
    var name: String
    var companyName: String
    var versionLabel: String
    var kind: WatchApplicationKind
    var isActive: Bool
    /// Nil when no watch is connected.
    var isInstalled: Bool?
    /// The store's picture of this application — a watchface's first
    /// screenshot, an app's icon — where the store has one. A package carries
    /// no images of its own, so a side-loaded application the store never
    /// listed keeps the symbol.
    var imageURL: URL? = nil

    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: {
                Image(systemName: kind == .watchface ? "clock" : "square.grid.2x2")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .frame(width: 44, height: 50)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                if !companyName.isEmpty {
                    Text(companyName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let isInstalled {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed on this watch", systemImage: "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            // Said rather than offered: tapping the row opens the screen that
            // can change it.
            if kind == .watchface, isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Active"))
            }
            Text(versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Installed app") {
    List {
        ApplicationRow(
            name: PreviewSamples.watchApplications[0].displayName,
            companyName: PreviewSamples.watchApplications[0].companyName,
            versionLabel: PreviewSamples.watchApplications[0].versionLabel,
            kind: .watchapp,
            isActive: false,
            isInstalled: true
        )
    }
}

#Preview("Active watchface, no watch") {
    List {
        ApplicationRow(
            name: PreviewSamples.watchfaces[0].displayName,
            companyName: PreviewSamples.watchfaces[0].companyName,
            versionLabel: PreviewSamples.watchfaces[0].versionLabel,
            kind: .watchface,
            isActive: true,
            isInstalled: nil
        )
    }
}
