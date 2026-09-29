import PebbleProtocol
import Foundation
// `FeatureFeedback` holds a `LocalizedStringKey`, whose literal initializer
// needs the module that declares it.
import SwiftUI

extension AppModel {
    /// What a reader who has never set any starts with, so the notification
    /// extension has something to send from the first time the screen is seen.
    static var startingReplyTemplates: [String] {
        [
            String(localized: "Got it.", bundle: .module),
            String(localized: "Yes", bundle: .module),
            String(localized: "No", bundle: .module),
            String(localized: "On my way!", bundle: .module),
            String(localized: "Thank you!", bundle: .module),
            String(localized: "I'll call you later.", bundle: .module),
        ]
    }

    func loadReplyTemplates() async {
        let stored: [ReplyTemplate]?
        do {
            stored = try await replyTemplateStore.templates()
        } catch {
            notifications.replyTemplates = []
            notifications.replyTemplatesFeedback = .failure("The reply templates could not be read.")
            return
        }
        if let stored {
            notifications.replyTemplates = stored
            return
        }
        let starting = Self.startingReplyTemplates.map { ReplyTemplate(text: $0) }
        let isKept = await changeReplyTemplates { _ in starting }
        if !isKept {
            notifications.replyTemplates = []
        }
    }

    func addReplyTemplate(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let added = ReplyTemplate(text: trimmed)
        await changeReplyTemplates { $0 + [added] }
    }

    func updateReplyTemplate(_ template: ReplyTemplate) async {
        let trimmed = template.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = template.id
        await changeReplyTemplates { templates in
            templates.map { $0.id == id ? ReplyTemplate(id: id, text: trimmed) : $0 }
        }
    }

    func removeReplyTemplates(_ removed: [ReplyTemplate]) async {
        let ids = Set(removed.map(\.id))
        await changeReplyTemplates { templates in
            templates.filter { !ids.contains($0.id) }
        }
    }

    /// Puts `moving` in front of `target`, or at the end for none.
    func moveReplyTemplates(_ moving: [ReplyTemplate], before target: ReplyTemplate?) async {
        let ids = Set(moving.map(\.id))
        let targetID = target?.id
        await changeReplyTemplates { templates in
            let moved = templates.filter { ids.contains($0.id) }
            var remaining = templates.filter { !ids.contains($0.id) }
            let index = targetID.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.count
            remaining.insert(contentsOf: moved, at: index)
            return remaining
        }
    }

    /// The list on screen changes only once it is kept: the extension reads the
    /// file, not this model, so a list shown and not saved is not what the
    /// watch is offered. The change is made to the list the store holds rather
    /// than to this copy, which lags behind any change still being saved.
    @discardableResult
    private func changeReplyTemplates(
        _ change: @Sendable ([ReplyTemplate]) -> [ReplyTemplate]
    ) async -> Bool {
        let kept: [ReplyTemplate]
        do {
            kept = try await replyTemplateStore.modify(change)
        } catch is ReplyTemplateStore.ContainerUnavailable {
            notifications.replyTemplatesFeedback = .failure(
                "Reply templates cannot be kept here: this app has no storage the notification extension can read."
            )
            return false
        } catch {
            notifications.replyTemplatesFeedback = .failure("The reply templates could not be saved.")
            return false
        }
        notifications.replyTemplates = kept
        notifications.replyTemplatesFeedback = nil
        return true
    }
}
