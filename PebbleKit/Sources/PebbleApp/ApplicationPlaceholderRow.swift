import SwiftUI

struct ApplicationPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
            VStack(alignment: .leading, spacing: 4) {
                Text("App Name")
                    .font(.headline)
                Text("Developer")
                    .font(.subheadline)
            }
        }
        .frame(minHeight: 44)
    }
}

#Preview("Loading") {
    List(0..<3, id: \.self) { _ in
        ApplicationPlaceholderRow()
    }
    .redacted(reason: .placeholder)
}
