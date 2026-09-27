import PebbleProtocol
import SwiftUI

struct NotificationRulesView: View {
    var model: AppModel
    var app: NotificationSourceApp

    private var current: NotificationSourceApp {
        model.notifications.sourceApps.first { $0.bundleID == app.bundleID } ?? app
    }

    var body: some View {
        NotificationRulesContent(
            appName: current.displayName,
            rules: current.filterRules,
            isSupported: model.connections.contains { $0.watch.supportsNotificationFiltering },
            feedback: model.notifications.sourceAppFeedback,
            setRules: { rules in
                Task {
                    await model.setNotificationSourceAppFilterRules(
                        bundleID: app.bundleID,
                        rules: rules
                    )
                }
            }
        )
    }
}

/// The notifications from one app the watch is to keep to itself.
struct NotificationRulesContent: View {
    var appName: String
    var rules: [NotificationFilterRule]
    var isSupported: Bool = true
    var feedback: FeatureFeedback?
    var setRules: ([NotificationFilterRule]) -> Void

    @State private var pattern = ""
    @State private var field = NotificationRuleField.anywhere
    @State private var isCaseSensitive = false

    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            FeedbackBanner(feedback: feedback)
            Section {
                if rules.isEmpty {
                    Text("Every notification from this app reaches the watch.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    LabeledContent {
                        Text(rule.field.title)
                    } label: {
                        Text(verbatim: rule.pattern)
                        if rule.isCaseSensitive {
                            Text("Match Case")
                        }
                    }
                }
                .onDelete { offsets in
                    var kept = rules
                    kept.remove(atOffsets: offsets)
                    setRules(kept)
                }
            } header: {
                Text("Rules")
            } footer: {
                if isSupported {
                    Text("A notification the watch is about to show is dropped when one of these is found in it.")
                } else {
                    Text("This watch's firmware does not filter notifications, so these are kept here until one that does connects.")
                }
            }

            Section {
                TextField("Words to look for", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                Picker("Look in", selection: $field) {
                    ForEach(NotificationRuleField.allCases, id: \.self) { field in
                        Text(field.title).tag(field)
                    }
                }
                Toggle("Match Case", isOn: $isCaseSensitive)
                Button("Add Rule") {
                    setRules(rules + [NotificationFilterRule(
                        pattern: trimmedPattern,
                        field: field,
                        isCaseSensitive: isCaseSensitive
                    )])
                    pattern = ""
                    field = .anywhere
                    isCaseSensitive = false
                }
                .disabled(trimmedPattern.isEmpty)
            } header: {
                Text("New Rule")
            } footer: {
                // Both are what the firmware does, and neither is guessable
                // from the screen.
                Text("The words are looked for anywhere in the text, and the watch compares them letter by letter — it folds case for English letters only.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: appName))
    }
}

extension NotificationRuleField {
    var title: LocalizedStringKey {
        switch self {
        case .anywhere: "Title or Body"
        case .title: "Title"
        case .body: "Body"
        }
    }
}

#Preview("Rules") {
    NavigationStack {
        NotificationRulesContent(
            appName: "Gmail",
            rules: [
                NotificationFilterRule(pattern: "Promotion"),
                NotificationFilterRule(pattern: "Newsletter", field: .title, isCaseSensitive: true),
            ],
            setRules: { _ in }
        )
    }
}

#Preview("No rules yet") {
    NavigationStack {
        NotificationRulesContent(appName: "Gmail", rules: [], setRules: { _ in })
    }
}

#Preview("Firmware that does not filter") {
    NavigationStack {
        NotificationRulesContent(
            appName: "Gmail",
            rules: [NotificationFilterRule(pattern: "Promotion")],
            isSupported: false,
            setRules: { _ in }
        )
    }
}
