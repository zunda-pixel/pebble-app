import PebbleProtocol
import SwiftUI

/// One of the store's shelves, opened: the full listing behind a Top Picks or
/// a Most Loved, paged the way the store pages it. Rows go to the same detail
/// screen and install path as everywhere else in the catalogue.
struct CatalogCollectionView: View {
    var collection: CatalogCollection
    var model: AppModel
    var editGlance: (WatchApplication) -> Void

    @State private var applications: [CatalogApplication] = []
    /// How far into the store's listing the pages so far reach. Not
    /// `applications.count`: that is after doubles are dropped, and asking
    /// from there fetched again rows already received.
    @State private var receivedCount = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var failedToLoad = false

    var body: some View {
        CatalogCollectionContent(
            collectionName: collection.name,
            applications: applications,
            state: { model.catalogInstallationState(for: $0) },
            hasMore: hasMore,
            isLoading: isLoading,
            failedToLoad: failedToLoad,
            loadMore: { Task { await loadPage() } },
            destination: { application in
                CatalogApplicationDetailView(
                    application: application,
                    model: model,
                    editGlance: editGlance
                )
            }
        )
        .task {
            guard applications.isEmpty else { return }
            await loadPage()
        }
    }

    private func loadPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // `hasMore` is left as it was: a page that failed is still a page the
        // shelf has, and dropping it ended the list as though it were whole.
        guard let page = await model.fetchCollectionPage(collection, offset: receivedCount) else {
            failedToLoad = true
            return
        }
        failedToLoad = false
        receivedCount += page.applications.count
        // The store already ranks the shelf; only doubles are dropped, which
        // paging over a listing that shifted underneath can produce.
        let known = Set(applications.map(\.id))
        applications += page.applications.filter { !known.contains($0.id) }
        hasMore = page.hasMore
    }
}

struct CatalogCollectionContent<Destination: View>: View {
    var collectionName: String
    var applications: [CatalogApplication]
    var state: (CatalogApplication) -> CatalogInstallationState
    var hasMore: Bool
    var isLoading: Bool
    var failedToLoad: Bool
    var loadMore: () -> Void
    @ViewBuilder var destination: (CatalogApplication) -> Destination

    var body: some View {
        List {
            ForEach(applications) { application in
                NavigationLink {
                    destination(application)
                } label: {
                    CatalogApplicationRow(application: application, state: state(application))
                }
            }
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if failedToLoad, !applications.isEmpty {
                Label("The next page could not be fetched.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise", action: loadMore)
            } else if hasMore {
                Button("Load More", action: loadMore)
            }
        }
        // The store's title, translated where this app knows it and verbatim
        // where it does not, like the section row that opened this.
        .navigationTitle(catalogCollectionText(collectionName))
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
}

#Preview("A shelf") {
    NavigationStack {
        CatalogCollectionContent(
            collectionName: PreviewSamples.catalogCollections[0].name,
            applications: [PreviewSamples.catalogApplication],
            state: { _ in .available },
            hasMore: true,
            isLoading: false,
            failedToLoad: false,
            loadMore: {},
            destination: { application in Text(verbatim: application.name) }
        )
    }
}

#Preview("Next page could not be fetched") {
    NavigationStack {
        CatalogCollectionContent(
            collectionName: PreviewSamples.catalogCollections[0].name,
            applications: [PreviewSamples.catalogApplication],
            state: { _ in .available },
            hasMore: true,
            isLoading: false,
            failedToLoad: true,
            loadMore: {},
            destination: { application in Text(verbatim: application.name) }
        )
    }
}

#Preview("First page on its way") {
    NavigationStack {
        CatalogCollectionContent(
            collectionName: PreviewSamples.catalogCollections[0].name,
            applications: [],
            state: { _ in .available },
            hasMore: false,
            isLoading: true,
            failedToLoad: false,
            loadMore: {},
            destination: { _ in EmptyView() }
        )
    }
}

#Preview("Could not be fetched") {
    NavigationStack {
        CatalogCollectionContent(
            collectionName: PreviewSamples.catalogCollections[1].name,
            applications: [],
            state: { _ in .available },
            hasMore: false,
            isLoading: false,
            failedToLoad: true,
            loadMore: {},
            destination: { _ in EmptyView() }
        )
    }
}

#Preview("Empty shelf") {
    NavigationStack {
        CatalogCollectionContent(
            collectionName: PreviewSamples.catalogCollections[1].name,
            applications: [],
            state: { _ in .available },
            hasMore: false,
            isLoading: false,
            failedToLoad: false,
            loadMore: {},
            destination: { _ in EmptyView() }
        )
    }
}
