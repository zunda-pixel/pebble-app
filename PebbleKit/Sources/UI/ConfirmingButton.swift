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
        .confirmationDialog(question, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(confirmationTitle, role: confirmationRole, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(explanation)
        }
    }
}
