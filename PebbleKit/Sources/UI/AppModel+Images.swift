import API
import Foundation

/// Pictures the watch asks for.
///
/// The watch pulls: when it has somewhere to show a picture it says how big
/// that space is and waits for an answer on that token. Every request is
/// answered, even when there is no picture — a token left unanswered is a watch
/// left waiting.
extension AppModel {
    func answerImageRequest(_ request: PebbleImageRequest, on connection: WatchConnection) async {
        let header = request.header
        guard header.width > 0, header.height > 0,
              header.width <= ImagingCodec.maximumDimension,
              header.height <= ImagingCodec.maximumDimension
        else {
            try? await connection.client.sendImage(
                token: header.token,
                kindValue: header.kindValue,
                image: nil
            )
            return
        }

        switch request {
        case .albumArt:
            let image = musicCoordinator.artwork(width: header.width, height: header.height)
            try? await connection.client.sendImage(
                token: header.token,
                kindValue: header.kindValue,
                image: image
            )
        case .notification, .unsupported:
            // Notifications reaching this app carry no picture: what iOS hands
            // over has no attachment, and there is nothing to look up by item.
            // Saying so once stops the watch asking again this connection.
            try? await connection.client.declineImageKind(
                token: header.token,
                kindValue: header.kindValue
            )
        }
    }
}
