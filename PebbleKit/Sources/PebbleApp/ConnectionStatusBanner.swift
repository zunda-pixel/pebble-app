import SwiftUI
import PebbleProtocol

struct ConnectionStatusBanner: View {
    var state: WatchConnectionState
    var cancelReconnect: (() -> Void)? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack {
            Label { title } icon: { Image(systemName: systemImage) }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Connection status"))
                .accessibilityValue(title)
            if case .reconnecting = state, let cancelReconnect {
                Button("Stop Reconnecting", role: .cancel, action: cancelReconnect)
                    .font(.callout)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
    }

    // A `Text` rather than a key: the failure reads as two sentences, and one of
    // them comes from the connection layer already localized.
    private var title: Text {
        switch state {
        case .idle: Text("Not connected")
        case .scanning: Text("Scanning for watches…")
        case .connecting: Text("Connecting…")
        case .negotiating: Text("Setting up connection…")
        case .connected(let watch): Text("Connected to \(watch.name)")
        case .reconnecting: Text("Connection lost — reconnecting…")
        case .failed(let error): Text("Connection failed. \(Text(error.message))")
        }
    }

    private var systemImage: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .scanning, .connecting, .negotiating, .reconnecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "applewatch.slash"
        }
    }
}

#Preview("Reconnecting") {
    ConnectionStatusBanner(state: .reconnecting(watchID: PreviewSamples.watch.id)) {}
}

#Preview("Connected") {
    ConnectionStatusBanner(state: .connected(PreviewSamples.watch))
}

#Preview("Failed") {
    ConnectionStatusBanner(state: .failed(.connectionTimedOut))
}

#Preview("Not connected") {
    ConnectionStatusBanner(state: .idle)
}

#Preview("Scanning") {
    ConnectionStatusBanner(state: .scanning)
}
