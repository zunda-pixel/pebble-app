import SwiftUI

struct CatalogStateLabel: View {
    var state: CatalogInstallationState
    var body: some View {
        switch state {
        case .available: EmptyView()
        case .installed: Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .updateAvailable: Label("Update", systemImage: "arrow.down.circle").foregroundStyle(.tint)
        case .incompatible: Label("Incompatible", systemImage: "nosign").foregroundStyle(.secondary)
        }
    }
}

#Preview("Every state") {
    List {
        CatalogStateLabel(state: .available)
        CatalogStateLabel(state: .installed)
        CatalogStateLabel(state: .updateAvailable)
        CatalogStateLabel(state: .incompatible)
    }
}
