import SwiftUI
import PebbleProtocol

#if !os(macOS)
struct IOSRootView: View {
    var model: AppModel
    var isFront: Bool
    @State private var selection: AppSection = .watches

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                // The label as a view rather than a key: `Tab`'s own
                // title initializer and a shimmed one cannot be told apart,
                // and this way the label is built by `Label` above.
                Tab(value: section) {
                    NavigationStack {
                        SectionContent(section: section, model: model)
                        .toolbar {
                            ToolbarItem(placement: .status) {
                                ConnectionStatusBanner(state: model.connectionState) {
                                    Task { await model.disconnect() }
                                }
                            }
                        }
                    }
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        // `initial:` because a cold start from a link sets the request before
        // this view exists, and waiting for a change would wait forever.
        .onChange(of: isFront ? model.deepLinks.requestedSection : nil, initial: true) { _, requested in
            guard let requested else { return }
            selection = requested
            model.consumeRequestedDeepLinkSection()
        }
    }
}

#Preview("Tabs") {
    IOSRootView(model: PreviewSamples.appModel(), isFront: true)
}
#endif
