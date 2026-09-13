import Defaults
import Foundation
import PebbleProtocol

extension AppModel {
    /// Reads back what the phone can do about the watch's microphone. Cheap
    /// enough to ask whenever a screen showing it appears, and it changes
    /// outside the app: the recognizer's model can be removed by iOS.
    func refreshVoiceTranscriptionReadiness() async {
        voiceTranscriptionReadiness = await speechBridge.readiness()
    }

    /// Turning dictation on fetches the recognizer's model there and then. The
    /// watch waits seconds for an answer and the download takes longer than
    /// that, so a session that arrived first would be refused for nothing.
    func setVoiceTranscriptionEnabled(_ isEnabled: Bool) async {
        Defaults[.voiceTranscriptionEnabled] = isEnabled
        guard isEnabled else {
            await refreshVoiceTranscriptionReadiness()
            return
        }
        voiceTranscriptionReadiness = .installing
        do {
            try await speechBridge.installAssets()
        } catch {
            await DiagnosticLog.shared.record(
                category: "voice",
                message: "Could not install the recognizer: \(error)"
            )
        }
        await refreshVoiceTranscriptionReadiness()
    }
}
