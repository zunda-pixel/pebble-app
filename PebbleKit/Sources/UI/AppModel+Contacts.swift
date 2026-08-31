public import API
import Contacts
public import Foundation
import SwiftUI

/// The people the watch can send a message to.
///
/// The phone holds the address book; the watch is given only the ones chosen
/// here, because it has room for a short list and a menu of four hundred names
/// is no use on a watch. Two things go over: the contacts themselves, and the
/// list of which ones the Send Text app shows — a contact the watch holds but
/// the list does not name is not shown at all.
extension AppModel {
    public func loadContacts() async {
        contacts = (try? await contactLibrary.contacts()) ?? []
    }

    /// Reads the phone's address book into the picker, asking for permission
    /// the first time.
    public func refreshAvailableContacts() async {
        if !contactsBridge.isAllowed {
            guard await contactsBridge.requestAccess() else {
                contactStatusMessage = "Allow access to Contacts to choose who the watch can write to."
                return
            }
        }
        do {
            availableContacts = try contactsBridge.contacts(matching: contacts)
            contactStatusMessage = nil
        } catch {
            contactStatusMessage = "The address book could not be read."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "contacts",
                message: "reading the address book: \(String(reflecting: error))"
            )
        }
    }

    public func isContactChosen(_ contact: PebbleContact) -> Bool {
        contacts.contains { $0.systemIdentifier == contact.systemIdentifier }
    }

    public func setContactChosen(_ contact: PebbleContact, isChosen: Bool) async {
        if isChosen {
            guard !isContactChosen(contact) else { return }
            contacts.append(contact)
        } else {
            let removed = contacts.filter { $0.systemIdentifier == contact.systemIdentifier }
            contacts.removeAll { $0.systemIdentifier == contact.systemIdentifier }
            for contact in removed {
                for connection in activeConnections {
                    try? await connection.client.removeContact(id: contact.id)
                }
            }
        }
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try? await contactLibrary.save(contacts)
        for connection in activeConnections {
            await synchronizeContacts(on: connection)
        }
    }

    public func setContactFavourite(_ contact: PebbleContact, addressID: UUID, isFavourite: Bool) async {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }),
              let addressIndex = contacts[index].addresses.firstIndex(where: { $0.id == addressID })
        else { return }
        contacts[index].addresses[addressIndex].isFavourite = isFavourite
        try? await contactLibrary.save(contacts)
        for connection in activeConnections {
            await synchronizeContacts(on: connection)
        }
    }

    /// Writes the chosen people, then the list that makes them visible. The
    /// order matters: a list naming a contact the watch has not been given
    /// leaves the app with a row it cannot fill in.
    func synchronizeContacts(on connection: WatchConnection) async {
        guard connection.isConnected, !connection.device.isRunningRecoveryFirmware else { return }
        for contact in contacts {
            do {
                try await connection.client.writeContact(contact)
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "contacts",
                    message: "\(connection.device.name) rejected \(contact.name): \(String(reflecting: error))"
                )
                return
            }
        }
        do {
            try await connection.client.writeSendTextContacts(contacts)
        } catch {
            contactStatusMessage = "\(connection.device.name) did not accept the contact list."
        }
    }
}
