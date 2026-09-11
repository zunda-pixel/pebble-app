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
            } label: {
                Text(verbatim: package.name)
            }
        }
        .navigationTitle(Text("Licenses"))
    }
}

#Preview("Licenses") {
    NavigationStack {
        LicensesView()
    }
}
