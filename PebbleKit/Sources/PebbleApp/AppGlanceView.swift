import PebbleProtocol
import SwiftUI

struct AppGlanceView: View {
    var model: AppModel
    var application: WatchApplication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppGlanceContent(
            applicationName: application.displayName,
            glance: model.glance(for: application.id)
                ?? AppGlance(applicationID: application.id),
            isInstalled: model.connections.contains {
                model.installedApplicationIDs(on: $0.watch.id).contains(application.id)
            },
            save: { glance in
                Task {
                    await model.setAppGlance(glance)
                    dismiss()
                }
            },
            cancel: { dismiss() }
        )
    }
}

/// The line the launcher shows under one watchapp.
struct AppGlanceContent: View {
    var applicationName: String
    var glance: AppGlance
    var isInstalled: Bool = true
    var feedback: FeatureFeedback?
    var save: (AppGlance) -> Void
    var cancel: () -> Void

    @State private var subtitle = ""
    @State private var icon: TimelineIcon?
    @State private var expires = false
    @State private var expiry = Date()

    private var edited: AppGlance {
        var written = glance
        written.slices = [AppGlanceSlice(
            subtitleTemplate: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            expires: expires ? expiry : nil
        )]
        return written
    }

    var body: some View {
        NavigationStack {
            Form {
                FeedbackBanner(feedback: feedback)
                Section {
                    TextField("Line", text: $subtitle, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Under the App's Name")
                } footer: {
                    if isInstalled {
                        Text("Shown in the launcher beside the app, so that its state can be read without opening it.")
                    } else {
                        Text("This watch does not have the app installed and will refuse a line for it. Install the app first.")
                    }
                }

                Section {
                    Picker("Icon", selection: $icon) {
                        Text("The App's Own").tag(TimelineIcon?.none)
                        ForEach(TimelineIcon.choosable, id: \.self) { icon in
                            Text(icon.title).tag(TimelineIcon?.some(icon))
                        }
                    }
                }

                Section {
                    Toggle("Stops Being True", isOn: $expires)
                    if expires {
                        DatePicker("At", selection: $expiry)
                    }
                } footer: {
                    Text("A line that has expired is not shown, and the app goes back to its name alone.")
                }

                Section {
                    // The watch works out the words again every time it draws
                    // them, so one written now can still be right tomorrow.
                    Text(verbatim: "{time_until(1788393600)|format(\"in %uH hours\")}")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Counting Down")
                } footer: {
                    Text("A line may hold a countdown the watch keeps up to date on its own. Give the moment in seconds since 1970.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: applicationName))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save(edited) }
                }
            }
        }
        .onAppear {
            guard let slice = glance.slices.first else { return }
            subtitle = slice.subtitleTemplate
            icon = slice.icon
            expires = slice.expires != nil
            expiry = slice.expires ?? Date()
        }
    }
}

#Preview("Empty") {
    AppGlanceContent(
        applicationName: "Timeline Weather",
        glance: AppGlance(applicationID: UUID()),
        save: { _ in },
        cancel: {}
    )
}

#Preview("Written") {
    AppGlanceContent(
        applicationName: "Timeline Weather",
        glance: AppGlance(
            applicationID: UUID(),
            slices: [AppGlanceSlice(
                subtitleTemplate: "Kyoto 18°",
                icon: .generic,
                expires: Date(timeIntervalSince1970: 1_788_393_600)
            )]
        ),
        save: { _ in },
        cancel: {}
    )
}

#Preview("App not on this watch") {
    AppGlanceContent(
        applicationName: "Timeline Weather",
        glance: AppGlance(applicationID: UUID()),
        isInstalled: false,
        save: { _ in },
        cancel: {}
    )
}
