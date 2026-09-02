import PebbleProtocol
import Foundation

/// The watch pulls: when it has somewhere to show a picture it says how big
/// that space is and waits for an answer on that token.
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
            // What iOS hands over has no attachment, and there is nothing to look up by
            // item, so saying so once stops the watch asking again.
            try? await connection.client.declineImageKind(
                token: header.token,
                kindValue: header.kindValue
            )
        }
    }
}
