import PebbleProtocol
import SwiftUI

/// Every version the store published, newest first: the version, when it
/// shipped, and what its author said about it. The row the reader is running
/// says so — by the store's own release number (#117), because the package's
/// label and the store's do not reliably agree.
struct CatalogChangelogView: View {
    var entries: [CatalogChangelogEntry]
    /// The store version installed today, if the store told us. Nil for an
    /// application that came in as a file, which no history row can claim.
    var installedVersion: String?

    var body: some View {
        List(entries, id: \.version) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.version)
                        .font(.headline)
                    if entry.version == installedVersion {
                        Text("Installed")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    if let publishedAt = entry.publishedAt {
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notes = entry.notes {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle(Text("Version History"))
    }
}

#Preview("A history with the installed version in it") {
    NavigationStack {
        CatalogChangelogView(
            entries: [
                CatalogChangelogEntry(
                    version: "1.16.0",
                    publishedAt: Date(timeIntervalSince1970: 1_789_500_000),
                    notes: "Sleep sessions now survive a reboot."
                ),
                CatalogChangelogEntry(
                    version: "1.15.2",
                    publishedAt: Date(timeIntervalSince1970: 1_780_000_000)
                ),
                CatalogChangelogEntry(
                    version: "1.15.1",
                    publishedAt: Date(timeIntervalSince1970: 1_770_000_000),
                    notes: "Fixes a crash on Pebble Time Round."
                ),
            ],
            installedVersion: "1.15.2"
        )
    }
}

#Preview("Nothing installed, and a dateless entry") {
    NavigationStack {
        CatalogChangelogView(
            entries: [
                CatalogChangelogEntry(version: "2.0", notes: "Rewritten for SDK 4."),
                CatalogChangelogEntry(version: "1.0"),
            ],
            installedVersion: nil
        )
    }
}
