import SwiftUI
import PebbleProtocol

#if os(macOS)
struct MacRootView: View {
    var model: AppModel
    var isFront: Bool
    @State private var selection: AppSection? = .watches

    var body: some View {
        NavigationSplitView {
            List(AppSection.windowSections, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle(Text("Pebble"))
        } detail: {
            NavigationStack {
                VStack(spacing: 0) {
                    ConnectionStatusBanner(state: model.connectionState) {
                        Task { await model.disconnect() }
                    }
                    SectionContent(section: selection ?? .watches, model: model)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onWindowMessage(ScanRequest.self, from: model) { _ in
            selection = .watches
        }
        .onWindowMessage(SectionRequest.self, from: model) { message in
            selection = message.section
        }
        // A deep link's navigation. Settings is its own window on the Mac and
        // not in the sidebar, so that one request has nowhere to go here.
        // Asked of the front window alone, which takes it up once it is front.
        .onChange(of: isFront ? model.deepLinks.requestedSection : nil, initial: true) { _, requested in
            guard let requested else { return }
            if requested != .settings { selection = requested }
            model.consumeRequestedDeepLinkSection()
        }
    }
}

#Preview("Mac window") {
    MacRootView(model: PreviewSamples.appModel(), isFront: true)
}
#endif
