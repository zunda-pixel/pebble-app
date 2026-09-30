import PebbleProtocol
import SwiftUI

/// One reply template, edited in place. The text is handed on when the reader
/// is done with it rather than on every keystroke: each change rewrites the
/// file the notification extension reads.
struct ReplyTemplateRow: View {
    var template: ReplyTemplate
    var update: (ReplyTemplate) -> Void

    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(template: ReplyTemplate, update: @escaping (ReplyTemplate) -> Void) {
        self.template = template
        self.update = update
        _draft = State(initialValue: template.text)
    }

    var body: some View {
        TextField("Reply", text: $draft)
            .focused($isEditing)
            .submitLabel(.done)
            .onSubmit(commit)
            .onChange(of: isEditing) { _, isEditing in
                if !isEditing { commit() }
            }
            .onChange(of: template.text) { _, text in
                if !isEditing { draft = text }
            }
    }

    /// Emptied, the reply goes back to what it was: deleting is a swipe, and a
    /// blank reply is nothing the watch could send.
    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draft = template.text
            return
        }
        guard trimmed != template.text else { return }
        var edited = template
        edited.text = trimmed
        update(edited)
    }
}

#Preview("Reply") {
    Form {
        ReplyTemplateRow(template: PreviewSamples.replyTemplates[0], update: { _ in })
    }
}

#Preview("Long reply") {
    Form {
        ReplyTemplateRow(template: PreviewSamples.replyTemplates[3], update: { _ in })
    }
}
