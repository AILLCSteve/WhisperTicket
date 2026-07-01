import UIKit

/// Lightweight haptic feedback helper. Tactile confirmation matters in a POS app
/// used one-handed and in motion, where the screen often isn't being watched.
enum Haptics {
    /// Firm tap — starting to record.
    static func recordStart() { impact(.medium) }
    /// Soft tap — stopping the recording.
    static func recordStop() { impact(.light) }
    /// Light selection tick — item added/edited, toggles.
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
    /// Success buzz — order sent to the kitchen.
    static func success() { notify(.success) }
    /// Warning buzz — allergy / noisy-environment alerts.
    static func warning() { notify(.warning) }
    /// Error buzz — failed action.
    static func error() { notify(.error) }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(type)
    }
}
