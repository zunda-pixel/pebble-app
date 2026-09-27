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
        if !(await saveReplyTemplates(starting)) {
            notifications.replyTemplates = []
        }
    }

    func addReplyTemplate(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await saveReplyTemplates((notifications.replyTemplates ?? []) + [ReplyTemplate(text: trimmed)])
    }

    func updateReplyTemplate(_ template: ReplyTemplate) async {
        let trimmed = template.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var templates = notifications.replyTemplates,
              let index = templates.firstIndex(where: { $0.id == template.id }) else {
            return
        }
        templates[index].text = trimmed
        await saveReplyTemplates(templates)
    }

    func removeReplyTemplates(_ removed: [ReplyTemplate]) async {
        guard var templates = notifications.replyTemplates else { return }
        let ids = Set(removed.map(\.id))
        templates.removeAll { ids.contains($0.id) }
        await saveReplyTemplates(templates)
    }

    /// Puts `moving` in front of `target`, or at the end for none.
    func moveReplyTemplates(_ moving: [ReplyTemplate], before target: ReplyTemplate?) async {
        guard var templates = notifications.replyTemplates else { return }
        let ids = Set(moving.map(\.id))
        let moved = templates.filter { ids.contains($0.id) }
        templates.removeAll { ids.contains($0.id) }
        let index = target.flatMap { target in templates.firstIndex { $0.id == target.id } } ?? templates.count
        templates.insert(contentsOf: moved, at: index)
        await saveReplyTemplates(templates)
    }

    /// The list on screen changes only once it is kept: the extension reads the
    /// file, not this model, so a list shown and not saved is not what the
    /// watch is offered.
    @discardableResult
    private func saveReplyTemplates(_ templates: [ReplyTemplate]) async -> Bool {
        do {
            try await replyTemplateStore.save(templates)
        } catch is ReplyTemplateStore.ContainerUnavailable {
            notifications.replyTemplatesFeedback = .failure(
                "Reply templates cannot be kept here: this app has no storage the notification extension can read."
            )
            return false
        } catch {
            notifications.replyTemplatesFeedback = .failure("The reply templates could not be saved.")
            return false
        }
        notifications.replyTemplates = templates
        notifications.replyTemplatesFeedback = nil
        return true
    }
}
