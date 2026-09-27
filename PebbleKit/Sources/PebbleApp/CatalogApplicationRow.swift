import SwiftUI
import PebbleProtocol

struct CatalogApplicationRow: View {
    var application: CatalogApplication
    var state: CatalogInstallationState

    /// A watchface's first screenshot is the face itself, which no icon says
    /// as well; a watch app's icon is its identity, so it stays first there.
    private var imageURL: URL? {
        application.kind == .watchface
            ? application.screenshotURLs.first ?? application.iconURL
            : application.iconURL ?? application.screenshotURLs.first
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: {
                Image(systemName: application.kind == .watchface ? "clock" : "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 50)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name).font(.headline)
                Text(verbatim: "\(application.developer) · \(application.version)").foregroundStyle(.secondary)
                // Left out where the store did not name one, as the detail
                // screen already does. It used to draw the model's `"Other"`,
                // which was this app putting a word in the store's mouth.
                if let category = application.category {
                    catalogCategoryText(category).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CatalogStateLabel(state: state)
        }
        .frame(minHeight: 52)
    }
}

#Preview("Catalog rows") {
    List {
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .available)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .installed)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .updateAvailable)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .incompatible)
        // The store did not name a category for this one. The line goes rather
        // than being filled with a word the store never said.
        CatalogApplicationRow(
            application: {
                var uncategorised = PreviewSamples.catalogApplication
                uncategorised.category = nil
                return uncategorised
            }(),
            state: .available
        )
    }
}
