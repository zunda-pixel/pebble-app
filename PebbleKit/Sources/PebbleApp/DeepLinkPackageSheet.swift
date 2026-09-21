import Foundation
import PebbleProtocol
import SwiftUI

/// What a link offered, laid out for the reader to judge before anything is
/// sent: the package's own name and version, not the URL's promise. The
/// install button hands over to the same paths a file chosen in the importer
/// takes.
struct DeepLinkPackageSheet: View {
    var package: PendingDeepLinkPackage
    var install: () -> Void
    var cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Kind") { Text(kindTitle) }
                    if let title = package.title {
                        LabeledContent("Name") { Text(title) }
                    }
                    if let subtitle = package.subtitle {
                        LabeledContent("Details") { Text(subtitle) }
                    }
                    LabeledContent("File") { Text(package.fileName) }
                    if package.byteCount > 0 {
                        LabeledContent("Size") {
                            Text(package.byteCount.formatted(.byteCount(style: .file)))
                        }
                    }
                } footer: {
                    Text("This arrived as a link. It is only installed if you choose to.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Install from link?"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install", action: install)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                }
            }
        }
    }

    private var kindTitle: LocalizedStringKey {
        switch package.kind {
        case .watchApp: "Watch app"
        case .firmware: "Firmware"
        case .languagePack: "Language pack"
        }
    }
}

#Preview("Watch app") {
    DeepLinkPackageSheet(
        package: PendingDeepLinkPackage(
            kind: .watchApp,
            fileName: "runcat.pbw",
            localURL: URL(filePath: "/tmp/runcat.pbw"),
            title: "RunCat for Pebble",
            subtitle: "Kyome · 1.4",
            byteCount: 131_072
        ),
        install: {},
        cancel: {}
    )
}

#Preview("Firmware, nothing to say about it") {
    DeepLinkPackageSheet(
        package: PendingDeepLinkPackage(
            kind: .firmware,
            fileName: "obelix.pbz",
            localURL: URL(filePath: "/tmp/obelix.pbz"),
            byteCount: 2_400_000
        ),
        install: {},
        cancel: {}
    )
}

#Preview("Language pack") {
    DeepLinkPackageSheet(
        package: PendingDeepLinkPackage(
            kind: .languagePack,
            fileName: "ja_zh.pbl",
            localURL: URL(filePath: "/tmp/ja_zh.pbl"),
            byteCount: 812_000
        ),
        install: {},
        cancel: {}
    )
}
