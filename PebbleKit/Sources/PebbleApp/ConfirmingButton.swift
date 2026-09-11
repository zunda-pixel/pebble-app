import SwiftUI

/// A button that asks before it acts.
///
/// The dialog is attached to the button rather than to the screen around it, so
/// it is anchored to the control that was tapped and each button carries its own
/// question instead of the screen holding one shared piece of pending state.
struct ConfirmingButton: View {
    var title: LocalizedStringKey
    var systemImage: String?
    var role: ButtonRole?
    var question: LocalizedStringKey
    var explanation: LocalizedStringKey
    var confirmationTitle: LocalizedStringKey
    var confirmationRole: ButtonRole? = .destructive
    var action: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button(role: role) {
            isConfirming = true
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .confirmationDialog(Text(question), isPresented: $isConfirming, titleVisibility: .visible) {
            Button(confirmationTitle, role: confirmationRole, action: action)
            Button(role: .cancel) {}
        } message: {
            Text(explanation)
        }
    }
}

#Preview {
    List {
        ConfirmingButton(
            title: "Forget This Watch",
            systemImage: "trash",
            role: .destructive,
            question: "Forget Pebble 5209?",
            explanation: "The watch is disconnected and removed from this phone. Its apps stay in the library.",
            confirmationTitle: "Forget Watch"
        ) {}
        // Without an image the label is plain text — the button's one branch.
        ConfirmingButton(
            title: "Forget Watch",
            role: .destructive,
            question: "Forget \("Pebble 5209")?",
            explanation: "Automatic reconnection information for this Pebble will be removed.",
            confirmationTitle: "Forget Watch"
        ) {}
    }
}
