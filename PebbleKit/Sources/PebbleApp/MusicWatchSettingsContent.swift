import PebbleProtocol
import SwiftUI

/// The watch music app's own display switches, on a page of their own so the
/// watch's detail screen is not a wall of toggles. Each row is one of the
/// syncable `WatchSetting`s the firmware keeps for the music app.
struct MusicWatchSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var board: WatchBoard?
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void

    static let musicSettings: [WatchSetting] = [
        .musicShowVolumeControls, .musicShowProgressBar, .musicShowAlbumArt,
    ]

    var body: some View {
        Form {
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                ForEach(Self.musicSettings.filter { $0.isOffered(on: board) }, id: \.self) { setting in
                    WatchSettingRow(
                        setting: setting,
                        rawValue: watchSettings[setting] ?? setting.defaultRawValue,
                        setRawValue: { setWatchSetting(setting, $0) }
                    )
                }
            } footer: {
                Text("What the watch's music app shows while something is playing.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Music"))
    }
}

#Preview("Music") {
    NavigationStack {
        MusicWatchSettingsContent(
            watchSettings: [.musicShowVolumeControls: 1, .musicShowAlbumArt: 1],
            board: .obelixPVT,
            feedback: nil,
            setWatchSetting: { _, _ in }
        )
    }
}
