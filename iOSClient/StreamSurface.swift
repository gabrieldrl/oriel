import SwiftUI

/// The Mac's picture with all of its input: the client's one display view under an InputOverlay of
/// the same frame, so a touch maps straight onto the streamed frame (taps, drags, scrolls, Pencil,
/// the iPad's pointer, three- and four-finger gestures, and the hardware keyboard, whose first
/// responder the overlay is). Every stream screen draws this; its frame, shape and whatever sits
/// over it belong to the screen.
struct StreamSurface: View {
    @ObservedObject var client: StreamClient
    let overlay: InputOverlayProxy
    /// The person's own keyboard is up.
    @Binding var keyboardShown: Bool
    /// Modifiers latched by a key row until the next key, character or click uses them.
    @Binding var latched: KeyModifiers
    /// What reaches the Mac through the picture (InputOverlayView.takesFingers, takesPointer).
    var takesFingers = true
    var takesPointer = true

    var body: some View {
        ZStack {
            StreamView(client: client)
            InputOverlay(videoSize: client.videoSize,
                         send: { client.sendInput($0) },
                         setOwnPointer: { client.setOwnPointer($0, from: $1) },
                         proxy: overlay,
                         isKeyboardShown: $keyboardShown,
                         latchedModifiers: latched,
                         onModifiersConsumed: { latched = [] },
                         sendGesture: { client.sendGesture($0, fingers: $1) },
                         takesFingers: takesFingers,
                         takesPointer: takesPointer)
        }
    }
}
