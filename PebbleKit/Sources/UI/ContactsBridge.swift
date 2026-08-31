public import API
public import Contacts
import Foundation

/// The phone's address book, as far as the watch needs it.
///
/// Only people with a phone number are of any use: the watch's Send Text app
/// sends to a number, and a contact without one would be a name that cannot be
/// chosen.
@MainActor
public struct ContactsBridge: Sendable {
    public init() {}

    public var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    public var isAllowed: Bool {
        authorizationStatus == .authorized
    }

    public func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Reads the address book, keeping the identifiers of contacts already
    /// known so a person the watch has already been told about keeps the same
    /// one — the watch's send-text list points at those identifiers, and a new
    /// one would leave it pointing at nothing.
    public func contacts(matching existing: [PebbleContact]) throws -> [PebbleContact] {
        let store = CNContactStore()
        let keys: [any CNKeyDescriptor] = [
            CNContactIdentifierKey as any CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        let known = Dictionary(existing.map { ($0.systemIdentifier, $0) }) { first, _ in first }
        var result: [PebbleContact] = []
        try unsafe store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return }
            let previous = known[contact.identifier]

            var addresses: [PebbleContactAddress] = []
            for number in contact.phoneNumbers {
                let value = number.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                addresses.append(PebbleContactAddress(
                    id: previous?.addresses.first { $0.value == value }?.id ?? UUID(),
                    kind: .phoneNumber,
                    value: value,
                    isFavourite: previous?.addresses.first { $0.value == value }?.isFavourite ?? false
                ))
            }
            guard !addresses.isEmpty else { return }

            result.append(PebbleContact(
                id: previous?.id ?? UUID(),
                systemIdentifier: contact.identifier,
                name: name,
                addresses: addresses
            ))
        }
        return result
    }
}
