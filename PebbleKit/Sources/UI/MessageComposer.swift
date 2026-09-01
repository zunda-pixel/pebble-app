import SwiftUI
#if os(iOS)
import MessageUI
#endif

/// Messages, opened at a new message with the reply already written.
///
/// The sheet rather than an `sms:` link, for two reasons: it takes an email
/// address as well as a number — which is what sends an iMessage — and it tells
/// the caller whether the message went, so a reply can be cleared when it is
/// sent and kept when it is not.
///
/// Sending is still a tap. iOS has no way for an app to send a message on its
/// own, and this sheet is as close as it goes.
struct MessageComposer: View {
    var recipient: String?
    var message: String
    var onFinish: (Bool) -> Void

    #if os(iOS)
    static var isAvailable: Bool { MFMessageComposeViewController.canSendText() }
    #else
    static var isAvailable: Bool { false }
    #endif

    var body: some View {
        #if os(iOS)
        MessageComposeView(recipient: recipient, message: message, onFinish: onFinish)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct MessageComposeView: UIViewControllerRepresentable {
    var recipient: String?
    var message: String
    var onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = message
        if let recipient, !recipient.isEmpty {
            controller.recipients = [recipient]
        }
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onFinish(result == .sent)
        }
    }
}
#endif
