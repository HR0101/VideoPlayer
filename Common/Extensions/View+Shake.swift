import SwiftUI
import UIKit

private class ShakeDetectingUIView: UIView {
    var onShake: () -> Void = {}
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); self.becomeFirstResponder() }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake() }
        super.motionEnded(motion, with: event)
    }
}
private struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void
    func makeUIView(context: Context) -> ShakeDetectingUIView { let v = ShakeDetectingUIView(); v.onShake = onShake; return v }
    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) { uiView.onShake = onShake }
}
private struct ShakeViewModifier: ViewModifier {
    let onShake: () -> Void
    func body(content: Content) -> some View { content.background(ShakeDetector(onShake: onShake).frame(width: 0, height: 0)) }
}
extension View {
    func onShake(perform action: @escaping () -> Void) -> some View { self.modifier(ShakeViewModifier(onShake: action)) }
}
