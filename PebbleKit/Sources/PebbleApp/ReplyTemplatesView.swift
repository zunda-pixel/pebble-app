import PebbleProtocol
import SwiftUI

struct ReplyTemplatesView: View {
    var model: AppModel

    var body: some View {
        ReplyTemplatesContent(
            templates: model.notifications.replyTemplates,
            feedback: model.notifications.replyTemplatesFeedback,
            add: { text in Task { await model.addReplyTemplate(text) } },
            update: { template in Task { await model.updateReplyTemplate(template) } },
            remove: { templates in Task { await model.removeReplyTemplates(templates) } },
            move: { templates, target in Task { await model.moveReplyTemplates(templates, before: target) } }
        )
        .task { await model.loadReplyTemplates() }
    }
}

/// The replies the watch offers when the reader answers an iPhone notification
/// from it.
struct ReplyTemplatesContent: View {
    /// Nil until they have been read.
    var templates: [ReplyTemplate]?
    var feedback: FeatureFeedback? = nil
    var add: (String) -> Void
    var update: (ReplyTemplate) -> Void
    var remove: ([ReplyTemplate]) -> Void
    /// The templates moved, and the one they now go in front of — nil for the
    /// end.
    var move: ([ReplyTemplate], ReplyTemplate?) -> Void

    @State private var newReply = ""

    private var trimmedNewReply: String {
        newReply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            FeedbackBanner(feedback: feedback)
            Section {
                if let templates {
                    if templates.isEmpty {
                        Text("The watch offers its own replies until you add one here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(templates) { template in
                        ReplyTemplateRow(template: template, update: update)
                    }
                    .onDelete { offsets in
                        remove(offsets.map { templates[$0] })
                    }
                    .onMove { offsets, destination in
                        let moving = offsets.map { templates[$0] }
                        let target = templates[destination...].first { !moving.contains($0) }
                        move(moving, target)
                    }
                } else {
                    ProgressView()
                }
            } footer: {
                Text("When you reply to an iPhone notification from the watch, it offers these in this order, as many as fit.")
            }

            Section {
                TextField("New Reply", text: $newReply)
                    .onSubmit(addNewReply)
                Button("Add", action: addNewReply)
                    .disabled(trimmedNewReply.isEmpty || templates == nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Reply Templates"))
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
    }

    private func addNewReply() {
        guard !trimmedNewReply.isEmpty, templates != nil else { return }
        add(trimmedNewReply)
        newReply = ""
    }
}

#Preview("Replies") {
    NavigationStack {
        ReplyTemplatesContent(
            templates: PreviewSamples.replyTemplates,
            add: { _ in },
            update: { _ in },
            remove: { _ in },
            move: { _, _ in }
        )
    }
}

#Preview("None") {
    NavigationStack {
        ReplyTemplatesContent(templates: [], add: { _ in }, update: { _ in }, remove: { _ in }, move: { _, _ in })
    }
}

#Preview("Reading") {
    NavigationStack {
        ReplyTemplatesContent(templates: nil, add: { _ in }, update: { _ in }, remove: { _ in }, move: { _, _ in })
    }
}

#Preview("Could not be kept") {
    NavigationStack {
        ReplyTemplatesContent(
            templates: PreviewSamples.replyTemplates,
            feedback: .failure("The reply templates could not be saved."),
            add: { _ in },
            update: { _ in },
            remove: { _ in },
            move: { _, _ in }
        )
    }
}
