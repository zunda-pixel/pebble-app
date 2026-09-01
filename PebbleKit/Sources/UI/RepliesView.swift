import API
import SwiftUI

/// The replies the watch offers, and the ones it has already chosen.
struct RepliesView: View {
    var model: AppModel
    @State private var draft = ""
    @State private var replyBeingSent: WatchReply?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                ForEach(model.cannedReplies, id: \.self) { reply in
                    Text(verbatim: reply)
                }
                .onDelete { offsets in
                    Task { await model.removeCannedReplies(at: offsets) }
                }
                HStack {
                    TextField("New Reply", text: $draft)
                    Button("Add", systemImage: "plus") {
                        let reply = draft
                        draft = ""
                        Task { await model.addCannedReply(reply) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Replies")
            } footer: {
                Text("The watch's Send Text app lists these. It hides itself when there are none.")
            }

            if !model.unsentReplies.isEmpty {
                Section {
                    ForEach(model.unsentReplies) { reply in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: reply.text)
                            if let recipient = reply.recipient {
                                Text(verbatim: recipient).font(.footnote).foregroundStyle(.secondary)
                            }
                            HStack {
                                if MessageComposer.isAvailable {
                                    Button("Send in Messages", systemImage: "square.and.pencil") {
                                        replyBeingSent = reply
                                    }
                                } else if let url = reply.composeURL {
                                    Button("Open in Messages", systemImage: "square.and.pencil") {
                                        openURL(url)
                                    }
                                }
                                Button("Discard", systemImage: "trash", role: .destructive) {
                                    model.discardReply(reply)
                                }
                            }
                            .buttonStyle(.bordered)
                            .font(.footnote)
                        }
                    }
                } header: {
                    Text("Chosen on the Watch")
                } footer: {
                    Text("iOS has no way for an app to send a message on its own, so a reply picked on the watch waits here until it is sent from Messages.")
                }
            }
        }
        .navigationTitle("Replies")
        .sheet(item: $replyBeingSent) { reply in
            MessageComposer(recipient: reply.recipient, message: reply.text) { wasSent in
                // A reply that was not sent stays on the list: the reader may
                // have meant to change it, and losing it would be worse than
                // showing it twice.
                if wasSent { model.discardReply(reply) }
                replyBeingSent = nil
            }
        }
    }
}
