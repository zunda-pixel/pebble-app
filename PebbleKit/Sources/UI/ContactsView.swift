import API
import SwiftUI

/// Who the watch can write to.
struct ContactsView: View {
    var model: AppModel
    @State private var search = ""

    private var matches: [PebbleContact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.availableContacts }
        return model.availableContacts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !model.contacts.isEmpty {
                Section {
                    ForEach(model.contacts) { contact in
                        DisclosureGroup(contact.name) {
                            ForEach(contact.addresses) { address in
                                Toggle(isOn: Binding(
                                    get: { address.isFavourite },
                                    set: { isFavourite in
                                        Task {
                                            await model.setContactFavourite(
                                                contact,
                                                addressID: address.id,
                                                isFavourite: isFavourite
                                            )
                                        }
                                    }
                                )) {
                                    LabeledContent {
                                        Text("Favourite")
                                    } label: {
                                        Text(verbatim: address.value)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("On the Watch")
                } footer: {
                    Text("These appear in the watch's Send Text app. A favourite is listed first.")
                }
            }

            Section {
                if model.availableContacts.isEmpty {
                    Button("Read Contacts", systemImage: "person.crop.circle.badge.plus") {
                        Task { await model.refreshAvailableContacts() }
                    }
                } else {
                    ForEach(matches) { contact in
                        Toggle(contact.name, isOn: Binding(
                            get: { model.isContactChosen(contact) },
                            set: { isChosen in
                                Task { await model.setContactChosen(contact, isChosen: isChosen) }
                            }
                        ))
                    }
                }
            } header: {
                Text("Address Book")
            } footer: {
                Text("Only people with a phone number or an email address are shown. An email address goes as an iMessage.")
            }

            if let message = model.contactStatusMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Contacts")
        .task {
            await model.loadContacts()
            if model.contactsBridge.isAllowed { await model.refreshAvailableContacts() }
        }
    }
}
