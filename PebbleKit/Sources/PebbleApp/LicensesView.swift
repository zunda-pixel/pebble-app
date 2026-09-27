import SwiftUI

/// The licenses of everything this app is built from.
///
/// The list is generated from the package graph at build time
/// (LicenseProvider), so a new dependency brings its license here by existing
/// — there is no hand-kept list to forget to extend. Names and license texts
/// are the packages' own words, shown verbatim.
struct LicensesView: View {
    var body: some View {
        List(LicenseProvider.packages) { package in
            NavigationLink {
                LicenseDetailView(package: package)
            } label: {
                Text(verbatim: package.name)
            }
        }
        .navigationTitle(Text("Licenses"))
    }
}

/// One package's license, in its own words.
struct LicenseDetailView: View {
    var package: Package

    var body: some View {
        ScrollView {
            Text(verbatim: package.license)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: package.name))
        .toolbar {
            if case .remoteSourceControl(let location) = package.kind {
                ToolbarItem(placement: .primaryAction) {
                    Link(destination: location) {
                        Label("Open Repository", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }
}

#Preview("Licenses") {
    NavigationStack {
        LicensesView()
    }
}

#Preview("A package with a repository") {
    NavigationStack {
        LicenseDetailView(package: PreviewSamples.remotePackage)
    }
}

#Preview("A package with nowhere to link") {
    NavigationStack {
        LicenseDetailView(package: PreviewSamples.registryPackage)
    }
}
