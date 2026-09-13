public import Foundation
public import SwiftUI

/// The model a window is showing is the message's subject, so a command only
/// reaches the windows showing that model.
public struct ScanRequest: NotificationCenter.MainActorMessage {
    public typealias Subject = AppModel

    public init() {}
}

public struct SectionRequest: NotificationCenter.MainActorMessage {
    public typealias Subject = AppModel

    public var section: AppSection

    public init(section: AppSection) {
        self.section = section
    }
}

public extension View {
    func onWindowMessage<Message: NotificationCenter.MainActorMessage>(
        _ messageType: Message.Type,
        from model: AppModel,
        perform action: @escaping @MainActor (Message) -> Void
    ) -> some View where Message.Subject == AppModel {
        modifier(MessageObserver(model: model, action: action))
    }
}

private struct MessageObserver<Message: NotificationCenter.MainActorMessage>: ViewModifier
where Message.Subject == AppModel {
    var model: AppModel
    var action: @MainActor (Message) -> Void

    // The observation lives exactly as long as the token, so the view holds it.
    @State private var token: NotificationCenter.ObservationToken?

    func body(content: Content) -> some View {
        content
            .onAppear {
                token = NotificationCenter.default.addObserver(
                    of: model,
                    for: Message.self,
                    using: action
                )
            }
            .onDisappear {
                if let token {
                    NotificationCenter.default.removeObserver(token)
                }
                token = nil
            }
    }
}
