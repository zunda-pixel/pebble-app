import PebbleProtocol
import PebbleTransport
import SwiftUI

/// One of the store's shelves, opened: the full listing behind a Top Picks or
/// a Most Loved, paged the way the store pages it. Rows go to the same detail
/// screen and install path as everywhere else in the catalogue.
struct CatalogCollectionView: View {
    var collection: CatalogCollection
    var model: AppModel
    var editGlance: (WatchApplication) -> Void

    @State private var applications: [CatalogApplication] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var failedToLoad = false

    var body: some View {
        List {
            ForEach(applications) { application in
                NavigationLink {
                    CatalogApplicationDetailView(
                        application: application,
                        model: model,
                        editGlance: editGlance
                    )
                } label: {
                    CatalogApplicationRow(
                        application: application,
                        state: model.catalogInstallationState(for: application)
                    )
                }
            }
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if hasMore {
                Button("Load More") {
                    Task { await loadPage() }
                }
            }
        }
        // The store's own title, shown verbatim: the shelf is the store's to name.
        .navigationTitle(Text(verbatim: collection.name))
        .task {
            guard applications.isEmpty else { return }
            await loadPage()
        }
        .overlay {
            if applications.isEmpty, !isLoading {
                if failedToLoad {
                    ContentUnavailableView(
                        "The collection could not be fetched.",
                        systemImage: "wifi.exclamationmark"
                    )
                } else {
                    // The store is entitled to an empty shelf; an error would
                    // be the wrong thing to call it.
                    ContentUnavailableView("This collection is empty.", systemImage: "bag")
                }
            }
        }
    }

    private func loadPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = await model.fetchCollectionPage(collection, offset: applications.count) else {
            failedToLoad = true
            hasMore = false
            return
        }
        failedToLoad = false
        // The store already ranks the shelf; only doubles are dropped, which
        // paging over a listing that shifted underneath can produce.
        let known = Set(applications.map(\.id))
        applications += page.applications.filter { !known.contains($0.id) }
        hasMore = page.hasMore
    }
}

#Preview("A shelf") {
    NavigationStack {
        CatalogCollectionView(
            collection: CatalogCollection(
                slug: "top-picks",
                name: "Top Picks (Changes Daily)",
                kind: .watchface,
                appsPath: "/api/v1/apps/collection/top-picks/faces"
            ),
            model: AppModel(client: MockWatchClient()),
            editGlance: { _ in }
        )
    }
}
